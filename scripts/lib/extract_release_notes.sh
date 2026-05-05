#!/usr/bin/env bash
# Shared release-notes parser. Sourced by both scripts/release.sh
# (preflight: "does this stanza exist?") and .github/workflows/release.yml
# (extract this stanza for both the GH Release body and Sparkle's HTML
# rendering). Single source of truth keeps local + CI in sync as the
# RELEASE_NOTES format evolves.

# Stanza format:
#   ## vX.Y.Z
#   <body lines>
#   <blank>
#   ## vX.Y.Z-1
#   ...

# extract_release_notes_stanza VERSION FILE
# Prints the body of the `## VERSION` stanza in FILE (lines after the
# heading, up to the next `## ` heading or EOF). Exits 0 if found and
# the stanza had at least one body line; 1 otherwise.
extract_release_notes_stanza() {
  local version="$1" file="$2"
  awk -v v="## $version" '
    $0 == v {capture=1; next}
    capture && /^## / {exit}
    capture {print}
  ' "$file"
}

# release_notes_stanza_exists VERSION FILE
# Exits 0 if the `## VERSION` heading exists in FILE, 1 otherwise.
# Faster than extract when you only need a presence check.
release_notes_stanza_exists() {
  local version="$1" file="$2"
  grep -q "^## $version$" "$file"
}
