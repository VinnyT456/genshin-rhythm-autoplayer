# Genshin Rhythm Autoplayer

A macOS autoplayer for the *Genshin Impact* Lyre / rhythm minigame. It watches
the screen with **ScreenCaptureKit**, detects falling notes by their color at
fixed lane points, and sends the matching keystrokes to the game with
**CGEvent** — fast enough to keep up in real time.

It handles both note types: **yellow taps** (quick presses) and **purple holds**
(the key is held down for the whole bar).

No injection, no memory reads, no input hooks into the game — it only reads the
screen (a permission you grant) and sends ordinary keystrokes, the same as if you
were pressing the keys yourself.

> **Disclaimer.** This is a personal/educational project. Automating online games
> may violate their Terms of Service. Use at your own risk.

## Requirements

- macOS 14 (Sonoma) or newer.
- Xcode Command Line Tools: `xcode-select --install`
- *Genshin Impact* installed and running.

## Build

```bash
./build.sh          # produces ./main
```

## Permissions

The app needs two macOS permissions. Grant both to your **terminal app**
(Terminal / iTerm / Ghostty) so the built binary inherits them, then fully quit
and reopen the terminal (`System Settings → Privacy & Security`):

- **Screen Recording** — so it can read the game's pixels.
- **Accessibility** — so it can send keystrokes and control the game window.

## Usage

Run `./main`, then type a single-letter command in the terminal and press ENTER:

| Command | Action |
|---|---|
| `c` | calibration snapshot — focuses Genshin, waits 3s, reports colors, saves debug images to `/tmp` |
| `s` | start autoplay — focuses Genshin, then begins pressing keys |
| `t` | stop autoplay |
| `q` | quit |

Control is entirely through the terminal (global hotkeys are unreliable for a
background tool on macOS). `c` and `s` bring the Genshin window to the front
automatically, so you can trigger them and let it take over. The six lanes map
left→right to the keys **A S D J K L**.

## Calibrate first

Detection relies on each lane's sample point sitting exactly on the note. Before
playing, open the minigame with notes visible and type `c`. The app focuses
Genshin, waits 3 seconds, then for each lane prints the pixel color it sees
(`PURPLE` / `YELLOW` / `WHITE` / `none`) and saves a cropped screenshot to
`/tmp/calib_lane*.png` with the exact sample pixel marked in red.

If a lane reports the wrong color, or the red marker in the crop isn't on the
note, adjust that lane's coordinates in `gLanes` (in
[`src/main.mm`](src/main.mm)) and rebuild. A full-screen capture is also saved to
`/tmp/calib_full.png` to help you find correct coordinates.

## How notes are handled

Each lane runs a small state machine driven by the color at its sample point:

- **Yellow (tap):** pressed briefly, then released. Two taps that arrive
  back-to-back are split into separate presses so the game registers both.
- **Purple (hold):** pressed and held for the whole bar. Because a held note's
  center visually turns white, the hold is judged from a point on the bar *body*
  rather than the center, and it releases only once the lane is genuinely empty.

Timing and color thresholds are compile-time constants at the top of
[`src/main.mm`](src/main.mm) if you need to tune them for a different resolution,
skin, or song.

## Project layout

```
src/main.mm      screen capture, color detection, lane state machine, controls
src/keyboard.*   CGEvent key synthesis, delivered to the Genshin process by PID
build.sh         one-command clang++ build
```

## How it works

```
ScreenCaptureKit ──► BGRA frame ──► per-lane pixel color classify
   (whole display)        │                    │
                          │              purple / yellow / white
                          ▼                    │
                  lane state machine  ◄────────┘
                  (tap vs hold, timing guards)
                          │
                          ▼
                 CGEventPostToPid(Genshin) ──► A S D J K L
```

The display is captured at its native size, so a lane's pixel coordinate equals
the on-screen desktop coordinate.

## License

[MIT](LICENSE) © 2026 Vinny456
