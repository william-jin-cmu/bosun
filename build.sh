#!/bin/bash
# Builds build/Bosun.app. Signs with Developer ID when available so that
# Accessibility / audio permissions survive rebuilds.
set -euo pipefail
cd "$(dirname "$0")"
CONFIG="${BOSUN_CONFIG:-release}"
swift build -c "$CONFIG" --product Bosun
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Bosun"
APP=build/Bosun.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Bosun"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
IDENTITY="${BOSUN_SIGN_IDENTITY-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
if [[ -n "$IDENTITY" ]]; then
    codesign --force --sign "$IDENTITY" --timestamp=none "$APP"
else
    codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo "Built: $PWD/$APP"
