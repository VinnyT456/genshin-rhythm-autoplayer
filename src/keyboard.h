#pragma once

#include <CoreGraphics/CoreGraphics.h>

#include <cstddef>
#include <sys/types.h>
#include <unordered_map>
#include <vector>

enum class Key
{
    A, S, D,
    J, K, L
};

class Keyboard
{
private:
    std::unordered_map<Key, CGKeyCode> keycodes;

    CGEventSourceRef eventSource;
    pid_t targetPID = 0;

    void post(Key key, bool down);

public:
    Keyboard();
    ~Keyboard();

    void setTargetPID(pid_t pid);

    void keyDown(Key key);
    void keyUp(Key key);

    // Prime event creation without posting any keyboard input.
    void warmUp();

    // Send a fixed-size chord as one key-down loop, an optional gap, and one
    // key-up loop. The caller owns the array for the duration of the call.
    void press(
        const Key* keys,
        std::size_t keyCount,
        int gapMs
    );

    void press(
        const std::vector<Key>& keys
    );
};
