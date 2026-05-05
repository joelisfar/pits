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

# Base flags for every codesign call. --options=runtime + --timestamp are
# required for notarization. The main app gets explicit --entitlements;
# Sparkle nested binaries get --preserve-metadata so their original
# entitlements (XPC service declarations, etc.) survive the re-sign.
BASE_FLAGS=(--force --options=runtime --timestamp --sign "$IDENTITY")

# Detect any unexpected executables in Sparkle.framework. If a future
# Sparkle release adds a new helper or XPC service we don't know about,
# notarization would silently fail because we wouldn't re-sign it. Force
# a human to look at the script before that ships.
KNOWN_NESTED=(
  "$SPARKLE/XPCServices/Downloader.xpc"
  "$SPARKLE/XPCServices/Installer.xpc"
  "$SPARKLE/Updater.app"
  "$SPARKLE/Autoupdate"
)

echo "→ Auditing Sparkle.framework for unknown nested executables"
# Use macOS-compatible bash 3.x (no mapfile). Find all .app and .xpc
# bundles + bare executable files at the framework's top level.
audit_unknown() {
  while IFS= read -r f; do
    local match=0
    for known in "${KNOWN_NESTED[@]}"; do
      if [[ "$f" == "$known" ]]; then match=1; break; fi
    done
    if [[ $match -eq 0 ]]; then
      echo "  ✗ unknown nested binary in Sparkle.framework: $f" >&2
      echo "    sign_app.sh has not been updated for this Sparkle release." >&2
      echo "    Add it to KNOWN_NESTED and verify it gets re-signed correctly." >&2
      exit 1
    fi
  done
}

{
  find "$SPARKLE" -maxdepth 4 -type d \( -name '*.app' -o -name '*.xpc' \) 2>/dev/null
  # Bare executables at framework top level; exclude the main Sparkle
  # dylib (signed separately as the framework root).
  find "$SPARKLE" -maxdepth 2 -type f -perm +111 ! -name 'Sparkle' 2>/dev/null
} | audit_unknown
echo "  ✓ all nested binaries are accounted for"

echo "→ Re-signing Sparkle nested binaries"
# Order matters: sign deepest items first so containing bundles' hashes
# include the new signatures. Use --preserve-metadata so Sparkle's XPC
# service entitlements (sandbox, library-validation flags, etc.) survive.
for BIN in "${KNOWN_NESTED[@]}"; do
  [[ -e "$BIN" ]] || { echo "  ✗ missing: $BIN" >&2; exit 1; }
  echo "  · $BIN"
  codesign "${BASE_FLAGS[@]}" \
    --preserve-metadata=identifier,entitlements,flags \
    "$BIN"
done

echo "→ Re-signing Sparkle framework"
codesign "${BASE_FLAGS[@]}" "$APP_PATH/Contents/Frameworks/Sparkle.framework"

echo "→ Re-signing main app (with entitlements)"
codesign "${BASE_FLAGS[@]}" \
  --entitlements Pits/Pits.entitlements \
  "$APP_PATH"

echo "→ Verifying"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
echo "✓ App signed end-to-end"
