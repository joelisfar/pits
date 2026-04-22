# Pits — Handoff for the Next Session (post v0.1.1)

**Current state:** v0.0.5 → v0.1.1 all shipped today. On `main` at `8f7619a`. Working tree clean. **117 tests pass.** App builds and runs from main.

**Repo:** `/Users/jifarris/Projects/pits`. Remote: `joelisfar/pits`.

**Sister repo:** `/Users/jifarris/Projects/gh-claude-costs` — also got matching pricing fixes today (PR #1 merged). Both tools now agree within rounding.

**Build/test/run:** `bash scripts/run.sh` rebuilds Debug and relaunches. Tests: `xcodegen generate && xcodebuild -project Pits.xcodeproj -scheme Pits -destination "platform=macOS,arch=$(uname -m)" test`.

**Cache files:**
- `~/Library/Caches/state.json` — conversation snapshot cache (~2MB, schema v4)
- `~/Library/Caches/pricing.json` — fetched LiteLLM rates (~1KB, refreshed daily)

---

## What shipped today (six PRs)

### v0.0.6 — pricing accuracy (PR #9)

Three concrete bugs in [Pits/Models/Pricing.swift](../Pits/Models/Pricing.swift) and the data-flow downstream of it. Measured impact across all 28k turns: **20.6% under-bill** ($1,547.50 → $1,948.09).

1. **`claude-opus-4-7` was missing from the rate table** — 2,500 turns silently priced at $0. The current Opus model.
2. **`claude-haiku-4-5` used Haiku 3.5 rates** ($0.80/$4) — was a copy-paste row from `claude-haiku-3-5`. Corrected to $1/$5.
3. **1-hour cache writes were billed at the 5-minute rate** — the JSONL `usage.cache_creation` is a nested object splitting `ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens`, billed at 1.25× and 2× input respectively. We were summing them and applying 5m. **88% of all cache_create tokens are 1h-tier**, so this was the largest under-bill.

Schema effect: `Turn` now stores `cacheCreation5mTokens` + `cacheCreation1hTokens` separately; `Conversation.estimatedNextTurnCost`'s cold path weights the write-rate by the last turn's actual mix; `SnapshotCache.currentSchemaVersion` bumped 1 → 2 (later 3 → 4).

### v0.0.7 — calendar-month scope (PR #10)

Replaced `daysLoaded` rolling window with a **calendar-month scope picker**. Per-turn bucketing — sessions that span months appear in every month they touched, each instance showing only that month's slice. Matches per-turn reference dashboards exactly.

- New `MonthScope` value type (year/month with date-range + display helpers)
- `Conversation.filtered(toMonth:in:)` clips turns/humans to a month range
- `LogWatcher.minMtime` → `mtimeRange: Range<Date>?`
- `ConversationStore.selectedMonth` + `setSelectedMonth(_:)` + `discoverActiveMonths()`
- Picker lives in the window toolbar (native `Picker(.menu)` pill button)
- `PersistedState.daysLoaded` removed; cache schema 2 → 3

### v0.0.8 — app icon (PR #11)

Fire-pit furnace with $ door (the user supplied a 1254×1254 source). Seven sizes generated with `sips`, `Contents.json` maps the 10 macOS slots to them with file-sharing where pixel sizes match.

### v0.0.9 — menu bar quick-open + hidden title (PR #12)

`.windowStyle(.hiddenTitleBar)` drops the "Pits" title text from the window title bar (traffic lights stay). Added a second `MenuBarExtra("Pits", systemImage: "flame.fill")` scene with `Open Pits` / `Quit Pits` items — useful when the window's been closed and you want it back without the Dock.

App stays a normal windowed app — Dock icon, cmd-tab presence intact.

### v0.1.0 — LiteLLM pricing fetch (PR #13)

Stops requiring a code change every time a new Claude model launches. `Pricing.table` becomes `private(set) var`; `bundledTable` keeps the canonical hardcoded rates as a fallback. On launch, the app synchronously hydrates from `~/Library/Caches/pricing.json`, then refetches from [LiteLLM](https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json) in the background if the snapshot is older than 24h.

The 1h cache rate is derived locally as `base × 2.0` — LiteLLM only models the 5m cache rate (= 1.25× base).

New files: [Pits/Services/RemotePricing.swift](../Pits/Services/RemotePricing.swift), [Pits/Services/PricingCache.swift](../Pits/Services/PricingCache.swift).

### v0.1.1 — row polish + ai-title fallback (PR #14)

Two row-related changes bundled into one PR.

**Row layout polish ([Pits/Views/ConversationRowView.swift](../Pits/Views/ConversationRowView.swift)):**
- `next ~` → `next turn ~` for clarity
- Cold rows render the countdown line at opacity 0 instead of being conditionally absent — prevents row-height shift when sessions transition warm → cold

**Title fallback ([Pits/Services/JSONLDecoder.swift](../Pits/Services/JSONLDecoder.swift)):**
- Claude Code skips `ai-title` generation for sessions opened with a slash command. Now the row falls back to a preview of the first user message.
- Preview extraction strips `<local-command-caveat>` wrappers, extracts `<command-name>…</command-name>` slugs (so slash-command openers show as e.g. `/context`), and strips `<ide_*>…</ide_*>` IDE-context tags.
- `HumanTurn` got a new optional `text` field; cache schema bumped 3 → 4.

### gh-claude-costs PR #1 (merged)

Sister-repo update so both tools agree. Same fixes, same LiteLLM fetcher (in Python via stdlib `urllib.request`, runtime fetch — no caching needed since the tool is one-shot). `template.html` updated to consume `cache_write_5m` / `cache_write_1h` separately. Twelve stdlib `unittest` tests added.

---

## Known follow-ups (in rough priority order)

### 1. Inset/rounded selection styling

Still unresolved from prior sessions. Want Safari-history-style selection (inset from edges, rounded corners, subtle gray) but with proper sticky-push section headers. We tried during this session via `.listRowBackground(...)` painting an inset rounded rect — but the macOS system selection bar (edge-to-edge blue) draws on top regardless, and the user explicitly didn't want a custom-selection LazyVStack rewrite. Currently still on `.listStyle(.plain)` with edge-to-edge blue selection.

The `v0.2.0-selection-styling` branch was created and immediately deleted unmerged when it became clear the SwiftUI-native approach hit a wall. **Don't reattempt without exploring NSTableView introspection** (e.g. via `SwiftUI-Introspect` package) or accepting the LazyVStack tradeoff.

### 2. Polish ideas

- **Per-agent breakdown when expanding subagents** (instead of just an aggregate). Would need `agentId` carried into the view layer and grouping in `ConversationRowView`.
- **Cost breakdown by model / human turns / cold turns** (à la `gh-claude-costs-dashboard`).
- **Cache compaction:** `state.json` (~2MB) grows with everything we've ever ingested. Month-scope picker means we accumulate every month visited. Consider pruning at hydrate time. Not urgent.

---

## Gotchas the next agent should know

(In addition to the ones in `4-21-handoff-1.md` through `-3.md` — those are still load-bearing.)

1. **`Pricing.table` is now mutable.** Tests must capture/restore via `Pricing.replaceTable(with:)` to avoid leaking state across tests. Three new tests in `PricingTests` show the pattern.

2. **Floating-point precision in pricing tests.** `Pricing.bundledTable` is computed at runtime via `rates(input:output:)` rather than constant-folded at compile time, so `1.0 * 0.10` produces `0.0999999...` instead of `0.10` exactly. Use `XCTAssertEqual(..., accuracy: 0.0001)` on rate comparisons. One existing test was retroactively patched.

3. **`MonthScope`'s `dateRange(in:)` is a half-open `Range<Date>`** — `[startOfMonth, startOfNextMonth)`. `Conversation.filtered(toMonth:)` uses `range.contains(timestamp)` which respects this. Don't change to `ClosedRange`.

4. **The watcher's `mtimeRange` keeps already-tracked files in scope** even when their mtime falls outside the range. Live appends to "older" files are still picked up. If you change month-switch behavior, preserve this — otherwise active sessions in another month will appear to stop receiving turns until you switch back.

5. **`RemotePricing` overlays onto the bundled table; it doesn't replace it.** Models LiteLLM doesn't list (or fields it omits) keep their bundled values. `Pricing.overlay(_:)` uses dict-merge semantics: per-model whole-record replacement, not per-field merge.

6. **`PricingCache.load(from:)` is non-throwing** — returns `nil` for missing/corrupt files. The 24h staleness check is in `PitsApp.init`, not the cache itself. Don't move the TTL into `PricingCache` unless you also rework the call sites.

7. **`MenuBarExtra` uses `@Environment(\.openWindow)` to reopen the closed main window** — see `MenuBarContent` in `PitsApp.swift`. The window scene's `id: "pits-main"` is what `openWindow(id:)` looks up. If you rename the id, update both sites.

8. **`gh-claude-costs/extract.py`'s assistant tuple grew from 9 → 10 fields** after the 5m/1h split (cache_creation became two fields). All `m[N]` indices in the classify loop shifted. The plan doc at `docs/superpowers/plans/2026-04-21-litellm-pricing-fetch.md` documents the new layout.

9. **There is a comment block at the top of the classify loop in extract.py** documenting tuple indices. Keep it in sync if you add/remove fields.

10. **Stale stash hygiene.** During this session I stashed working-tree changes that pre-existed the session, then later popped/dropped them. If you start a session with `git status` showing modifications you didn't make, `git stash` them with a descriptive message before branching — this avoids them ending up in commits you didn't intend.

---

## Process notes

- Six PRs in one day. The branch-per-version pattern (`vX.Y.Z-<topic>`) worked well; squash-merge with `gh pr merge --squash --delete-branch` keeps `main`'s log clean.
- Toward the end of the session I made a `local-stack` branch that combined all open PRs for visual testing. The user found this confusing. **Don't re-introduce it.** New rule: *the running app always comes from whatever branch you're sitting on; don't switch branches mid-chunk.* If you need to verify how PRs look together, wait until they've merged to main and rebuild from main.
- The `superpowers:writing-plans` + `superpowers:executing-plans` flow worked for the LiteLLM PR (Plan A + Plan B in one doc). For the smaller PRs (icon, menu bar, row polish) inline TDD without a plan doc was faster.
- One mislabeled commit happened: `f5cd8de` claimed to ship the row-polish tweaks but its actual diff was the title-fallback code. The polish ended up in a follow-up commit `a2810df`. Lesson: when you stash + pop + commit in a sequence, double-check `git diff --cached` before committing.

---

## How to start the next session

Paste into the next chat:

> Follow the handoff doc at `/Users/jifarris/Projects/pits/docs/4-21-handoff-4.md`. Top open item is **inset/rounded selection styling** (#1 in the follow-ups) — but read the gotcha about it first; it's blocked on a SwiftUI-native solution and the user doesn't want a LazyVStack rewrite. Polish ideas (#2) are independent and bite-sized. Branch off the latest `main` (don't stack PRs), use TDD, ship one PR per chunk, squash-merge.
