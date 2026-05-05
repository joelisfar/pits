#!/usr/bin/env bash
# Local-only tagging tool. Bumps version, asserts release notes, commits, tags, pushes.
# CI (.github/workflows/release.yml) takes it from there: build, sign, notarize, publish.
# Phase 2 — see docs/superpowers/specs/2026-05-04-release-pipeline-phase2-design.md
# Usage: bash scripts/release.sh X.Y.Z

set -euo pipefail
IFS=$'\n\t'

cd "$(dirname "$0")/.."

VERSION="${1:-}"

die() {
  echo "✗ $1" >&2
  exit 1
}

version_gt() {
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

  for tool in xcodegen gh git; do
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

  grep -q "^## v$VERSION$" RELEASE_NOTES.md \
    || die "RELEASE_NOTES.md is missing a '## v$VERSION' stanza — add one before tagging"

  echo "  version $VERSION valid; current is $current; release notes stanza found"
}

bump_version() {
  echo "→ bump_version"

  local current_project_version new_project_version
  current_project_version=$(grep -E '^    CURRENT_PROJECT_VERSION:' project.yml \
                            | sed -E 's/.*"([0-9]+)".*/\1/')
  [[ -n "$current_project_version" ]] \
    || die "Could not read CURRENT_PROJECT_VERSION from project.yml"
  new_project_version=$((current_project_version + 1))

  sed -i '' -E "s/^(    MARKETING_VERSION: )\"[^\"]+\"/\1\"$VERSION\"/" project.yml
  sed -i '' -E "s/^(    CURRENT_PROJECT_VERSION: )\"[^\"]+\"/\1\"$new_project_version\"/" project.yml

  xcodegen generate >/dev/null

  echo "  MARKETING_VERSION=$VERSION CURRENT_PROJECT_VERSION=$new_project_version"
}

tag_and_push() {
  echo "→ tag_and_push"

  git add project.yml
  git commit -m "release: v$VERSION"
  git tag "v$VERSION"

  if ! git push origin main "v$VERSION"; then
    die "Push failed. Recover with: git push origin main v$VERSION"
  fi

  echo "  pushed main + tag v$VERSION to origin"
}

print_ci_url() {
  echo ""
  echo "✓ Tag pushed. CI is now building, signing, notarizing, and publishing."
  echo "  Watch: https://github.com/joelisfar/pits/actions"
  echo "  Release will appear at: https://github.com/joelisfar/pits/releases/tag/v$VERSION"
  echo ""
  echo "  ETA: ~5–8 minutes."
}

main() {
  preflight
  bump_version
  tag_and_push
  print_ci_url
}

main
