#!/usr/bin/env bash
# Build the Genshin rhythm autoplayer (macOS, ScreenCaptureKit + CGEvent).
set -euo pipefail

cd "$(dirname "$0")"

clang++ -std=c++17 -ObjC++ -fobjc-arc -O2 \
  src/main.mm \
  src/keyboard.mm \
  src/themes/theme.mm \
  -Isrc \
  -framework Cocoa \
  -framework ScreenCaptureKit \
  -framework CoreMedia \
  -framework CoreVideo \
  -framework CoreGraphics \
  -framework ImageIO \
  -framework UniformTypeIdentifiers \
  -o main

echo "Built ./main"
