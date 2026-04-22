# Release Pipeline Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `scripts/release.sh X.Y.Z` — a single-command build-tag-publish pipeline that produces an unsigned `.dmg` on GitHub Releases. First real run produces `v0.1.2`.

**Architecture:** One new shell script with six phase-functions (`preflight`, `bump_version`, `build_release`, `package_dmg`, `tag_and_push`, `publish`). Minor edits to `project.yml`, `.gitignore`, `README.md`. No Swift or SwiftPM changes. Function boundaries leave room for Phase 2 additions (signing, notarization, Sparkle, CI) to slot in without rewrites.

**Tech Stack:** Bash, `xcodegen`, `xcodebuild`, `hdiutil`, `gh` CLI, `git`.

**Spec:** [docs/superpowers/specs/2026-04-22-release-pipeline-phase1-design.md](../specs/2026-04-22-release-pipeline-phase1-design.md)

---

## Preamble: working-tree hygiene

Before any task, check `git status`. If modified files are present from before the session (handoff gotcha #10: the session started with pre-existing unstaged modifications to `Pits/Models/Conversation.swift`, `PitsTests/ConversationTests.swift`, `docs/4-21-handoff-1.md`, and 7 icon PNGs), stash them with a descriptive message:

```sh
git stash push -m "pre-session stale WT (do not ship)" -- \
  Pits/Models/Conversation.swift \
  PitsTests/ConversationTests.swift \
  docs/4-21-handoff-1.md \
  Pits/Resources/Assets.xcassets/AppIcon.appiconset/
```

The working tree should be clean before creating the feature branch.

---

## File Structure

**Create:**
- `scripts/release.sh` — the release automation

**Modify:**
- `project.yml` — align `MARKETING_VERSION` (0.1.0 → 0.1.1) and `CURRENT_PROJECT_VERSION` (1 → 2) with already-shipped state
- `.gitignore` — add `build/`, `dist/`
- `README.md` — add "Releasing" section and "Install" section

---

## Branch

Create feature branch `release-pipeline-phase1` off a clean `main`. All tasks commit to this branch. The branch merges to `main` after Task 8. Task 9 runs the first release from `main`.

```sh
git checkout main
git pull origin main
git checkout -b release-pipeline-phase1
```

---

### Task 1: Align version metadata and gitignore

**Files:**
- Modify: `project.yml`
- Modify: `.gitignore`

**Why first:** Phase 1's spec calls out that `project.yml` is stale (reads `0.1.0`; actual shipped tag is `v0.1.1`). The release script's preflight check is `VERSION > current MARKETING_VERSION` — if we leave 0.1.0 in place, running `release.sh 0.1.1` would *succeed* and produce a duplicate tag. Aligning first means the first real run (`0.1.2`) starts from truth.

- [ ] **Step 1: Read current version lines**

Run: `grep -E '(MARKETING|CURRENT_PROJECT)_VERSION' project.yml`

Expected output:
```
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
```

- [ ] **Step 2: Edit `project.yml`**

Change `MARKETING_VERSION: "0.1.0"` → `"0.1.1"` and `CURRENT_PROJECT_VERSION: "1"` → `"2"`.

- [ ] **Step 3: Edit `.gitignore`**

Append (creating file if it doesn't exist; it does):

```
build/
dist/
```

- [ ] **Step 4: Regenerate xcodeproj and verify build**

```sh
xcodegen generate
xcodebuild -project Pits.xcodeproj -scheme Pits \
  -destination "platform=macOS,arch=$(uname -m)" \
  -configuration Debug build -quiet
```

Expected: both succeed with no errors.

- [ ] **Step 5: Commit**

```sh
git add project.yml .gitignore Pits.xcodeproj
git commit -m "chore: align project.yml versions with shipped v0.1.1; ignore build/ and dist/"
```

---

### Task 2: Skeleton `release.sh` + preflight

**Files:**
- Create: `scripts/release.sh`

This task writes the complete file structure and fleshes out `preflight()` only. Other functions are stubs that `echo` their name so we can trace the full flow. We validate preflight exhaustively before adding real build/package/publish logic.

- [ ] **Step 1: Create `scripts/release.sh` with skeleton + preflight + stubs**

Write exactly this content:

```bash
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
```

- [ ] **Step 2: Make executable**

```sh
chmod +x scripts/release.sh
```

- [ ] **Step 3: Test — happy path on current branch**

We're on `release-pipeline-phase1`, so preflight's branch check should fail. Run:

```sh
bash scripts/release.sh 0.1.2
```

Expected: exits 1 with `✗ Release must run from main (currently on release-pipeline-phase1)`.

- [ ] **Step 4: Test — bad version formats**

```sh
bash scripts/release.sh
bash scripts/release.sh 0.1
bash scripts/release.sh v0.1.2
bash scripts/release.sh 0.1.2-beta
```

Expected: each exits 1 with a specific message about usage or version format. No file mutations.

- [ ] **Step 5: Test — temporarily on main (no mutations expected)**

```sh
git checkout main
bash scripts/release.sh 0.1.1
```

Expected: `✗ 0.1.1 is not greater than current MARKETING_VERSION (0.1.1)`.

```sh
bash scripts/release.sh 0.1.2
```

Expected: stub functions echo their names in order, then `✓ Released v0.1.2`. **No real changes — all post-preflight functions are stubs.**

Switch back to the feature branch:

```sh
git checkout release-pipeline-phase1
```

- [ ] **Step 6: Commit**

```sh
git add scripts/release.sh
git commit -m "feat(release): skeleton + preflight in scripts/release.sh"
```

---

### Task 3: Implement `bump_version()`

**Files:**
- Modify: `scripts/release.sh`

- [ ] **Step 1: Replace the `bump_version` stub with the real implementation**

Find this in `scripts/release.sh`:

```bash
bump_version() {
  echo "→ bump_version (stub)"
}
```

Replace with:

```bash
bump_version() {
  echo "→ bump_version"

  local current_project_version new_project_version
  current_project_version=$(grep -E '^    CURRENT_PROJECT_VERSION:' project.yml \
                            | sed -E 's/.*"([0-9]+)".*/\1/')
  [[ -n "$current_project_version" ]] \
    || die "Could not read CURRENT_PROJECT_VERSION from project.yml"
  new_project_version=$((current_project_version + 1))

  # BSD sed (macOS): -i '' for in-place with no backup.
  sed -i '' -E "s/^(    MARKETING_VERSION: )\"[^\"]+\"/\1\"$VERSION\"/" project.yml
  sed -i '' -E "s/^(    CURRENT_PROJECT_VERSION: )\"[^\"]+\"/\1\"$new_project_version\"/" project.yml

  xcodegen generate >/dev/null

  echo "  MARKETING_VERSION=$VERSION CURRENT_PROJECT_VERSION=$new_project_version"
}
```

- [ ] **Step 2: Dry-test bump_version in isolation**

Verify the sed edits work without committing anything. Use a subshell so `source` pollution doesn't leak, and source both `die()` (the function's dependency) and `bump_version()`:

```sh
cp project.yml /tmp/project.yml.backup
cp Pits.xcodeproj/project.pbxproj /tmp/project.pbxproj.backup

(
  set -euo pipefail
  VERSION=9.9.9
  source <(sed -n '/^die()/,/^}/p' scripts/release.sh)
  source <(sed -n '/^bump_version()/,/^}/p' scripts/release.sh)
  bump_version
)

grep -E '(MARKETING|CURRENT_PROJECT)_VERSION' project.yml
```

Expected:
```
    MARKETING_VERSION: "9.9.9"
    CURRENT_PROJECT_VERSION: "3"
```

(`3` because the alignment in Task 1 set it to `2`, and bump incremented.)

- [ ] **Step 3: Restore**

```sh
mv /tmp/project.yml.backup project.yml
mv /tmp/project.pbxproj.backup Pits.xcodeproj/project.pbxproj
grep -E '(MARKETING|CURRENT_PROJECT)_VERSION' project.yml
git status
```

Expected:
```
    MARKETING_VERSION: "0.1.1"
    CURRENT_PROJECT_VERSION: "2"
```

and `git status` clean (no `M` lines).

- [ ] **Step 4: Commit**

```sh
git add scripts/release.sh
git commit -m "feat(release): implement bump_version"
```

---

### Task 4: Implement `build_release()`

**Files:**
- Modify: `scripts/release.sh`

- [ ] **Step 1: Replace the `build_release` stub**

Find:

```bash
build_release() {
  echo "→ build_release (stub)"
}
```

Replace with:

```bash
build_release() {
  echo "→ build_release (this takes ~30s on a warm cache)"

  rm -rf build/release

  xcodebuild \
    -project Pits.xcodeproj \
    -scheme Pits \
    -configuration Release \
    -destination "platform=macOS,arch=$(uname -m)" \
    -derivedDataPath build/release \
    clean build \
    >/dev/null

  APP_PATH="build/release/Build/Products/Release/Pits.app"
  [[ -d "$APP_PATH" ]] \
    || die "Built app not found at $APP_PATH"

  echo "  $APP_PATH"
}
```

- [ ] **Step 2: Dry-test by invoking the function standalone**

```sh
(
  set -euo pipefail
  source <(sed -n '/^die()/,/^}/p' scripts/release.sh)
  source <(sed -n '/^build_release()/,/^}/p' scripts/release.sh)
  build_release
)

ls -la build/release/Build/Products/Release/Pits.app
```

Expected: `Pits.app` directory exists, containing `Contents/MacOS/Pits`.

- [ ] **Step 3: Verify the built app actually runs**

```sh
open build/release/Build/Products/Release/Pits.app
```

Expected: Pits launches. Close it.

- [ ] **Step 4: Clean up build artifacts and commit**

```sh
rm -rf build/
git status
```

Expected: only `scripts/release.sh` modified (build/ is gitignored from Task 1).

```sh
git add scripts/release.sh
git commit -m "feat(release): implement build_release"
```

---

### Task 5: Implement `package_dmg()`

**Files:**
- Modify: `scripts/release.sh`

- [ ] **Step 1: Replace the `package_dmg` stub**

Find:

```bash
package_dmg() {
  echo "→ package_dmg (stub)"
}
```

Replace with:

```bash
package_dmg() {
  echo "→ package_dmg"

  local staging="build/dmg-staging"
  rm -rf "$staging" dist
  mkdir -p "$staging" dist

  cp -R "$APP_PATH" "$staging/"
  ln -s /Applications "$staging/Applications"

  DMG_PATH="dist/Pits-$VERSION.dmg"
  hdiutil create \
    -volname "Pits $VERSION" \
    -srcfolder "$staging" \
    -ov -format UDZO \
    "$DMG_PATH" \
    >/dev/null

  [[ -f "$DMG_PATH" ]] \
    || die "DMG not created at $DMG_PATH"

  echo "  $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
}
```

- [ ] **Step 2: Dry-test package_dmg standalone**

Requires `APP_PATH` and `VERSION` to be set.

```sh
(
  set -euo pipefail
  VERSION=9.9.9
  source <(sed -n '/^die()/,/^}/p' scripts/release.sh)
  source <(sed -n '/^build_release()/,/^}/p' scripts/release.sh)
  source <(sed -n '/^package_dmg()/,/^}/p' scripts/release.sh)
  build_release
  package_dmg
)

ls -la dist/
```

Expected: `dist/Pits-9.9.9.dmg` exists, ~5-20MB.

- [ ] **Step 3: Mount the DMG and verify contents**

```sh
hdiutil attach dist/Pits-9.9.9.dmg
ls /Volumes/Pits\ 9.9.9/
```

Expected: `Pits.app` and `Applications` (symlink) visible.

```sh
hdiutil detach /Volumes/Pits\ 9.9.9/
```

- [ ] **Step 4: Clean up and commit**

```sh
rm -rf build/ dist/
git add scripts/release.sh
git commit -m "feat(release): implement package_dmg"
```

---

### Task 6: Implement `tag_and_push()` and `publish()`

**Files:**
- Modify: `scripts/release.sh`

These two are not dry-testable without mutating remote state — they're validated during the first real run in Task 9.

- [ ] **Step 1: Replace the `tag_and_push` stub**

Find:

```bash
tag_and_push() {
  echo "→ tag_and_push (stub)"
}
```

Replace with:

```bash
tag_and_push() {
  echo "→ tag_and_push"

  git add project.yml Pits.xcodeproj
  git commit -m "release: v$VERSION"
  git tag "v$VERSION"

  if ! git push origin main "v$VERSION"; then
    die "Push failed. Recover with: git push origin main v$VERSION"
  fi

  echo "  pushed main + tag v$VERSION to origin"
}
```

- [ ] **Step 2: Replace the `publish` stub**

Find:

```bash
publish() {
  echo "→ publish (stub)"
}
```

Replace with:

```bash
publish() {
  echo "→ publish"

  if ! gh release create "v$VERSION" \
    --title "v$VERSION" \
    --generate-notes \
    "$DMG_PATH"; then
    die "Release creation failed. Recover with: gh release create v$VERSION --generate-notes --title v$VERSION $DMG_PATH"
  fi

  echo "  https://github.com/joelisfar/pits/releases/tag/v$VERSION"
}
```

- [ ] **Step 3: Sanity-check the script compiles**

```sh
bash -n scripts/release.sh
```

Expected: no output (successful parse).

- [ ] **Step 4: Commit**

```sh
git add scripts/release.sh
git commit -m "feat(release): implement tag_and_push and publish"
```

---

### Task 7: README — Releasing and Install sections

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Read current README**

```sh
cat README.md
```

- [ ] **Step 2: Add an "Install" section below the existing "Run" section**

Insert this text (after the `## Run` section, before `## Test`):

```markdown
## Install (for end users)

Download the latest `.dmg` from the [releases page](https://github.com/joelisfar/pits/releases):

1. Open the downloaded `Pits-X.Y.Z.dmg`.
2. Drag `Pits.app` into the `Applications` folder shown in the window.
3. Eject the DMG.
4. First launch: right-click `Pits.app` in `/Applications` → **Open** → confirm the "cannot verify the developer" prompt. This is a one-time step because the app is not yet signed — this will go away once the Apple Developer account clears and Phase 2 ships.

State lives in `~/Library/Caches/state.json` and `~/Library/Caches/pricing.json`. Updating by installing a newer DMG preserves state.
```

- [ ] **Step 3: Add a "Releasing" section at the bottom**

Append:

```markdown
## Releasing

Requires `gh auth login` and the tools from the Build section on PATH.

```sh
bash scripts/release.sh X.Y.Z
```

This builds a Release-configuration `.app`, packages it as `Pits-X.Y.Z.dmg`, bumps the versions in `project.yml`, commits, tags `vX.Y.Z`, pushes, and creates a GitHub Release with auto-generated notes from merged PRs.

The script must run from a clean `main` that's in sync with `origin/main`. It refuses to run otherwise.

The current Phase 1 pipeline produces **unsigned** binaries — users must right-click → Open on first launch. Phase 2 will add Developer ID signing, notarization, and Sparkle auto-update.
```

- [ ] **Step 4: Commit**

```sh
git add README.md
git commit -m "docs: README install + releasing sections"
```

---

### Task 8: Open PR, merge, clean up branch

**Files:** none (git operations)

- [ ] **Step 1: Push branch**

```sh
git push -u origin release-pipeline-phase1
```

- [ ] **Step 2: Open PR**

```sh
gh pr create \
  --title "feat: release pipeline Phase 1" \
  --body "$(cat <<'EOF'
## Summary
- New `scripts/release.sh X.Y.Z` — one-command build, package, tag, and publish of an unsigned `.dmg` to GitHub Releases
- Aligns `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` in `project.yml` with already-shipped `v0.1.1`
- README gets Install and Releasing sections

Spec: `docs/superpowers/specs/2026-04-22-release-pipeline-phase1-design.md`
Plan: `docs/superpowers/plans/2026-04-22-release-pipeline-phase1.md`

Phase 2 (signing, notarization, Sparkle, CI) is deferred until the Apple Developer account clears and will slot into the existing phase-function structure without rewrites.

## Test plan
- [x] Preflight failure modes (bad version, not-main, dirty tree, version-not-greater) manually verified in Task 2
- [x] `bump_version` verified against known-good `project.yml` in Task 3
- [x] `build_release` verified by launching the built app in Task 4
- [x] `package_dmg` verified by mounting the DMG in Task 5
- [ ] First real release (`v0.1.2`) happens in Task 9 post-merge

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Squash-merge via gh**

Wait for any checks to settle (none are wired today, so it merges immediately), then:

```sh
gh pr merge --squash --delete-branch
```

- [ ] **Step 4: Sync local main**

```sh
git checkout main
git pull origin main
git branch -d release-pipeline-phase1 2>/dev/null || true
```

Expected: local `main` now contains the release script. Working tree clean.

- [ ] **Step 5: Restore pre-session stash if stashed in preamble**

```sh
git stash list
```

If the stash from the preamble exists, leave it alone — it's not this task's concern.

---

### Task 9: First real release — v0.1.2

**Files:** none (runs the pipeline)

This is the integration test. Everything before this was setup.

- [ ] **Step 1: Preflight one more time from the outside**

Run preflight with a bogus version to confirm the merged script on main behaves:

```sh
bash scripts/release.sh 0.0.5
```

Expected: `✗ 0.0.5 is not greater than current MARKETING_VERSION (0.1.1)`.

- [ ] **Step 2: Execute the release**

```sh
bash scripts/release.sh 0.1.2
```

Expected output (timing approximate):

```
→ preflight
  version 0.1.2 is valid; current is 0.1.1
→ bump_version
  MARKETING_VERSION=0.1.2 CURRENT_PROJECT_VERSION=3
→ build_release (this takes ~30s on a warm cache)
  build/release/Build/Products/Release/Pits.app
→ package_dmg
  dist/Pits-0.1.2.dmg (8.4M)
→ tag_and_push
  pushed main + tag v0.1.2 to origin
→ publish
  https://github.com/joelisfar/pits/releases/tag/v0.1.2
✓ Released v0.1.2
```

- [ ] **Step 3: Verify repo state**

```sh
grep -E '(MARKETING|CURRENT_PROJECT)_VERSION' project.yml
git log -1 --oneline
git tag --list 'v0.1.*'
```

Expected:
```
    MARKETING_VERSION: "0.1.2"
    CURRENT_PROJECT_VERSION: "3"
<hash> release: v0.1.2
v0.1.2
```

- [ ] **Step 4: Verify release on GitHub**

```sh
gh release view v0.1.2
```

Expected: release exists, body contains auto-generated notes referencing recently merged PRs (#13, #14, #15 presumably), `Pits-0.1.2.dmg` attached as asset.

- [ ] **Step 5: Install on personal Mac**

Download the `.dmg` from the [releases page](https://github.com/joelisfar/pits/releases) in a browser (don't just `cp dist/...` — we want to exercise the real user flow).

1. Open the downloaded `.dmg`.
2. Drag `Pits.app` to `/Applications`.
3. Right-click `Pits.app` in `/Applications` → Open.
4. "cannot verify the developer" prompt → Open.
5. App launches, live conversations appear within a second or two.

- [ ] **Step 6: Install on work Mac**

Repeat Step 5's flow on the employer-issued MDM-managed Mac.

Expected: may see an additional MDM-layer prompt before or after Gatekeeper; right-click → Open should still work because the Mac allows unsigned apps.

If this step fails on the work Mac (unsigned apps actually blocked), Phase 1 delivery on the work Mac is blocked on Phase 2. Phase 1 is still complete on its own terms — this is an unknown-until-tested risk.

---

## Self-Review

**Spec coverage:**
- Goal 1 (single command) → Tasks 2–7 build the script, Task 9 runs it ✓
- Goal 2 (versions stay in sync) → Task 1 aligns, Task 3's `bump_version` maintains ✓
- Goal 3 (work-Mac install flow) → Task 9 Step 6 ✓
- Goal 4 (Phase 2 slots in) → function boundaries preserved across Tasks 2, 4, 5, 6 ✓
- Non-goal compliance: no codesign, no notarytool, no Sparkle, no CI, no Homebrew, no pre-releases ✓
- Error-handling table: each row corresponds to a `die` call in the script ✓

**Placeholder scan:** No TBDs, no "similar to Task N", all code blocks complete, all commands explicit.

**Type/name consistency:** `APP_PATH` and `DMG_PATH` are set in `build_release` / `package_dmg` and consumed by `publish`. Declared as script-level globals at the top of the file so the `set -u` flag doesn't trip on them before they're set.
