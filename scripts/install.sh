#!/bin/bash
# Builds Klavko and installs it to /Applications, replacing a running copy.
# The installed copy is the one that starts at login.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh

DEST="/Applications/Klavko.app"
pkill -x Klavko || true
sleep 1
rm -rf "$DEST"
# Earlier versions went to ~/Applications; don't leave a second copy there.
rm -rf "$HOME/Applications/Klavko.app"
cp -R build/Klavko.app "$DEST"
open "$DEST"

echo "Installed and started $DEST"
