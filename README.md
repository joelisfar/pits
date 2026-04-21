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
