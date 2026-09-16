// default.h — the baseline theme.
//
// These are the original isPurple/isYellow classifiers that perform well on the
// standard note skin (purple HOLD bars, gold/yellow TAPs on a near-white rail).
// Every other theme is compared against this one; if calibration finds nothing
// closer, this is the fallback.

#pragma once

namespace theme_default {

// HOLD: purple bar. Blue dominant, clearly above red, and red at least green.
inline bool isHold(int r, int g, int b)
{
    return b > 200 && b > r + 30 && r >= g;
}

// TAP: gold/yellow. Red dominant, well above blue, green above blue. The blue
// ceiling rejects the pale hit/press flash (~254,250,188) that briefly appears
// as a note is struck — real gold notes have low blue (~87-130), the flash ~188.
inline bool isTap(int r, int g, int b)
{
    return r > 200 && r > b + 60 && g > b && b < 160;
}

// Fingerprints sampled on the calibration screen: lane 2 (hold), lane 5 (tap).
constexpr int kHoldRef[3] = {181, 165, 244};
constexpr int kTapRef[3]  = {243, 209, 130};

}  // namespace theme_default
