// main.mm

#import <Cocoa/Cocoa.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

#include "keyboard.h"

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

// 3x3 patch used only by the calibration snapshot.
static constexpr int kRefRadius = 1;
static constexpr int kRefPix    = (2 * kRefRadius + 1) * (2 * kRefRadius + 1);
static constexpr int kRefLen    = kRefPix * 3;

// ============================================================
// Note color classification (BGRA buffer, read as RGB)
//   PURPLE ~ (181,165,244)  YELLOW ~ (243,209,130)  empty ~ near-white
// ============================================================

static inline bool isPurple(int r, int g, int b)
{
    return b > 200 && b > r + 30 && r >= g;
}

static inline bool isYellow(int r, int g, int b)
{
    return r > 200 && r > b + 60 && g > b;
}

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

    SteadyClock::time_point burstGuardUntil{};
    SteadyClock::time_point pressedAt{};
    SteadyClock::time_point blockPressUntil{};
};

static std::array<Lane, 6> gLanes =
{{
    { 358,  783, Key::A },   // lane 1
    { 519,  783, Key::S },   // lane 2 (purple, calibrated)
    { 680,  783, Key::D },   // lane 3
    { 840,  783, Key::J },   // lane 4
    { 1001, 783, Key::K },   // lane 5 (gold, calibrated)
    { 1162, 783, Key::L }    // lane 6
}};

// Single-pixel color detection at the lane's sample point.
static inline bool laneNotePresent(
    const uint8_t* base, size_t stride, size_t width, size_t height,
    const Lane& lane)
{
    const int x = lane.x, y = lane.y;
    if (x < 0 || y < 0 ||
        static_cast<size_t>(x) >= width ||
        static_cast<size_t>(y) >= height)
        return false;

    const uint8_t* p = base + (size_t)y * stride + (size_t)x * 4;
    const int b = p[0], g = p[1], r = p[2];
    return isPurple(r, g, b) || isYellow(r, g, b);
}

// ============================================================
// Calibration helpers
// ============================================================

static inline bool sampleRefPatch(
    const uint8_t* base, size_t stride, size_t width, size_t height,
    int cx, int cy, uint8_t out[kRefLen])
{
    int i = 0;
    for (int dy = -kRefRadius; dy <= kRefRadius; ++dy)
    for (int dx = -kRefRadius; dx <= kRefRadius; ++dx)
    {
        const int x = cx + dx, y = cy + dy;
        if (x < 0 || y < 0 ||
            static_cast<size_t>(x) >= width ||
            static_cast<size_t>(y) >= height)
            return false;
        const uint8_t* p =
            base + (size_t)y * stride + (size_t)x * 4;
        out[i++] = p[2];   // R
        out[i++] = p[1];   // G
        out[i++] = p[0];   // B
    }
    return true;
}

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

        for (size_t li = 0; li < gLanes.size(); ++li)
        {
            Lane& lane = gLanes[li];
            uint8_t patch[kRefLen];
            bool ok = sampleRefPatch(base, stride, width, height,
                                     lane.x, lane.y, patch);
            saveCropPNG(base, stride, width, height, lane.x, lane.y, 80,
                        "/tmp/calib_lane" + std::to_string(li + 1) + ".png");

            std::cout << "Lane " << (li + 1) << " (x=" << lane.x
                      << ", y=" << lane.y << "): ";
            if (!ok) { std::cout << "OUT OF BOUNDS\n"; continue; }

            long sr = 0, sg = 0, sb = 0;
            for (int p = 0; p < kRefPix; ++p) {
                sr += patch[p*3+0]; sg += patch[p*3+1]; sb += patch[p*3+2];
            }
            int ar = sr/kRefPix, ag = sg/kRefPix, ab = sb/kRefPix;
            const char* cls = isPurple(ar,ag,ab) ? "PURPLE"
                            : isYellow(ar,ag,ab) ? "YELLOW" : "none";
            std::cout << "avg(" << ar << "," << ag << "," << ab << ") -> "
                      << cls << "\n";
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
        const bool detected =
            laneNotePresent(base, stride, width, height, lane);

        if (detected && !lane.held)
        {
            if (now < lane.blockPressUntil)   // enforce min up-gap
                continue;

            lane.held      = true;
            lane.missCount = 0;
            lane.pressedAt = now;
            lane.burstGuardUntil = now + kClickBurstGuard;
            _keyboard.keyDown(lane.key);
        }
        else if (detected && lane.held)
        {
            lane.missCount = 0;

            if (now - lane.pressedAt >= kMaxHoldMs)   // split touching notes
            {
                lane.held = false;
                lane.blockPressUntil = now + kMinUpGapMs;
                _keyboard.keyUp(lane.key);
            }
        }
        else if (!detected && lane.held)
        {
            if (now - lane.pressedAt < kMinHoldMs)     // min down time
                continue;
            if (++lane.missCount < kReleaseFrames)     // release hysteresis
                continue;

            lane.held      = false;
            lane.missCount = 0;
            lane.blockPressUntil = now + kMinUpGapMs;
            _keyboard.keyUp(lane.key);
        }
    }

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
        std::thread([controller]{
            std::string line;
            while (std::getline(std::cin, line))
            {
                if (line == "q" || line == "Q") { gRunning.store(false); std::exit(0); }
                else if (line == "s" || line == "S")
                    dispatch_async(dispatch_get_main_queue(),
                                   ^{ [controller startDetector]; });
                else if (line == "t" || line == "T")
                    dispatch_async(dispatch_get_main_queue(),
                                   ^{ [controller stopDetector]; });
                else if (line == "c" || line == "C")
                {
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
