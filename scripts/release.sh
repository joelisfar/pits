#!/usr/bin/env bash
# Build, package, tag, and publish an unsigned Pits release.
# Phase 1 — see docs/superpowers/specs/2026-04-22-release-pipeline-phase1-design.md
# Usage: bash scripts/release.sh X.Y.Z

set -euo pipefail
IFS=$'\n\t'

cd "$(dirname "$0")/.."

VERSION="${1:-}"
# Set by build_release + package_dmg for downstream phases to consume.
APP_PATH=""
DMG_PATH=""

die() {
  echo "✗ $1" >&2
  exit 1
}

version_gt() {
  # Returns 0 iff $1 > $2 by semver. Uses sort -V (BSD sort on macOS 12+).
  [[ "$1" == "$2" ]] && return 1
  local higher
  higher=$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)
  [[ "$higher" == "$1" ]]
}

preflight() {
  echo "→ preflight"

  [[ -n "$VERSION" ]] || die "Usage: bash scripts/release.sh X.Y.Z"
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "Version must match X.Y.Z; got: $VERSION"

  for tool in xcodegen xcodebuild hdiutil gh git; do
    command -v "$tool" >/dev/null \
      || die "$tool not on PATH"
  done

  gh auth status >/dev/null 2>&1 \
    || die "Run \`gh auth login\` first"

  local branch
  branch=$(git rev-parse --abbrev-ref HEAD)
  [[ "$branch" == "main" ]] \
    || die "Release must run from main (currently on $branch)"

  [[ -z $(git status --porcelain) ]] \
    || die "Working tree not clean:
$(git status --porcelain)"

  git fetch origin --quiet
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
    || die "Local main is not in sync with origin/main — pull first"

  if git rev-parse --verify --quiet "v$VERSION" >/dev/null \
     || git ls-remote --tags origin "v$VERSION" 2>/dev/null | grep -q .; then
    die "Tag v$VERSION already exists (local or remote)"
  fi

  local current
  current=$(grep -E '^    MARKETING_VERSION:' project.yml \
            | sed -E 's/.*"([0-9.]+)".*/\1/')
  [[ -n "$current" ]] || die "Could not read MARKETING_VERSION from project.yml"

  if ! version_gt "$VERSION" "$current"; then
    die "$VERSION is not greater than current MARKETING_VERSION ($current)"
  fi

  echo "  version $VERSION is valid; current is $current"
}

bump_version() {
  echo "→ bump_version (stub)"
}

build_release() {
  echo "→ build_release (stub)"
}

package_dmg() {
  echo "→ package_dmg (stub)"
}

tag_and_push() {
  echo "→ tag_and_push (stub)"
}

publish() {
  echo "→ publish (stub)"
}

main() {
  preflight
  bump_version
  build_release
  package_dmg
  tag_and_push
  publish

  echo "✓ Released v$VERSION"
}

main
