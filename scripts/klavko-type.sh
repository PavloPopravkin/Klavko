#!/bin/bash
# Test helper: builds (if needed) and runs klavko-type, which presses physical keys like a person.
# Usage examples: scripts/klavko-type.sh keys en "ghbdsn "   |   scripts/klavko-type.sh tap option,command
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product KlavkoType >/dev/null
exec .build/release/KlavkoType "$@"
