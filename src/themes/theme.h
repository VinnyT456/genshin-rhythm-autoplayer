// theme.h — per-theme note-colour classifiers.
//
// Different Genshin Lyre themes reskin the note colours, so one hard-coded
// isPurple/isYellow can't cover them all. Instead each theme lives in its own
// small header under src/themes/ and supplies:
//   * a HOLD reference RGB  (sampled at lane 2, which is ALWAYS a hold on the
//     calibration screen)
//   * a TAP  reference RGB  (sampled at lane 5, which is ALWAYS a tap)
//   * isHold(r,g,b) / isTap(r,g,b) — that theme's tuned classifiers.
//
// At calibration we read lane 2 + lane 5, pick the theme whose two reference
// colours are nearest, and use that theme's classifiers at runtime. The choice
// is persisted so it reloads next launch.

#pragma once

#include <cstddef>

struct RGB { int r = 0, g = 0, b = 0; };

inline int rgbDist2(const RGB& a, int r, int g, int b)
{
    const int dr = a.r - r, dg = a.g - g, db = a.b - b;
    return dr * dr + dg * dg + db * db;
}

struct Theme
{
    const char* name;                 // stable id, persisted
    RGB holdRef;                      // lane 2 hold colour (fingerprint)
    RGB tapRef;                       // lane 5 tap colour  (fingerprint)
    bool (*isHold)(int r, int g, int b);
    bool (*isTap)(int r, int g, int b);
};

namespace themes {

// All registered themes (one entry per src/themes/<name>.h).
const Theme* all(std::size_t* count);

// Look a theme up by its stable name; nullptr if unknown.
const Theme* by_name(const char* name);

// Pick the theme whose hold/tap references are nearest to the two sampled
// colours (lane 2 hold, lane 5 tap). Never null while at least one theme is
// registered. Combined squared distance over both reference points.
const Theme* nearest(const RGB& holdSample, const RGB& tapSample);

}  // namespace themes
