# Genshin Rhythm Autoplayer

macOS autoplayer for the *Genshin Impact* Lyre / rhythm minigame. It reads the
screen with **ScreenCaptureKit**, detects notes by their color at fixed lane
points, and sends the matching keystrokes to the game with **CGEvent**.

No injection, no memory reads — only screen capture and normal keystrokes.

> Automating online games may break their Terms of Service. Use at your own risk.

## Build

```bash
./build.sh          # produces ./main
```

Needs the Xcode Command Line Tools (`xcode-select --install`) and macOS 14+.

## Permissions

Grant both to your **terminal app**, then restart it
(`System Settings → Privacy & Security`):

- **Screen Recording** — to read the screen.
- **Accessibility** — to send keystrokes.

## Usage

Run `./main`, then type a command in the terminal and press ENTER:

| Command | Action |
|---|---|
| `c` | calibration snapshot (3s delay, saves debug images to `/tmp`) |
| `s` | start autoplay |
| `t` | stop autoplay |
| `q` | quit |

Lanes map left→right to **A S D J K L**.

## Calibrate first

Open the minigame with notes on screen, type `c`, switch to Genshin, and check
each lane reports the expected color (purple / yellow). Debug crops are saved to
`/tmp/calib_*.png`. If a lane is wrong, adjust its coordinates in `gLanes`
(in [`src/main.mm`](src/main.mm)) and rebuild.

## Layout

```
src/main.mm      capture, detection, lane state machine, controls
src/keyboard.*   CGEvent key synthesis (PID-targeted)
build.sh         one-command build
```

## License

[MIT](LICENSE) © 2026 Vinny456
