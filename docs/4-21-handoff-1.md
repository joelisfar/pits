# Pits — Handoff for the Next Session

**Current state:** v1 shipped. On `main` at `f4e40dd` (squash of PR #1). Working tree clean. 48 tests pass. App builds and runs.

**Repo:** `/Users/jifarris/Projects/pits`. Remote: `joelisfar/pits`.

**To build/test/run, see `README.md`.** Summary: `xcodegen generate && xcodebuild -project Pits.xcodeproj -scheme Pits -destination 'platform=macOS' test`.

---

## Known v1.1 follow-ups (in priority order)

### 1. Backfill floods the main thread → UI beach-balls on heavy users

**Observed symptom:** on the author's workstation (years of Claude Code history, several GB of JSONL), launching Pits shows rows correctly but the window beach-balls for minutes. Root cause documented in the final code review at PR #1.

**Why it happens:** `LogWatcher.onLine` fires per line during backfill. The store's handler does `DispatchQueue.main.async { handleLine(url:line:) }` per line, then `handleLine` runs a synchronous `rebuildSnapshot()` AND the parser's `onSessionUpdated` dispatches ANOTHER async rebuild. For N sessions × M total turns that's O(N·M) work per ingest, multiplied by thousands of queued closures.

**The fix (~30-50 lines):**

- **`Pits/Services/LogWatcher.swift`:** in `readNewBytes(from:)`, instead of calling `onLine?(url, line)` per line, collect all lines from one rescan pass into an array and call a new `onLines: ((URL, [String]) -> Void)?` callback once per file per scan.
- **`Pits/Stores/ConversationStore.swift`:** replace the per-line handler with one that accepts `[String]`, loops through them, calls `parser.ingest` for each, and calls `rebuildSnapshot()` once at the end of the batch.
- **Also drop the redundant `parser.onSessionUpdated` async rebuild** — under batching, one rebuild per batch is enough. Either remove the handler assignment in `init`, or have it do nothing.
- Keep the `onLine` single-line API around as a thin wrapper if any existing test depends on it (the current Task 7 tests do), or update the tests to use `onLines`.

**Verify:** run `scripts/smoke-fake-session.sh` and confirm the new row still appears within ~1s. Run the full test suite. Launch the app and confirm it's snappy from first frame.

### 2. README doesn't mention the smoke script

Add a "Smoke test / manual QA" section to `README.md` pointing at `scripts/smoke-fake-session.sh` and documenting the cleanup step (`rm -rf ~/.claude/projects/-tmp-pits-smoke`).

### 3. App icon is a placeholder

`Pits/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` declares all the icon slots but has no image assets. The original starter spec suggested "a fire pit glyph or stylized flames." Draw or commission one; drop the PNG sizes into the appiconset.

### 4. Minor cleanups noted by reviewers (optional polish)

- Remove the commented-out `.swiftpm` line at `.gitignore:30`; line 70 has the active one (duplicate noise).
- Add a one-line comment above `RunLoop.main.add(t, forMode: .common)` in `ConversationStore.startTimer()` explaining why `.common` mode matters (fires during window resize / menu tracking).
- ~~`Conversation.projectName(from:)` is lossy for literal-dash project paths.~~ Fixed: the decoder now walks split segments against the real filesystem and merges adjacent segments whenever the candidate prefix doesn't exist on disk, so a leaf like `one-two-three` is preserved instead of truncating to `three`.

---

## Gotchas the next agent should know

1. **Always re-run `xcodegen generate` after adding/removing `.swift` files.** The Xcode project is gitignored and regenerated from `project.yml`. Existing agents sometimes forget and then scratch their heads about "Cannot find X in scope."

2. **`PitsTests` target has `GENERATE_INFOPLIST_FILE: YES` override.** The project-level setting is `NO`, but the test target needs Xcode to synthesize one for code signing. If you regenerate `project.yml` from memory, don't drop this override. The comment in `project.yml` explains why.

3. **The XCTest-runner-hang trap.** `PitsApp.swift`'s `.onAppear { store.start() }` is guarded with a `ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil` check. Without this guard, `xcodebuild test` hangs for ~5 minutes then fails with "The test runner hung before establishing connection." Don't remove the guard thinking it's dead code — it's load-bearing for CI.

4. **macOS `/var` → `/private/var` symlink issue in `LogWatcher.discoverFiles()`.** The rebase logic there isn't overengineering — it's required because `FileManager.enumerator(at:)` resolves `/var` to `/private/var`, which makes the emitted URL differ lexically from what a caller constructs under `NSTemporaryDirectory()`. The plan's verbatim code would fail `test_backfill_readsAllExistingLines` on any standard macOS.

5. **FSEvents callback must call `rescanLocked()` directly, not `rescan()`.** The callback runs on the watcher's own `queue`; calling `rescan()` would `queue.sync` on that same serial queue → deadlock. Tests won't catch this because they never call `start()`; `test_liveStart_emitsLineOnAppend` is the regression test.

6. **FSEventStreamContext uses `passRetained` + a release callback.** Don't "simplify" to `passUnretained` — it races with `deinit` during app shutdown.

7. **`chimeCutoff` starts at `.distantFuture`.** This keeps the ingest path silent until `start()` is called. `ingestForTesting` relies on this. If you ever initialize it to `Date.distantPast` (or any finite date) in a constructor, every test will start firing chimes.

8. **Tests inject a silent `SoundManager`.** `ConversationStoreTests` uses `SoundManager(defaults: suiteDefaults, player: { _ in })` to avoid AppKit `NSSound` side effects during CI. If you add new store tests, follow this pattern.

---

## How to start a v1.1 session

Paste into the next chat:

> Follow the handoff doc at `/Users/jifarris/Projects/pits/docs/HANDOFF.md`. Start with v1.1 follow-up #1 (backfill main-thread flood). Open a new branch (`pits/v1.1-batching` is fine), use TDD, and open a PR when tests pass.

The next agent should have enough context from that + the handoff doc alone.
