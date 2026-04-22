# Pits — Handoff for the Next Session (post v0.0.5)

**Current state:** v0.0.1 → v0.0.5 all shipped. On `main` at `be09138` (squash of PR #8). Working tree clean, **76 tests pass** (53 prior + 23 new), app builds and runs snappy.

**Repo:** `/Users/jifarris/Projects/pits`. Remote: `joelisfar/pits`.

**Build/test/run:** `bash scripts/run.sh` rebuilds Debug and relaunches the app. Tests: `xcodegen generate && xcodebuild -project Pits.xcodeproj -scheme Pits -destination "platform=macOS,arch=$(uname -m)" test`.

**Cache file:** `~/Library/Caches/state.json` (sandbox-aware path; would be `~/Library/Containers/net.farriswheel.Pits/Data/Library/Caches/state.json` if Pits ever gets sandboxed). ~1MB at typical use.

---

## What shipped this session (PR #8 — v0.0.5)

**Local cache (stale-while-revalidate).** `SnapshotCache` service persists `LogParser` state, watcher offsets, and the loaded-day window to disk after every rebuild (debounced 2s). On reopen, `ConversationStore.init` consults the cache synchronously, prunes sessions whose JSONL is gone, hydrates parser/watcher seeds, restores `daysLoaded`, and calls `rebuildSnapshot()` before the first frame. Then `start()` reconciles in the background from saved offsets — no more multi-second spinner on warm launches.

**Status-bar activity indicator.** Small `ProgressView().controlSize(.small).scaleEffect(0.7)` at the trailing edge of the status bar in `ConversationListView`, conditional on `store.isLoading`. Mail-style — no label, just the icon.

**Row layout polish.** Status dot pinned to the title line (top-aligned HStack); status dot hidden for cold sessions but column reserved so warm/cold rows align; warm countdown text hidden for cold sessions.

**Brainstorm/spec/plan paper trail.** First end-to-end run of the superpowers workflow on this repo: `docs/superpowers/specs/2026-04-21-local-cache-design.md` and `docs/superpowers/plans/2026-04-21-v0.0.5-local-cache.md`.

---

## Known follow-ups (in rough priority order)

### 1. Pricing reporting is inaccurate

User flagged this at the end of v0.0.3 and again before v0.0.5. **Hasn't been investigated yet.** This is now the top open item. Likely places to dig:
- `Pits/Services/Pricing.swift` — model name normalization, rate table
- `Conversation.totalCost` / `Turn.totalCost` — calculation
- `Conversation.estimatedNextTurnCost(at:)` — context-size + warm/cold rate selection

Verify against `gh-claude-costs` (the reference dashboard) on a known session — find a session where the two disagree, narrow down whether the divergence is in the rate table, the input/output token attribution, or the cache-write/cache-read split.

### 2. Inset/rounded selection styling

The user wants Safari-History-style selection (inset from edges, rounded corners, subtle gray) but with proper sticky-push section headers. Tried during v0.0.4:
- `.listStyle(.sidebar)` → made the whole window translucent + broke headers
- `.listStyle(.inset)` → wonky sticky behavior ("zap" + double bottom border)
- Currently on `.listStyle(.plain)` which has correct sticky behavior but edge-to-edge selection

Real fix probably needs a custom row background that paints an inset rounded rect when selected, using `List` selection state inside each row. Or `LazyVStack` + custom selection (loses native ⌘-click / shift-click — bigger surgery).

### 3. App icon is still a placeholder

`Pits/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json` declares all the slots. No PNGs. From the original spec: "a fire pit glyph or stylized flames." Design work, not code.

### 4. Smaller polish ideas the user has raised

- Per-agent breakdown when expanding subagents (instead of just an aggregate). Would need `agentId` carried into the view layer and grouping in `ConversationRowView`.
- Cost breakdown by model / human turns / cold turns (à la `gh-claude-costs-dashboard`).
- "Load more" smarter: load to month boundary, or by week label.
- Cache compaction: `state.json` currently grows monotonically with `daysLoaded`. If a heavy user has scrolled back many weeks, the cache will hold all of it. Consider pruning entries older than the current `daysLoaded` window at hydrate time. Not urgent — current size is ~1MB at 17 sessions × 3000+ turns.

---

## Gotchas the next agent should know

(In addition to the existing 8 in `docs/4-21-handoff-1.md` and 10 in `docs/4-21-handoff-2.md` — those are still load-bearing.)

1. **Cache file lives at `~/Library/Caches/state.json`, not `Application Support`.** This is intentional and matches Apple's "regenerable data" guidance (the OS may evict it, which is the same as a cache miss → cold launch). The original v1.1 handoff suggested Application Support; we changed to Caches during the v0.0.5 spec phase. Don't move it back without a reason.

2. **`SnapshotCache.scheduleSave` runs the work item ON the cache's serial queue.** Calling `saveNow` (which does `queue.sync`) from inside the work item would deadlock. The implementation extracts `writeToDisk(_:)` so the work item bypasses `queue.sync`. The first debounce test caught this; if you add another save path, follow the same pattern.

3. **`LogParser.init(seed:)` and `LogWatcher.init(initialOffsets:)` are set-at-birth**, not patched in after. Don't add `hydrate(...)` setters — it's intentional that hydration happens at construction (NSCoding's `init(coder:)` convention). If you need to reset state mid-life, construct a new instance.

4. **`ConversationStore.start()` only runs the progressive 6-day chain when `daysLoaded == 1`** (cold-launch indicator). On warm launches `daysLoaded` is already restored from the cache, so `start()` reconciles once at the existing window. If you change `daysLoaded` semantics (e.g. add a "reset to default window" feature), update this branch in `start()`.

5. **The watcher persists offsets *adjusted before any trailing partial line*** via `currentOffsetsForPersistence()`. We don't persist `partials` separately — partial bytes get re-read on next launch. Don't add a `persistedPartials` field; the offset adjustment is the design.

6. **Hydrate-time pruning drops any session whose JSONL no longer exists on disk.** This is silent — no UI surfaces it. If a user manually deletes a JSONL file from `~/.claude/projects/` while the app is closed, that session vanishes from the list on next launch. This is intentional (the file is the source of truth), but if a user reports "my session disappeared," check whether the JSONL was deleted/moved.

7. **`willTerminate` observer in `PitsApp.init` triggers `store.stop()`.** This is in addition to `WindowGroup.onDisappear { store.stop() }` — belt-and-suspenders, since `onDisappear` doesn't fire reliably for app quit. `stop()` itself calls `cache?.saveNow(...)` which cancels any pending debounce. If you split the save logic, keep both call sites.

8. **`reconcileForTesting()` includes a 50ms `RunLoop.main.run(until:)` drain** because `LogWatcher.onLines` dispatches to `DispatchQueue.main.async` and we need those handlers to flush before our explicit `rebuildSnapshot()`. If a future change makes `handleLines` synchronous, this drain becomes unnecessary.

---

## How to start the next session

Paste into the next chat:

> Follow the handoff doc at `/Users/jifarris/Projects/pits/docs/4-21-handoff-3.md`. Top priority is **investigating the pricing reporting inaccuracy** (#1 in the follow-ups). Branch off the latest `main` (don't stack PRs), use TDD, ship one PR, squash-merge.

If selection styling or another item is more pressing, swap that for #1. They're independent.

---

## Process notes (for the next agent running superpowers)

- This session was the first end-to-end run of `brainstorm → write-plan → execute-plan → finish-branch` on this repo. Workflow was clean; one process tweak: I went **inline** (executing-plans) rather than **subagent-driven**, because the brainstorm + plan context was already loaded in the conversation. For the next feature, if the design is fresh and the plan is short (~10 tasks), inline is faster.
- Specs go to `docs/superpowers/specs/` and plans go to `docs/superpowers/plans/` — the brainstorming skill defaults to that split, and it works well here. The `docs/superpowers/plans/` dir already had two earlier plans from prior sessions; I didn't disturb them.
- The TDD loop with `xcodebuild -only-testing:PitsTests/<Class>` is fast (~5–10s per single-file run, ~20s for the full suite). Use the targeted form during inner-loop development; only run the full suite before committing the final task.
