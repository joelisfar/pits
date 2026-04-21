#!/usr/bin/env bash
# Build and launch the current working-tree Pits.app.
# Usage: bash scripts/run.sh
set -euo pipefail

cd "$(dirname "$0")/.."

echo "→ regenerating project from project.yml"
xcodegen generate >/dev/null

echo "→ building (Debug)"
xcodebuild -project Pits.xcodeproj -scheme Pits \
  -destination 'platform=macOS' -configuration Debug build -quiet

APP="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -type d -name 'Pits.app' -path '*/Debug/*' 2>/dev/null | head -1)"

if [ -z "$APP" ]; then
  echo "✗ couldn't find built Pits.app under DerivedData" >&2
  exit 1
fi

echo "→ killing any running Pits"
pkill -x Pits 2>/dev/null || true

echo "→ launching $APP"
open "$APP"
