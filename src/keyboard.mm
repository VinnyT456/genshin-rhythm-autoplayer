#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

#include "keyboard.h"

#include <chrono>
#include <thread>
#include <vector>

using namespace std;


// ============================================================
// Keyboard
// ============================================================

Keyboard::Keyboard()
{
    // --------------------------------------------------------
    // Cache event source ONCE
    // --------------------------------------------------------

    eventSource =
        CGEventSourceCreate(
            kCGEventSourceStateHIDSystemState
        );


    // --------------------------------------------------------
    // Key mappings
    // --------------------------------------------------------

    keycodes[Key::A] = 0;
    keycodes[Key::S] = 1;
    keycodes[Key::D] = 2;

    keycodes[Key::J] = 38;
    keycodes[Key::K] = 40;
    // macOS virtual keycode 37 is L; 41 is the semicolon key.
    keycodes[Key::L] = 37;
}


// ============================================================
// Destructor
// ============================================================

Keyboard::~Keyboard()
{
    if (eventSource)
    {
        CFRelease(eventSource);
        eventSource = nullptr;
    }
}


// ============================================================
// Target process
// ============================================================

void Keyboard::setTargetPID(pid_t pid)
{
    targetPID = pid;
}


// ============================================================
// Raw post helper
// ============================================================

void Keyboard::post(
    Key key,
    bool down
)
{
    auto it =
        keycodes.find(key);

    if (it == keycodes.end())
        return;

    if (!eventSource)
        return;


    CGEventRef event =
        CGEventCreateKeyboardEvent(
            eventSource,
            it->second,
            down
        );


    if (!event)
        return;


    // Zero the event's modifier/state flags so each key event is fully self
    // contained and can't carry global key state onto the target — one lane's
    // key never influences another's.
    CGEventSetFlags(event, (CGEventFlags)0);


    // Post directly to the target application's event queue instead of
    // relying on whichever application happens to be frontmost.
    if (targetPID > 0)
    {
        CGEventPostToPid(
            targetPID,
            event
        );
    }


    CFRelease(event);
}


// ============================================================
// Key down
// ============================================================

void Keyboard::keyDown(Key key)
{
    post(
        key,
        true
    );
}


// ============================================================
// Key up
// ============================================================

void Keyboard::keyUp(Key key)
{
    post(
        key,
        false
    );
}


// ============================================================
// Silent event-path warm-up
// ============================================================

void Keyboard::warmUp()
{
    if (!eventSource)
        return;


    // Construct representative down/up events without posting them. This
    // removes first-use CoreGraphics setup from the first real note.
    for (const auto& entry : keycodes)
    {
        for (bool down : {true, false})
        {
            CGEventRef event =
                CGEventCreateKeyboardEvent(
                    eventSource,
                    entry.second,
                    down
                );


            if (event)
                CFRelease(event);
        }
    }
}


// ============================================================
// Press chord
// ============================================================

void Keyboard::press(
    const Key* keys,
    size_t keyCount,
    int gapMs
)
{
    if (!keys || keyCount == 0)
        return;


    // Keep the two loops adjacent so all keys in a detected chord go down
    // before the worker waits for Genshin to sample the press.
    for (size_t i = 0; i < keyCount; ++i)
    {
        post(
            keys[i],
            true
        );
    }


    if (gapMs > 0)
    {
        std::this_thread::sleep_for(
            std::chrono::milliseconds(
                gapMs
            )
        );
    }


    for (size_t i = 0; i < keyCount; ++i)
    {
        post(
            keys[i],
            false
        );
    }
}


void Keyboard::press(
    const vector<Key>& keys
)
{
    press(
        keys.data(),
        keys.size(),
        0
    );
}
