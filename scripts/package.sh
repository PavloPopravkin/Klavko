#!/bin/bash
# Builds Klavko and packs the app into dist/Klavko-<version>.zip for installing on a Mac:
# unzip, move Klavko.app to Applications, open it, allow Accessibility.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
mkdir -p dist
ZIP="dist/Klavko-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/Klavko.app "$ZIP"

echo "Packed $ZIP"
