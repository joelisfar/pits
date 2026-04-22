# Pits

A macOS app that monitors live Claude Code sessions, tracks cost, and keeps you aware of cache TTL.

## Build

Requires Xcode 15+, macOS 14+, and XcodeGen (`brew install xcodegen`).

```sh
xcodegen generate
xcodebuild -project Pits.xcodeproj -scheme Pits -destination 'platform=macOS' build
```

## Run

Open `Pits.xcodeproj` in Xcode and press ⌘R, or double-click the produced `Pits.app`.

## Install (for end users)

Download the latest `.dmg` from the [releases page](https://github.com/joelisfar/pits/releases):

1. Open the downloaded `Pits-X.Y.Z.dmg`.
2. Drag `Pits.app` into the `Applications` folder shown in the window.
3. Eject the DMG.
4. First launch: right-click `Pits.app` in `/Applications` → **Open** → confirm the "cannot verify the developer" prompt. One-time step; subsequent launches are clean. Signing + notarization will remove this step once the Apple Developer account clears (Phase 2).

State lives in `~/Library/Caches/state.json` and `~/Library/Caches/pricing.json`. Installing a newer DMG preserves state.

## Test

```sh
xcodebuild -project Pits.xcodeproj -scheme Pits -destination 'platform=macOS' test
```

## Data source

Pits reads JSONL session logs from `~/.claude/projects/`. No configuration required.

## Smoke test / manual QA

To verify Pits is picking up new turns without waiting for real Claude Code activity:

```sh
bash scripts/smoke-fake-session.sh
```

This appends a fabricated assistant turn to `~/.claude/projects/-tmp-pits-smoke/smoke.jsonl`. A new `smoke-sess` row should appear in Pits within about a second.

To clean up when you're done:

```sh
rm -rf ~/.claude/projects/-tmp-pits-smoke
```

## Releasing

Requires `gh auth login` and the tools from the Build section on PATH.

```sh
bash scripts/release.sh X.Y.Z
```

This builds a Release-configuration `.app`, packages it as `Pits-X.Y.Z.dmg`, bumps the versions in `project.yml`, commits, tags `vX.Y.Z`, pushes, and creates a GitHub Release with auto-generated notes from merged PRs.

The script must run from a clean `main` that's in sync with `origin/main`. It refuses to run otherwise.

Phase 1 produces **unsigned** binaries — users must right-click → Open on first launch. Phase 2 will add Developer ID signing, notarization, and Sparkle auto-update.
