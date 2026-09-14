// theme.mm — assemble the theme registry from the per-theme headers.
//
// To add a theme: create src/themes/<name>.h in the same shape as default.h,
// #include it below, and add one THEME_ENTRY(...) line. Nothing else changes.

#include "theme.h"

#include <cstring>
#include <limits>

#include "default.h"
// #include "<your_theme>.h"   // add new theme headers here

namespace {

// Build a Theme registry entry from a theme namespace's pieces.
#define THEME_ENTRY(NAME, NS)                                   \
    Theme{ NAME,                                                \
           RGB{ NS::kHoldRef[0], NS::kHoldRef[1], NS::kHoldRef[2] }, \
           RGB{ NS::kTapRef[0],  NS::kTapRef[1],  NS::kTapRef[2] },  \
           &NS::isHold, &NS::isTap }

const Theme kThemes[] = {
    THEME_ENTRY("default", theme_default),
    // THEME_ENTRY("<name>", theme_<name>),
};

constexpr std::size_t kThemeCount = sizeof(kThemes) / sizeof(kThemes[0]);

}  // namespace

namespace themes {

const Theme* all(std::size_t* count)
{
    if (count) *count = kThemeCount;
    return kThemes;
}

const Theme* by_name(const char* name)
{
    if (!name) return nullptr;
    for (std::size_t i = 0; i < kThemeCount; ++i)
        if (std::strcmp(kThemes[i].name, name) == 0)
            return &kThemes[i];
    return nullptr;
}

const Theme* nearest(const RGB& holdSample, const RGB& tapSample)
{
    const Theme* best = nullptr;
    long bestDist = std::numeric_limits<long>::max();
    for (std::size_t i = 0; i < kThemeCount; ++i)
    {
        const Theme& t = kThemes[i];
        const long d =
            (long)rgbDist2(t.holdRef, holdSample.r, holdSample.g, holdSample.b) +
            (long)rgbDist2(t.tapRef,  tapSample.r,  tapSample.g,  tapSample.b);
        if (d < bestDist) { bestDist = d; best = &t; }
    }
    return best;
}

}  // namespace themes
