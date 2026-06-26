#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP="build/Yap.app"
MACOS_DIR="$APP/Contents/MacOS"

swift build -c "$CONFIG" --product YapApp
BIN="$(swift build -c "$CONFIG" --product YapApp --show-bin-path)/YapApp"

rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$APP/Contents/Resources"
cp "$BIN" "$MACOS_DIR/Yap"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Prefer a stable self-signed identity so TCC grants (Accessibility, mic) survive
# rebuilds; fall back to ad-hoc when it isn't installed.
SIGN_ID="Yap Self-Signed"
if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    codesign --force --sign "$SIGN_ID" --entitlements Resources/Yap.entitlements "$APP"
    echo "Built $APP (signed: $SIGN_ID)"
else
    codesign --force --sign - --entitlements Resources/Yap.entitlements "$APP"
    echo "Built $APP (signed: ad-hoc)"
fi
