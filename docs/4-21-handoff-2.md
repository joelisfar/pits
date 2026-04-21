# Pits — Handoff for the Next Session (post v0.0.4)

**Current state:** v0.0.1 → v0.0.4 all shipped. On `main` at `cb2b5b3` (squash of PR #7). Working tree clean, 53 tests pass, app builds and runs snappy.

**Repo:** `/Users/jifarris/Projects/pits`. Remote: `joelisfar/pits`.

**Build/test/run:** `bash scripts/run.sh` rebuilds Debug and relaunches the app — this is the canonical local test loop, no Xcode needed. For just the test suite: `xcodegen generate && xcodebuild -project Pits.xcodeproj -scheme Pits -destination "platform=macOS,arch=$(uname -m)" test`.

**Tag:** `v0.0.1` points at the original v1 squash (`f4e40dd`). Subsequent versions are PR squash merges — feel free to add tags going forward.

---

## What shipped this session (PRs #2, #6, #7)

**v0.0.2** — fixed the launch beach-ball: `LogWatcher` now batches per-file; `ConversationStore` rebuilds once per batch; dropped redundant `parser.onSessionUpdated`. Added run.sh + smoke-test docs.

**v0.0.3** — session titles (parsed from `{"type":"ai-title",...}` JSONL entries), chime filter (only fires on final `stop_reason`, no more pings on every tool call), TTL setting simplified to a 5m / 1h Picker, "Keep window on top" setting, project label trimmed to leaf dir, bold titles, loading state spinner, default window 580×420.

**v0.0.4** — day-grouped layout with daily cost totals; initial load is a progressive 7-day window (one day at a time via `pendingLoadDays`/`runOneDayChunk` recursion); `Load 7 more days` capsule button; multi-select with status-bar aggregate (`X of Y selected · $Z.ZZ total`); subagent rollup via in-row chevron disclosure that reveals an aggregate `N subagent turns · $X.XX`; L/R arrow keys expand/collapse; clicking day headers / footer / load-more empty area clears selection; cache TTL now uses `lastTurnTimestamp` (resets on user send, not Claude's reply); `LogWatcher.minMtime` filters discovery; `CostFormat` is the single source of truth for `$X.XX`.

---

## Known follow-ups (in rough priority order)

### 1. Local cache (stale-while-revalidate) — the big one

**Why:** even with the day-window load, opening the app shows the loading spinner for several seconds while the first day's JSONLs are parsed. Cache it.

**The shape of the fix (~150 lines + tests):**

- Make `Conversation`, `Turn`, `HumanTurn`, `SessionTitle` conform to `Codable`.
- Persist a snapshot to `~/Library/Application Support/Pits/cache.json` (or similar) every time `rebuildSnapshot()` produces a different result.
- Persist `LogWatcher.offsets` (and `partials`?) to the same dir so we resume reading each JSONL at its known byte offset on next launch.
- On `init`: if a cache exists, load it into `conversations` synchronously — no spinner. Then call `start()` which begins live watching + a "tail from saved offsets" backfill in the background to reconcile.
- Edge cases: file shrunk/rotated (already handled in `LogWatcher.readNewBytes(from:)` — restart from 0), file removed (drop from offsets), session aged off the day window (drop from snapshot or re-include if its file is still in the active mtime range).

**Verify:** quit and reopen the app — list should appear instantly with no spinner. New turns from a live `claude` session should still arrive within ~1s (FSEvents). Smoke-test: `bash scripts/smoke-fake-session.sh`.

### 2. Pricing reporting is inaccurate

User flagged at the end of v0.0.3: "Pricing reporting clearly isn't working." Hasn't been investigated yet. Likely places to dig:
- `Pits/Services/Pricing.swift` — model name normalization, rate table
- `Conversation.totalCost` / `Turn.totalCost` — calculation
- `Conversation.estimatedNextTurnCost(at:)` — context-size + warm/cold rate selection
Check the displayed numbers against `gh-claude-costs` (the reference dashboard) on a known session.

### 3. Inset/rounded selection styling

The user wants Safari-History-style selection (inset from edges, rounded corners, subtle gray) but with proper sticky-push section headers. Tried during v0.0.4:
- `.listStyle(.sidebar)` → made the whole window translucent + broke headers
- `.listStyle(.inset)` → wonky sticky behavior ("zap" + double bottom border)
- Currently on `.listStyle(.plain)` which has correct sticky behavior but edge-to-edge selection

Real fix probably needs a custom row background that paints an inset rounded rect when selected, using `List` selection state inside each row. Or a `LazyVStack` + custom selection (loses native ⌘-click / shift-click — bigger surgery).

### 4. App icon is still a placeholder

`Pits/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` declares all the slots. No PNGs. From the original spec: "a fire pit glyph or stylized flames." Design work, not code.

### 5. Smaller polish ideas the user has raised

- Per-agent breakdown when expanding subagents (instead of just an aggregate). Would need `agentId` added to `Turn` and grouping in the view.
- Cost breakdown by model / human turns / cold turns (à la `gh-claude-costs-dashboard`).
- "Load more" smarter: load to month boundary, or by week label.

---

## Gotchas the next agent should know

(In addition to the existing 8 in `docs/4-21-handoff-1.md` — those are all still load-bearing.)

1. **Don't stack PRs and squash-merge.** When you squash + delete the base branch, GitHub auto-closes any dependent PR (irreversibly), and the leftover branch's history conflicts with main's single squash commit. The painful workaround is what produced PR #6 and #7: `git checkout main && git checkout -b X && git checkout origin/<old-branch> -- . && git commit && PR && squash-merge`. **Easier going forward: one branch per session, off the latest `main`. No stacking.**

2. **`LogWatcher.minMtime` is thread-safe via `queue.sync`.** The backing `_minMtime` must only be touched through the property accessor (which serializes via `queue`). The watcher's internal `discoverFiles()` reads `_minMtime` directly because it's already on `queue`. If you add another caller, go through the public property.

3. **Subagent turns share the parent's `sessionId`** — they're flagged with `agentId` / `isSubagent` per line, NOT a separate session. Earlier in v0.0.4 there was a path-based rollup that assumed otherwise; it did nothing. The current design treats them as part of the parent's `turns` array, surfaces them in the view via `Conversation.subagentTurns` / `subagentCost`. Don't reintroduce path-based grouping without changing the data model first.

4. **`onRescanComplete` drives rebuilds, not `handleLines`.** `ConversationStore.handleLines(url:lines:)` only ingests; it does *not* rebuild. The rebuild fires once per rescan in the `onRescanComplete` closure, which also drives the `pendingLoadDays` chain. If you add a new ingest entry point (besides the watcher), call `rebuildSnapshot()` yourself — this is what `ingestForTesting` / `ingestBatchForTesting` do.

5. **Cache TTL uses `lastTurnTimestamp`, not `lastResponseTimestamp`.** This includes the latest human turn so the warm countdown resets the moment a message is sent (matching Anthropic API cache semantics). Don't "fix" `cacheTTLRemaining` to use `lastResponseTimestamp` — it's intentional.

6. **Progressive day-load is a recursion through `onRescanComplete`.** `loadMoreDays(n)` sets `pendingLoadDays = n - 1` then kicks the first chunk via `runOneDayChunk()`. Each completion checks `pendingLoadDays > 0` and calls `runOneDayChunk()` again. Don't replace this with a synchronous loop — the backfill must yield to the main queue so the UI can render between days.

7. **All cost rendering goes through `CostFormat.string(from:)`.** Always two decimals, leading `$`. Don't reintroduce the old `>= 10.0 ? "%.2f" : "%.3f"` conditional anywhere. New cost-displaying code should call `CostFormat`.

8. **`scripts/run.sh` swallows xcodebuild stderr unless the build fails.** Useful for clean console output, but if you're debugging build issues, run `xcodebuild ... build` directly to see what's actually wrong. The captured stderr lives in a tempfile that's deleted on script exit.

9. **`pkill -x Pits` then `open` needs ~1s breathing room.** LaunchServices holds the bundle briefly after SIGTERM. The 1-second `sleep` in `run.sh` between kill and open exists for this reason — without it, `open` returns error -600.

10. **`@AppStorage("net.farriswheel.Pits.alwaysOnTop")`** is observed in `ConversationListView` and applied via `NSApp.windows.first(where: { $0.title == "Pits" })?.level`. The Settings window has its own title and is unaffected. Don't refactor to apply level globally — it'll float the Settings window too.

---

## How to start the next session

Paste into the next chat:

> Follow the handoff doc at `/Users/jifarris/Projects/pits/docs/4-21-handoff-2.md`. Top priority is **v0.0.5: local cache** so the app reopens instantly. Branch off the latest `main` (don't stack PRs), use TDD, ship one PR, squash-merge.

If pricing inaccuracy is more pressing than the cache, swap "v0.0.5: local cache" for "fix pricing reporting". They're independent.
