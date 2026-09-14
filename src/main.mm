// main.mm

#import <Cocoa/Cocoa.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

#include "keyboard.h"
#include "themes/theme.h"

// ============================================================
// Configuration
// ============================================================

static constexpr int kTargetFPS  = 120;
static constexpr int kQueueDepth = 3;

using SteadyClock = std::chrono::steady_clock;

static constexpr std::chrono::milliseconds kClickBurstGuard{5};

// Minimum tap cycle = kMinHoldMs + kMinUpGapMs. Two same-lane taps closer than
// that floor cannot both fire, so keep it as low as Genshin still registers.
// kMaxHoldMs force-releases a still-detected key so two touching notes split.
static constexpr std::chrono::milliseconds kMinHoldMs{18};
static constexpr std::chrono::milliseconds kMaxHoldMs{60};
static constexpr std::chrono::milliseconds kMinUpGapMs{30};

// Consecutive "gone" samples before a key-up (flicker hysteresis).
static constexpr int kReleaseFrames = 3;

// A purple HOLD ends only after this many CONSECUTIVE white frames. Brief white
// glints mid-bar (bright head/cap, gem highlight) are shorter than this, so the
// hold survives them; only the real empty rail at the bar's end is sustained.
static constexpr int kHoldWhiteFrames = 12;

// ============================================================
// Note color classification (BGRA buffer, read as RGB)
//
// HOLD/TAP classification is theme-specific and lives in src/themes/. The active
// theme is chosen at calibration (lane 2 = hold, lane 5 = tap) and used through
// gActiveTheme->isHold / ->isTap below. Empty-rail (white) detection is generic.
// ============================================================

// The theme whose classifiers are in use. Defaults to "default" and is replaced
// by calibration / a persisted choice at startup.
static const Theme* gActiveTheme = themes::by_name("default");

static inline bool isHoldColor(int r, int g, int b)
{
    return gActiveTheme && gActiveTheme->isHold(r, g, b);
}

static inline bool isTapColor(int r, int g, int b)
{
    return gActiveTheme && gActiveTheme->isTap(r, g, b);
}

// Empty rail is near-white/gray: all channels high and close together
// (calibrated ~237,236,234 and ~255,255,251). Used to end a purple HOLD.
static inline bool isWhite(int r, int g, int b)
{
    const int mn = std::min({r, g, b});
    const int mx = std::max({r, g, b});
    return mn > 200 && (mx - mn) < 25;
}

// The MISS burst: a reddish flash the game shows at the hit line when a note is
// MISSED. It is a UI effect, identical across every theme, so it is a global
// reference (not part of a Theme). Seeing it means this lane just failed a note
// and must be reset for a clean restart — this is how a lane recovers instead of
// staying stuck. Matched within a small tolerance to absorb capture jitter.
static constexpr int kMissBurst[3] = {243, 177, 168};
static constexpr int kMissBurstTol = 5;

static inline bool isMissBurst(int r, int g, int b)
{
    return std::abs(r - kMissBurst[0]) <= kMissBurstTol &&
           std::abs(g - kMissBurst[1]) <= kMissBurstTol &&
           std::abs(b - kMissBurst[2]) <= kMissBurstTol;
}

// Purple notes are HOLD bars (sustain the key); yellow are TAPS. White is the
// empty rail (ends a purple hold). None = anything else (gap/shading/head).
enum class NoteColor { None, Purple, Yellow, White };

// ============================================================
// Lane
// ============================================================

struct Lane
{
    int x;
    int y;
    Key key;

    bool held = false;
    int  missCount = 0;
    bool holdNote = false;   // current press came from a purple (hold) note

    SteadyClock::time_point burstGuardUntil{};
    SteadyClock::time_point pressedAt{};
    SteadyClock::time_point blockPressUntil{};
};

// Primary sample point (used for all press/tap detection).
static std::array<Lane, 6> gLanes =
{{
    { 355,  785, Key::A },   // lane 1
    { 515,  785, Key::S },   // lane 2 (purple, calibrated)
    { 675,  785, Key::D },   // lane 3
    { 835,  785, Key::J },   // lane 4
    { 995, 785, Key::K },   // lane 5 (gold, calibrated)
    { 1155, 785, Key::L }    // lane 6
}};

// While a purple HOLD is pressed, the note center whitens and the primary point
// misreads as "white" (false bar-end). For hold continuation only, probe a
// point offset above the center, which stays on the purple bar body.
static constexpr int kHoldProbeDY = -12;

// Single-pixel color detection at an arbitrary (x,y).
static inline NoteColor colorAt(
    const uint8_t* base, size_t stride, size_t width, size_t height,
    int x, int y)
{
    if (x < 0 || y < 0 ||
        static_cast<size_t>(x) >= width ||
        static_cast<size_t>(y) >= height)
        return NoteColor::None;

    const uint8_t* p = base + (size_t)y * stride + (size_t)x * 4;
    const int b = p[0], g = p[1], r = p[2];
    if (isHoldColor(r, g, b)) return NoteColor::Purple;
    if (isTapColor(r, g, b))  return NoteColor::Yellow;
    if (isWhite(r, g, b))     return NoteColor::White;
    return NoteColor::None;
}

static inline NoteColor laneNoteColor(
    const uint8_t* base, size_t stride, size_t width, size_t height,
    const Lane& lane)
{
    return colorAt(base, stride, width, height, lane.x, lane.y);
}

// ============================================================
// Calibration helpers
// ============================================================

// Save a BGRA crop around (cx,cy) to PNG, marking the sample pixel red.
static void saveCropPNG(
    const uint8_t* base, size_t stride, size_t width, size_t height,
    int cx, int cy, int cropR, const std::string& path)
{
    const int x0 = std::max(0, cx - cropR);
    const int y0 = std::max(0, cy - cropR);
    const int x1 = std::min((int)width  - 1, cx + cropR);
    const int y1 = std::min((int)height - 1, cy + cropR);
    const int w  = x1 - x0 + 1;
    const int h  = y1 - y0 + 1;
    if (w <= 0 || h <= 0) return;

    std::vector<uint8_t> buf((size_t)w * h * 4);
    for (int y = 0; y < h; ++y)
    for (int x = 0; x < w; ++x)
    {
        const uint8_t* p =
            base + (size_t)(y0 + y) * stride + (size_t)(x0 + x) * 4;
        uint8_t* q = &buf[((size_t)y * w + x) * 4];
        q[0] = p[2]; q[1] = p[1]; q[2] = p[0]; q[3] = 255;   // BGRA->RGBA
    }
    {
        int mx = cx - x0, my = cy - y0;
        if (mx >= 0 && my >= 0 && mx < w && my < h) {
            uint8_t* q = &buf[((size_t)my * w + mx) * 4];
            q[0] = 255; q[1] = 0; q[2] = 0; q[3] = 255;
        }
    }

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        buf.data(), w, h, 8, (size_t)w * 4, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGImageRef img = CGBitmapContextCreateImage(ctx);

    NSURL* url = [NSURL fileURLWithPath:
        [NSString stringWithUTF8String:path.c_str()]];
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier, 1, nullptr);
    if (dst) {
        CGImageDestinationAddImage(dst, img, nullptr);
        CGImageDestinationFinalize(dst);
        CFRelease(dst);
        std::cout << "  saved " << path << " (" << w << "x" << h << ")\n";
    }
    CGImageRelease(img);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
}

// ============================================================
// Theme persistence
// ============================================================

// The chosen theme's name is stored next to the executable so it reloads across
// runs without re-calibrating.
static std::string themePath()
{
    NSString* exe = [[NSBundle mainBundle] executablePath];
    NSString* dir = exe != nil ? [exe stringByDeletingLastPathComponent]
                               : NSFileManager.defaultManager.currentDirectoryPath;
    return [dir stringByAppendingPathComponent:@"theme.txt"].UTF8String;
}

static void saveTheme(const char* name)
{
    NSString* ns = [NSString stringWithUTF8String:name ? name : "default"];
    NSString* path = [NSString stringWithUTF8String:themePath().c_str()];
    if ([ns writeToFile:path atomically:YES
               encoding:NSUTF8StringEncoding error:nil])
        std::cout << "  theme saved -> " << ns.UTF8String << "\n";
}

static void loadTheme()
{
    NSString* path = [NSString stringWithUTF8String:themePath().c_str()];
    NSString* name = [[NSString stringWithContentsOfFile:path
                                                encoding:NSUTF8StringEncoding
                                                   error:nil]
        stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (name.length == 0) return;   // none saved — keep the default
    const Theme* t = themes::by_name(name.UTF8String);
    if (t) {
        gActiveTheme = t;
        std::cout << "Loaded theme: " << t->name << "\n";
    }
}

// ============================================================
// Global state
// ============================================================

static std::atomic<bool> gRunning{false};          // autoplay armed?
static std::atomic<bool> gCalibrateCapture{false}; // pending snapshot request?

// ============================================================
// Controller
// ============================================================

@interface CaptureController : NSObject <SCStreamOutput, SCStreamDelegate>
@property(nonatomic, strong) SCStream* stream;
- (void)startDetector;
- (void)stopDetector;
- (void)releaseAllKeys;
- (void)setKeyboardTargetPID:(pid_t)pid;
@end

@implementation CaptureController
{
    Keyboard _keyboard;
}

- (void)setKeyboardTargetPID:(pid_t)pid
{
    _keyboard.setTargetPID(pid);
}

- (void)startDetector
{
    if (!gRunning.exchange(true, std::memory_order_acq_rel))
        std::cout << "\nDetector STARTED\n" << std::flush;
}

- (void)stopDetector
{
    if (gRunning.exchange(false, std::memory_order_acq_rel))
    {
        [self releaseAllKeys];
        std::cout << "\nDetector STOPPED\n" << std::flush;
    }
}

- (void)releaseAllKeys
{
    for (Lane& lane : gLanes)
    {
        if (!lane.held) continue;
        _keyboard.keyUp(lane.key);
        lane.held = false;
        lane.burstGuardUntil = SteadyClock::time_point{};
    }
}

// ============================================================
// ScreenCaptureKit frame
// ============================================================

- (void)stream:(SCStream*)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type
{
    if (type != SCStreamOutputTypeScreen)  return;
    if (!CMSampleBufferIsValid(sampleBuffer)) return;

    CVPixelBufferRef pixelBuffer =
        CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pixelBuffer) return;

    if (CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly)
            != kCVReturnSuccess)
        return;

    uint8_t* base =
        static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(pixelBuffer));
    const size_t width  = CVPixelBufferGetWidth(pixelBuffer);
    const size_t height = CVPixelBufferGetHeight(pixelBuffer);
    const size_t stride = CVPixelBufferGetBytesPerRow(pixelBuffer);

    if (!base)
    {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        return;
    }

    // On-demand calibration snapshot ('c'+ENTER). Reports per-lane color and
    // saves debug PNGs to /tmp. Runs whether or not autoplay is armed.
    if (gCalibrateCapture.exchange(false, std::memory_order_relaxed))
    {
        std::cout << "\n================ CALIBRATION =================\n";
        std::cout << "buffer size: " << width << "x" << height << "\n";
        saveCropPNG(base, stride, width, height,
                    (int)width / 2, (int)height / 2,
                    (int)std::max(width, height), "/tmp/calib_full.png");

        // The calibration screen is fixed: lane 2 is always a HOLD, lane 5 is
        // always a TAP. Sample those two pixels and pick the theme whose hold/tap
        // reference colours are nearest — no per-pixel classification guesswork.
        RGB holdSample{}, tapSample{};
        bool haveHold = false, haveTap = false;

        for (size_t li = 0; li < gLanes.size(); ++li)
        {
            Lane& lane = gLanes[li];
            saveCropPNG(base, stride, width, height, lane.x, lane.y, 80,
                        "/tmp/calib_lane" + std::to_string(li + 1) + ".png");

            std::cout << "Lane " << (li + 1) << " (x=" << lane.x
                      << ", y=" << lane.y << "): ";
            if (lane.x < 0 || lane.y < 0 ||
                (size_t)lane.x >= width || (size_t)lane.y >= height)
            { std::cout << "OUT OF BOUNDS\n"; continue; }

            // Single center pixel — matches runtime detection and avoids
            // averaging over a skinned note's facets/rings (which a patch does).
            const uint8_t* p =
                base + (size_t)lane.y * stride + (size_t)lane.x * 4;
            const int b = p[0], g = p[1], r = p[2];
            std::cout << "rgb(" << r << "," << g << "," << b << ")";
            if (li == 1) { holdSample = RGB{r,g,b}; haveHold = true; std::cout << "  <- HOLD ref (lane 2)"; }
            if (li == 4) { tapSample  = RGB{r,g,b}; haveTap  = true; std::cout << "  <- TAP ref (lane 5)"; }
            std::cout << "\n";
        }

        // Choose the theme from the two reference samples and persist it.
        if (haveHold && haveTap)
        {
            const Theme* chosen = themes::nearest(holdSample, tapSample);
            if (chosen)
            {
                gActiveTheme = chosen;
                saveTheme(chosen->name);
                std::cout << "Selected theme: " << chosen->name << "\n";
            }
        }
        else
        {
            std::cout << "Calibration incomplete: lane 2 / lane 5 out of bounds.\n";
        }
        std::cout << "=============================================\n"
                  << std::flush;
    }

    // Key state machine — only when autoplay is armed ('s').
    if (!gRunning.load(std::memory_order_relaxed))
    {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        return;
    }

    const SteadyClock::time_point now = SteadyClock::now();

    for (Lane& lane : gLanes)
    {
        const NoteColor color =
            laneNoteColor(base, stride, width, height, lane);
        const bool isNote  = (color == NoteColor::Purple ||
                              color == NoteColor::Yellow);
        const bool isEmpty = (color == NoteColor::White);

        // MISS-burst recovery: if the hit line shows the reddish miss flash, this
        // lane just failed a note. Force it fully back to idle so it can start
        // clean on the next note — this is what breaks a stuck hold out of its
        // stuck state instead of ignoring everything that follows.
        if (lane.x >= 0 && lane.y >= 0 &&
            (size_t)lane.x < width && (size_t)lane.y < height)
        {
            const uint8_t* hp = base + (size_t)lane.y * stride + (size_t)lane.x * 4;
            if (isMissBurst(hp[2], hp[1], hp[0]))   // hp = BGRA
            {
                if (lane.held)
                    _keyboard.keyUp(lane.key);
                lane.held      = false;
                lane.holdNote  = false;
                lane.missCount = 0;
                lane.blockPressUntil = now + kMinUpGapMs;
                continue;   // don't run the state machine on a miss frame
            }
        }

        if (isNote && !lane.held)
        {
            if (now < lane.blockPressUntil)   // enforce min up-gap
                continue;

            lane.held      = true;
            lane.missCount = 0;
            lane.pressedAt = now;
            lane.holdNote  = (color == NoteColor::Purple);  // purple = sustain
            lane.burstGuardUntil = now + kClickBurstGuard;
            _keyboard.keyDown(lane.key);
        }
        else if (lane.held && lane.holdNote)
        {
            // HOLD (purple): the note CENTER whitens while pressed, so the
            // primary point misreads as white. Judge the bar from a probe point
            // offset up the bar body instead. Release only on SUSTAINED white
            // there (real empty rail), surviving brief glints.
            const NoteColor probe = colorAt(base, stride, width, height,
                                            lane.x, lane.y + kHoldProbeDY);
            if (probe == NoteColor::White)
            {
                if (now - lane.pressedAt < kMinHoldMs)
                    continue;
                if (++lane.missCount < kHoldWhiteFrames)
                    continue;

                lane.held      = false;
                lane.missCount = 0;
                lane.blockPressUntil = now + kMinUpGapMs;
                _keyboard.keyUp(lane.key);
            }
            else
            {
                lane.missCount = 0;   // any non-white resets the white streak
            }
        }
        else if (lane.held)   // TAP (yellow)
        {
            if (isNote)
            {
                lane.missCount = 0;
                // Split two touching taps into separate presses.
                if (now - lane.pressedAt >= kMaxHoldMs)
                {
                    lane.held = false;
                    lane.blockPressUntil = now + kMinUpGapMs;
                    _keyboard.keyUp(lane.key);
                }
            }
            else   // not a note anymore
            {
                if (now - lane.pressedAt < kMinHoldMs)
                    continue;
                if (++lane.missCount < kReleaseFrames)
                    continue;

                lane.held      = false;
                lane.missCount = 0;
                lane.blockPressUntil = now + kMinUpGapMs;
                _keyboard.keyUp(lane.key);
            }
        }
    }

#if DEBUG_TRACE
    // Held-state snapshot of all six lanes, printed only when it changes. Each
    // slot: '.' idle, 'H' holding a HOLD note, 'T' holding a TAP. A lane stuck
    // on shows here as a slot that never returns to '.'. Enable -DDEBUG_TRACE=1.
    if (gRunning.load(std::memory_order_relaxed))
    {
        static bool sHeld[6] = {false,false,false,false,false,false};
        bool changed = false;
        for (size_t i = 0; i < gLanes.size(); ++i)
            if (gLanes[i].held != sHeld[i]) { changed = true; break; }
        if (changed)
        {
            std::cerr << "HELD ";
            for (size_t i = 0; i < gLanes.size(); ++i)
            {
                const Lane& l = gLanes[i];
                std::cerr << (l.held ? (l.holdNote ? 'H' : 'T') : '.');
                sHeld[i] = l.held;
            }
            std::cerr << "\n";
        }
    }
#endif

    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
}

- (void)stream:(SCStream*)stream didStopWithError:(NSError*)error
{
    gRunning.store(false, std::memory_order_release);
    [self releaseAllKeys];

    if (error)
        std::cerr << "Capture stopped: "
                  << error.localizedDescription.UTF8String << std::endl;
}

- (void)dealloc
{
    [self releaseAllKeys];
}

@end

// ============================================================
// Main
// ============================================================

// Bring the Genshin window to the front (so keystrokes land + you can watch).
static void activateGenshin(pid_t pid)
{
    NSRunningApplication* app =
        [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    [app activateWithOptions:NSApplicationActivateAllWindows];
}

static pid_t findGenshinPID()
{
    for (NSRunningApplication* app in
         [NSWorkspace sharedWorkspace].runningApplications)
    {
        NSString* name = app.localizedName;
        if ([name isEqualToString:@"Genshin Impact"] ||
            [name isEqualToString:@"YuanShen"])
            return app.processIdentifier;
    }
    return 0;
}

int main(int argc, const char* argv[])
{
    @autoreleasepool
    {
        (void)argc; (void)argv;

        [NSApplication sharedApplication];

        // Accessibility permission (for synthesized keystrokes).
        NSDictionary* options =
            @{ (__bridge id)kAXTrustedCheckOptionPrompt: @YES };
        AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);

        // Restore the saved theme choice (falls back to "default").
        loadTheme();

        // Resolve the display to capture.
        __block SCShareableContent* shareableContent = nil;
        dispatch_semaphore_t contentSemaphore = dispatch_semaphore_create(0);
        [SCShareableContent getShareableContentWithCompletionHandler:
            ^(SCShareableContent* content, NSError* error)
            {
                if (error)
                    std::cerr << "Unable to get displays: "
                              << error.localizedDescription.UTF8String << std::endl;
                shareableContent = content;
                dispatch_semaphore_signal(contentSemaphore);
            }];
        dispatch_semaphore_wait(contentSemaphore, DISPATCH_TIME_FOREVER);

        if (!shareableContent || shareableContent.displays.count == 0)
        {
            std::cerr << "No displays available." << std::endl;
            return 1;
        }

        SCDisplay* display = shareableContent.displays.firstObject;
        std::cout << "Capturing display: " << display.width
                  << "x" << display.height << std::endl;

        // Capture the whole display so buffer[x,y] == desktop point (x,y).
        SCContentFilter* filter =
            [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];

        SCStreamConfiguration* config = [[SCStreamConfiguration alloc] init];
        config.width  = display.width;
        config.height = display.height;
        config.pixelFormat = kCVPixelFormatType_32BGRA;
        config.minimumFrameInterval = CMTimeMake(1, kTargetFPS);
        config.queueDepth   = kQueueDepth;
        config.showsCursor  = NO;
        config.capturesAudio = NO;

        CaptureController* controller = [[CaptureController alloc] init];

        const pid_t genshinPID = findGenshinPID();
        if (genshinPID <= 0)
        {
            std::cerr << "Genshin Impact is not running; no target PID."
                      << std::endl;
            return 1;
        }
        [controller setKeyboardTargetPID:genshinPID];
        std::cout << "Keyboard target PID: " << genshinPID << std::endl;

        controller.stream =
            [[SCStream alloc] initWithFilter:filter
                               configuration:config
                                    delegate:controller];

        dispatch_queue_attr_t attributes =
            dispatch_queue_attr_make_with_qos_class(
                DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0);
        dispatch_queue_t captureQueue =
            dispatch_queue_create("genshin.pixel.detector", attributes);

        NSError* outputError = nil;
        BOOL added = [controller.stream addStreamOutput:controller
                                                   type:SCStreamOutputTypeScreen
                                     sampleHandlerQueue:captureQueue
                                                  error:&outputError];
        if (!added || outputError)
        {
            std::cerr << "Unable to add capture output";
            if (outputError)
                std::cerr << ": " << outputError.localizedDescription.UTF8String;
            std::cerr << std::endl;
            return 1;
        }

        dispatch_semaphore_t startSemaphore = dispatch_semaphore_create(0);
        __block BOOL started = NO;
        [controller.stream startCaptureWithCompletionHandler:^(NSError* error)
            {
                if (error)
                    std::cerr << "Capture failed: "
                              << error.localizedDescription.UTF8String << std::endl;
                else
                    started = YES;
                dispatch_semaphore_signal(startSemaphore);
            }];
        dispatch_semaphore_wait(startSemaphore, DISPATCH_TIME_FOREVER);
        if (!started) return 1;

        std::cout
            << "\n====================================\n"
            << " Genshin note autoplayer\n"
            << "====================================\n"
            << ">> RECOMMENDED: calibrate first. Open the game with notes\n"
            << "   visible, type 'c' + ENTER, switch to Genshin, and check\n"
            << "   each lane reports PURPLE / YELLOW as expected.\n\n"
            << "Commands (type, then ENTER):\n"
            << "  c : calibrate snapshot (3s delay, saves /tmp PNGs)\n"
            << "  s : start autoplay\n"
            << "  t : stop autoplay\n"
            << "  q : quit\n\n"
            << "FPS: " << kTargetFPS << "\n\n"
            << std::flush;

        // Terminal-driven control. AppKit calls hop to the main thread.
        std::thread([controller, genshinPID]{
            std::string line;
            while (std::getline(std::cin, line))
            {
                if (line == "q" || line == "Q") { gRunning.store(false); std::exit(0); }
                else if (line == "s" || line == "S")
                    dispatch_async(dispatch_get_main_queue(), ^{
                        activateGenshin(genshinPID);   // focus the game
                        [controller startDetector];
                    });
                else if (line == "t" || line == "T")
                    dispatch_async(dispatch_get_main_queue(),
                                   ^{ [controller stopDetector]; });
                else if (line == "c" || line == "C")
                {
                    dispatch_async(dispatch_get_main_queue(),
                                   ^{ activateGenshin(genshinPID); });  // focus
                    for (int s = 3; s > 0; --s) {
                        std::cout << "Snapshot in " << s << "..." << std::endl;
                        std::this_thread::sleep_for(std::chrono::seconds(1));
                    }
                    gCalibrateCapture.store(true, std::memory_order_relaxed);
                }
            }
        }).detach();

        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
