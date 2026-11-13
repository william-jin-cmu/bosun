#!/bin/bash
# Regenerates Resources/AppIcon.icns from the code-drawn wheel.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/icon
xcrun swiftc -O tools/icon/main.swift Sources/Bosun/Core/WheelGlyph.swift -o build/icon/make-icon
build/icon/make-icon build/icon
iconutil -c icns build/icon/AppIcon.iconset -o Resources/AppIcon.icns
echo "Wrote Resources/AppIcon.icns"
