#!/usr/bin/env bash
# Package a built Pits.app into a UDZO-compressed DMG with /Applications symlink.
# Inputs:
#   $1 (VERSION) — semver string, e.g. 0.2.0
#   $APP_PATH (env, optional) — path to Pits.app; defaults to build/release/Build/Products/Release/Pits.app
# Outputs:
#   dist/Pits-$VERSION.dmg
# Used by scripts/release.sh (locally, in pre-CI smoke tests) and .github/workflows/release.yml (CI).

set -euo pipefail
IFS=$'\n\t'

VERSION="${1:?usage: package_dmg.sh VERSION}"
APP_PATH="${APP_PATH:-build/release/Build/Products/Release/Pits.app}"

[[ -d "$APP_PATH" ]] || { echo "✗ App not found at $APP_PATH" >&2; exit 1; }

STAGING="build/dmg-staging"
rm -rf "$STAGING" dist
mkdir -p "$STAGING" dist

cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

DMG_PATH="dist/Pits-$VERSION.dmg"
hdiutil create \
  -volname "Pits $VERSION" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG_PATH" \
  >/dev/null

echo "→ $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
