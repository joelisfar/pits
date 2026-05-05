#!/usr/bin/env bash
# Re-sign Pits.app's Sparkle nested binaries + the main app with Developer ID.
#
# Why this exists: Xcode's automatic codesign doesn't recurse into nested apps
# (Sparkle.framework/Versions/B/Updater.app), XPC services (Downloader.xpc,
# Installer.xpc), or the Autoupdate helper. Sparkle distributes them
# adhoc-signed, and notarization rejects anything not signed with our Developer
# ID. We re-sign deepest-first, then the framework, then the main app.
#
# Inputs:
#   $1 IDENTITY — codesign identity (e.g. "Developer ID Application")
#   $APP_PATH (env, optional) — path to Pits.app; defaults to standard Release output.
#
# Used by .github/workflows/release.yml (CI) and local sign smoke tests.

set -euo pipefail
IFS=$'\n\t'

IDENTITY="${1:?usage: sign_app.sh \"Developer ID Application\"}"
APP_PATH="${APP_PATH:-build/release/Build/Products/Release/Pits.app}"

[[ -d "$APP_PATH" ]] || { echo "✗ App not found at $APP_PATH" >&2; exit 1; }

SPARKLE="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B"

CODESIGN_FLAGS=(--force --options=runtime --timestamp --sign "$IDENTITY")

echo "→ Re-signing Sparkle nested binaries"
# Order matters: sign deepest items first so containing bundles' hashes
# include the new signatures.
for BIN in \
  "$SPARKLE/XPCServices/Downloader.xpc" \
  "$SPARKLE/XPCServices/Installer.xpc" \
  "$SPARKLE/Updater.app" \
  "$SPARKLE/Autoupdate"; do
    [[ -e "$BIN" ]] || { echo "  ✗ missing: $BIN" >&2; exit 1; }
    echo "  · $BIN"
    codesign "${CODESIGN_FLAGS[@]}" "$BIN"
done

echo "→ Re-signing Sparkle framework"
codesign "${CODESIGN_FLAGS[@]}" "$APP_PATH/Contents/Frameworks/Sparkle.framework"

echo "→ Re-signing main app (with entitlements)"
codesign "${CODESIGN_FLAGS[@]}" \
  --entitlements Pits/Pits.entitlements \
  "$APP_PATH"

echo "→ Verifying"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "✓ App signed end-to-end"
