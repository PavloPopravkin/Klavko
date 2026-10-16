#!/bin/bash
# Builds Klavko and packs it with the install guide into dist/Klavko-<version>.zip,
# the archive to give to other people (or attach to a GitHub release).
set -euo pipefail
cd "$(dirname "$0")/.."

# Signed ad hoc, not with the developer's certificate: a public download shouldn't carry its owner's email.
KLAVKO_SIGN_IDENTITY="-" scripts/build-app.sh

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
STAGE="$(mktemp -d)/Klavko $VERSION"
mkdir -p "$STAGE" dist
cp -R build/Klavko.app "$STAGE/"
cp "Distribution/Як встановити Klavko.txt" "$STAGE/"

ZIP="dist/Klavko-$VERSION.zip"
rm -f "$ZIP"
# ditto keeps the app's code signature and extended attributes intact.
ditto -c -k --keepParent "$STAGE" "$ZIP"
rm -rf "$(dirname "$STAGE")"

echo "Packed $ZIP"
