# Pits — Release Pipeline, Phase 1 Design

**Status:** Drafted 2026-04-22
**Target:** first tagged release under the new flow (likely v0.1.2)
**Successor:** Phase 2 (Developer ID signing, notarization, Sparkle auto-updates, GitHub Actions CI) — out of scope here, designed separately after Apple Developer enrollment clears.

## Problem

Pits has been shipped via PR merges to `main` with version numbers in PR titles (e.g. `v0.1.1: row layout polish + ai-title fallback (#14)`), but there is no distributable artifact and no release channel. `MARKETING_VERSION` in `project.yml` is stale (reads `0.1.0`; actual shipped state is `v0.1.1`). Only one git tag exists (`v0.0.1`), and the GitHub Releases page is empty. To use Pits on a work Mac, today, the only option is running `bash scripts/run.sh` in the repo.

The user wants to install Pits on an employer-issued MDM-managed Mac (unsigned apps allowed but must be explicitly Gatekeeper-approved on first launch) and have a clear, repeatable flow for shipping new versions.

An Apple Developer individual enrollment is pending ID verification — timeline unknown (24h in the best case, potentially weeks). Phase 1 is scoped to what can be delivered *without* Apple Developer credentials, so it is not blocked.

## Goals

1. A single command (`bash scripts/release.sh X.Y.Z`) that builds an unsigned `.dmg`, tags the commit, pushes, and publishes a GitHub Release with the `.dmg` attached.
2. `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` stay in sync with shipped tags after every release.
3. Work-Mac install flow: download `.dmg` → open → drag to `/Applications` → right-click → Open (one-time Gatekeeper prompt). No "hack a Gatekeeper override" scripts — the user has accepted this tradeoff.
4. The release script is structured so Phase 2 additions (codesign, notarytool, appcast generation, CI) slot in without rewriting.

## Non-goals

- Code signing with a real Developer ID certificate (Phase 2).
- Notarization via `xcrun notarytool` (Phase 2).
- In-app auto-update via Sparkle (Phase 2).
- GitHub Actions CI for releases (Phase 2).
- Homebrew cask, Mac App Store, or any other distribution channel.
- Delta updates, rollback, or multi-track (beta/stable) releases.
- A release-notes authoring tool beyond `gh release create --generate-notes`.
- Pre-release / RC builds. Every tag is a production release.

## Architecture

One new shell script, `scripts/release.sh`, plus a small edit to `project.yml`. No new Swift code in Phase 1. No new application dependencies.

The script has six phases, each a discrete function, failing fast with `set -euo pipefail`:

```
release.sh X.Y.Z
  preflight()    → fail if tree/branch/remote/auth/tag/version invalid
  bump_version() → edit project.yml, xcodegen, assert clean build of project
  build_release()→ xcodebuild Release into temp DerivedData, locate Pits.app
  package_dmg()  → hdiutil create Pits-X.Y.Z.dmg with /Applications symlink
  tag_and_push() → git commit project.yml + tag + push main + tags
  publish()      → gh release create with generated notes + .dmg asset
```

Phase separation matters for Phase 2: codesigning slots between `build_release` and `package_dmg`; notarization + stapling slots into `package_dmg`; appcast generation slots between `package_dmg` and `publish`.

## Components

### `scripts/release.sh` (new)

Bash, `set -euo pipefail`, `IFS=$'\n\t'`. Runs from repo root via `cd "$(dirname "$0")/.."`.

**Invocation:**

```sh
bash scripts/release.sh 0.1.2
```

Single required argument: the semantic version. No flags in Phase 1.

**`preflight(version)`** — fails with clear error message on any of:

- `version` does not match `^[0-9]+\.[0-9]+\.[0-9]+$`
- Current branch is not `main`
- Working tree is not clean (`git status --porcelain` non-empty)
- Local `main` is not in sync with `origin/main` (run `git fetch origin`, then compare `HEAD` to `origin/main`)
- Tag `vX.Y.Z` already exists locally or on remote
- Supplied version is not strictly greater than the current `MARKETING_VERSION` in `project.yml` (semantic compare, not lexical)
- `gh auth status` fails
- `xcodegen`, `xcodebuild`, `hdiutil`, `gh`, `git` not on PATH

**`bump_version(version)`** — edits `project.yml` in place using `sed` against these exact line patterns:

- `^    MARKETING_VERSION: "..."` → `"X.Y.Z"`
- `^    CURRENT_PROJECT_VERSION: "N"` → `"N+1"` (monotonic integer; Sparkle will need this in Phase 2 for build-number comparison)

The indentation anchor (`^    `) prevents matching any future occurrences of these strings elsewhere in the file (e.g. in comments).

Then runs `xcodegen generate` to regenerate `Pits.xcodeproj`. Leaves the edits unstaged — `tag_and_push` commits them later, so a mid-script failure leaves the tree in a diffable state.

**`build_release()`** — runs:

```sh
xcodebuild \
  -project Pits.xcodeproj \
  -scheme Pits \
  -configuration Release \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath build/release \
  clean build
```

Using a local `build/release` directory (instead of the default `~/Library/Developer/Xcode/DerivedData`) keeps the artifact path predictable and avoids interaction with any dev builds. `build/` is added to `.gitignore` as part of this change.

Locates the built app at `build/release/Build/Products/Release/Pits.app`. Fails if missing.

**`package_dmg(version)`** — produces `dist/Pits-X.Y.Z.dmg`:

1. Create a staging directory `build/dmg-staging/`.
2. Copy `Pits.app` into it.
3. Create a symlink `Applications -> /Applications` inside the staging dir (the drag-target.)
4. `hdiutil create -volname "Pits X.Y.Z" -srcfolder build/dmg-staging -ov -format UDZO dist/Pits-X.Y.Z.dmg`

UDZO = compressed read-only DMG, the standard Mac distribution format. Volume name appears as the Finder window title when the DMG is mounted.

No background image, no custom window layout in Phase 1. (The drag-to-Applications visual requires AppleScript window-position hacks that are brittle; skipping until there's reason to invest.)

`dist/` is also added to `.gitignore`.

**`tag_and_push(version)`** — sequential. The script fails loudly at the first error; recovery is manual via the hint printed to stderr. There is no transactional guarantee across git/gh, and none is needed — the recovery state is always diagnosable.

```sh
git add project.yml Pits.xcodeproj
git commit -m "release: v$VERSION"
git tag "v$VERSION"
git push origin main "v$VERSION"
```

Commits the xcodeproj regeneration alongside `project.yml` so a checkout of the tag builds cleanly without a local `xcodegen` step. `git push origin main "v$VERSION"` pushes both in one call; if this fails, the tag exists locally but not remotely — the script prints a recovery hint (`git push origin main v$VERSION`).

**`publish(version)`**:

```sh
gh release create "v$VERSION" \
  --title "v$VERSION" \
  --generate-notes \
  "dist/Pits-$VERSION.dmg"
```

`--generate-notes` fills the release body from PRs merged since the previous tag. The user's PR titles already carry version + topic (`v0.1.1: row layout polish + ai-title fallback (#14)`) so auto-generated notes are coherent without hand-editing.

### `project.yml` edits

- Bump `MARKETING_VERSION: "0.1.0"` → `"0.1.1"` in this change (aligning the in-repo value with the already-shipped `v0.1.1` tag). The first run of `release.sh 0.1.2` will bump it to `0.1.2`.
- Bump `CURRENT_PROJECT_VERSION: "1"` → `"2"` (monotonic — we've shipped before).

### `.gitignore` addition

```
build/
dist/
```

### `README.md` addition

A short **Releasing** section documenting:

- Prerequisite: `gh auth login` done, `xcodegen`/`hdiutil`/`git` on PATH (all already present).
- The one command: `bash scripts/release.sh X.Y.Z`.
- Install flow for end users: download `Pits-X.Y.Z.dmg` from [the releases page](https://github.com/joelisfar/pits/releases) → open → drag to `/Applications` → right-click `Pits.app` → Open → confirm Gatekeeper prompt (first launch only).
- Note: "This binary is not signed or notarized yet. Phase 2 will fix this."

## Data flow

### Normal release

1. Developer finishes a PR, squash-merges to `main`, pulls.
2. Runs `bash scripts/release.sh 0.1.2`.
3. Script preflights, bumps, builds, packages, commits, tags, pushes, and publishes — ~2–3 minutes depending on build cache.
4. Release page shows `v0.1.2` with `Pits-0.1.2.dmg` attached and auto-generated notes.

### End-user install

1. Download `Pits-0.1.2.dmg` from [releases](https://github.com/joelisfar/pits/releases).
2. Double-click → mount → drag `Pits.app` to `Applications`.
3. Eject DMG.
4. First launch: right-click `Pits.app` in `/Applications` → Open → "macOS cannot verify the developer…" sheet → Open. Subsequent launches are clean.

### Updating to a newer version (Phase 1)

1. User hears (via whatever channel) that a new release exists, or notices they haven't checked in a while.
2. Repeat the install flow. `.dmg` overwrites the existing `Pits.app` in `/Applications`. No migration — state lives in `~/Library/Caches/`, untouched.

Phase 2 will replace this manual step with Sparkle auto-update.

## Error handling

| Failure | Script behavior |
|---|---|
| Invalid version arg | Exit 1 with "Version must match X.Y.Z; got: …" before any mutation |
| Not on `main` | Exit 1 with "Release must run from main (currently on <branch>)" |
| Dirty tree | Exit 1 with `git status --porcelain` output |
| Behind remote | Exit 1 with "Local main is behind origin/main — pull first" |
| Tag exists | Exit 1 with "Tag vX.Y.Z already exists (local or remote)" |
| Version not greater | Exit 1 with "X.Y.Z is not greater than current MARKETING_VERSION (A.B.C)" |
| `gh auth status` fails | Exit 1 with "Run `gh auth login` first" |
| `xcodebuild` fails | xcodebuild output shown, exit 1. `project.yml` edits remain in working tree (uncommitted) so the failure is diagnosable |
| `hdiutil` fails | Exit 1. Same as above — tree is inspectable |
| `git push` fails after local tag created | Exit 1 with recovery hint: "Local tag created but not pushed. Run: `git push origin main vX.Y.Z`" |
| `gh release create` fails after push | Exit 1 with recovery hint: "Tag pushed. Create release manually: `gh release create vX.Y.Z --generate-notes --title 'vX.Y.Z' dist/Pits-X.Y.Z.dmg`" |

The script is **not** idempotent. Re-running after a mid-flight failure is the developer's judgment call — fix the underlying issue, then either retry (if nothing external changed) or clean up (if tag was created but push failed, etc.). The recovery hints surface exactly what state the world is in at each failure point.

## Testing

Phase 1 has no unit tests — it's a shell script whose main correctness surface is "does it produce a working `.dmg` and GitHub release." Manual validation is the primary gate.

**Manual validation plan (first run = v0.1.2):**

1. Dry-run-equivalent: read through the finished script end-to-end before the first run. Verify every `set` flag, every `sed` replacement pattern, every `gh` invocation by eye.
2. Run `bash scripts/release.sh 0.1.2` on a clean `main` checkout.
3. Verify:
   - `project.yml` shows `MARKETING_VERSION: "0.1.2"`, `CURRENT_PROJECT_VERSION: "3"` (was `2` after the alignment bump)
   - `git log -1` shows `release: v0.1.2`, commit includes `project.yml` and regenerated `Pits.xcodeproj`
   - `git tag` shows `v0.1.2`
   - `origin/main` and `origin/v0.1.2` both match local
   - [Releases page](https://github.com/joelisfar/pits/releases) shows `v0.1.2` with `Pits-0.1.2.dmg` attached
   - Auto-generated notes mention the PRs merged between `v0.0.1` (previous tag) and `v0.1.2` — or fall back sensibly if the PR history is thin
4. Install flow on personal Mac:
   - Download the .dmg from the browser
   - Mount, drag to `/Applications`
   - Right-click → Open, accept Gatekeeper
   - App launches, `~/Library/Caches/state.json` hydrates, live turns flow
5. Install flow on work Mac:
   - Same as 4, plus: any MDM dialogs surfacing before or after Gatekeeper
   - Verify `~/Library/Caches/` exists and is writable in the MDM profile

**Preflight-failure coverage** (run the script, expect exit-1 with useful message, then recover):

- Pass `0.1` instead of `0.1.2` (bad format)
- Run from a feature branch
- Leave a dirty tree
- Pass `0.1.0` (equal to current) or `0.0.5` (less than current)
- Pre-create tag `v0.1.2` locally, then run

Each of these should exit cleanly before mutating anything.

**Script-under-version-control check:** after first successful run, rerun `bash scripts/release.sh 0.1.3` on a synthetic "no changes on main yet" state — verify it exits on "no PRs since last release" (or produces an empty-but-valid release, acceptable either way — `gh --generate-notes` handles no-PRs gracefully).

## Out of scope (Phase 2 teaser, for planning continuity)

- `codesign --options runtime --sign "Developer ID Application: …"` inside `build_release` (or after it, before packaging)
- `xcrun notarytool submit … --wait` + `xcrun stapler staple` inside `package_dmg` (after `hdiutil create`)
- Sparkle framework as SwiftPM dep; `SPUStandardUpdaterController` wired into `PitsApp.swift`; `SUFeedURL` + `SUPublicEDKey` in `Info.plist`
- `generate_appcast` (Sparkle tool) producing `appcast.xml`, committed to repo, consumed at `https://raw.githubusercontent.com/joelisfar/pits/main/appcast.xml`
- `.github/workflows/release.yml` triggered on `v*` tag push, running the full signed pipeline with secrets for Developer ID P12 + password + EdDSA private key + notarytool app-specific password

Each of those slots into the Phase 1 structure without moving existing phases around — verified by the function boundaries above.
