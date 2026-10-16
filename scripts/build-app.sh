#!/bin/bash
# Builds build/Klavko.app (universal: Apple Silicon + Intel) and signs it.
# Signing with a stable certificate keeps the Accessibility permission across rebuilds;
# without one the app is signed ad hoc and the permission must be re-granted after each build.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
ARCHS=(--arch arm64 --arch x86_64)

swift build -c "$CONFIG" "${ARCHS[@]}"
BIN_DIR="$(swift build -c "$CONFIG" "${ARCHS[@]}" --show-bin-path)"

APP="build/Klavko.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Klavko" "$APP/Contents/MacOS/Klavko"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Resource bundles of dependencies (FluidAudio's), found by Bundle.module in Contents/Resources.
for bundle in "$BIN_DIR"/*.bundle; do
    [ -e "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

IDENTITY="${KLAVKO_SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
    | awk -F'"' '/Developer ID Application|Apple Development/ { print $2; exit }')}"
IDENTITY="${IDENTITY:--}"
codesign --force --options runtime --entitlements Resources/Klavko.entitlements --sign "$IDENTITY" "$APP"

echo "Built $APP (signed with: $IDENTITY)"
