#!/bin/bash
# Builds Klavko and installs it to ~/Applications, replacing a running copy.
# The installed copy is the one that starts at login.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh

DEST="$HOME/Applications/Klavko.app"
mkdir -p "$HOME/Applications"
pkill -x Klavko || true
sleep 1
rm -rf "$DEST"
cp -R build/Klavko.app "$DEST"
open "$DEST"

echo "Installed and started $DEST"
