#!/usr/bin/env bash
# Build and launch the current working-tree Pits.app.
# Usage: bash scripts/run.sh
set -euo pipefail

cd "$(dirname "$0")/.."

echo "→ regenerating project from project.yml"
xcodegen generate >/dev/null

# Pin destination to the native arch — `platform=macOS` alone matches both
# arm64 and x86_64 slices and trips the "multiple matching destinations"
# warning on Apple Silicon.
ARCH=$(uname -m)

echo "→ building (Debug, arch=$ARCH)"
# Capture stderr so CoreSimulator's unconditional "out of date" noise doesn't
# pollute the console on every run. Only surface stderr if xcodebuild itself
# failed — that's when it's actually useful.
ERR_LOG=$(mktemp)
trap 'rm -f "$ERR_LOG"' EXIT
if ! xcodebuild -project Pits.xcodeproj -scheme Pits \
  -destination "platform=macOS,arch=$ARCH" -configuration Debug build -quiet \
  2>"$ERR_LOG" >/dev/null; then
  echo "✗ build failed — xcodebuild stderr follows:" >&2
  cat "$ERR_LOG" >&2
  exit 1
fi

APP="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
  -type d -name 'Pits.app' -path '*/Debug/*' 2>/dev/null | head -1)"

if [ -z "$APP" ]; then
  echo "✗ couldn't find built Pits.app under DerivedData" >&2
  exit 1
fi

echo "→ killing any running Pits"
pkill -x Pits 2>/dev/null || true
# LaunchServices briefly holds the old bundle after SIGTERM — give it a
# moment before re-opening, otherwise `open` can fail with error -600.
sleep 1

echo "→ launching $APP"
open "$APP"
