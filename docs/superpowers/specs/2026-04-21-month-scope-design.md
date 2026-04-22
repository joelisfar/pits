# Spec: Calendar-month scope (replaces rolling-day window)

**Date:** 2026-04-21
**Target version:** v0.0.7
**Motivation:** Verify the v0.0.6 pricing fixes against an external per-turn reference (`gh-claude-costs`) by aligning Pits' bucketing with the reference: per-turn timestamps grouped by calendar month. Also a UX win — month-scoped browsing is a more natural mental model than "rolling N-day window with progressive load."

## What ships

A month picker at the top of the conversation list. Selecting a month restricts the visible conversations and recomputes per-row cost from only that month's turns. Sessions that span months appear in every month they touched, each instance showing only that month's slice. Default scope on launch is the current calendar month.

## What goes away

- `daysLoaded` rolling-window concept on `ConversationStore`
- "Load 7 more days" button (`loadMoreRow` in [ConversationListView.swift](../../../Pits/Views/ConversationListView.swift))
- The progressive 6-day chain in `ConversationStore.start()` triggered when `daysLoaded == 1`
- `daysLoaded` field on `PersistedState`

## Behavior

### Month picker
- Located top-of-list, in a new compact bar above the `List` (under the title bar, above the existing `Divider`).
- Renders as a SwiftUI `Menu` with the selected month as label, e.g. `[April 2026 ▾]`.
- Items: contiguous calendar months from `earliestMonth` (derived from JSONL mtimes) through current month, newest-first.
- Default selection on launch: current calendar month. Selection is **not** persisted across launches — re-launching always returns to "now".

### Active months (dropdown population)
- Computed once at store init (after cache hydrate) by scanning `~/.claude/projects/**/*.jsonl` mtimes — one stat per file. Range = `[earliestMonth, currentMonth]`, contiguous (no gaps). Empty months in the range still appear (selecting them just shows an empty list).
- Recomputed on app activation (cheap) so the dropdown reflects newly-arrived sessions / month boundary crossings.

### Per-turn bucketing
- New `Conversation.filtered(toMonth: MonthScope)` returns a *new* `Conversation` whose `turns` and `humanTurns` are clipped to the month's `[start, nextMonthStart)` range.
- The list view consumes `store.conversations.compactMap { $0.filtered(toMonth: store.selectedMonth) }`. Empty conversations (no turns in that month) are dropped.
- Cross-month sessions appear once per month they have activity in. Each instance:
  - Shows only that month's turns
  - `totalCost`, `subagentCost`, `lastResponseTimestamp`, `lastActivityTimestamp` all derive from the filtered turn set
  - Day grouping (v0.0.4) groups by the filtered `lastActivityTimestamp` — keeps working unchanged

### Loading on month switch
- `ConversationStore.setSelectedMonth(_:)` updates the watcher's discovery range to that month's bounds, sets `isLoading = true`, kicks off ingestion of any not-yet-loaded files in range.
- Already-ingested data stays in `LogParser` state — re-selecting a previously-visited month is instant.
- The status-bar progress spinner (v0.0.5) is the loading affordance — no new UI needed.

### Watcher
- `LogWatcher.minMtime` becomes `mtimeRange: ClosedRange<Date>` (or `(min: Date?, max: Date?)`). `backfill()` and FSEvents handlers honor both bounds.
- Files arriving outside the active scope still get ingested into parser state (so re-selecting their month is instant later); they just aren't visible until selected.

### Status bar
- Existing `"N conversations · $X.XX total"` line in [ConversationListView.swift](../../../Pits/Views/ConversationListView.swift) — total naturally re-derives from the filtered set since it sums `c.totalCost` over the displayed conversations.

### Cache
- `SnapshotCache` schema stays at v2. Persisted state continues to represent "everything we've ever ingested." Filter is a display layer.
- One field change: `PersistedState.daysLoaded` is removed (it's no longer meaningful). This is a schema shape change → bump v2 → v3 (old v2 caches discarded silently on next launch).

## Non-goals

- Persisting last-selected month across launches (always reset to current).
- Multi-month selection or arbitrary date ranges (single-month is the common case for verification; arbitrary ranges are a future feature).
- Year selector / hierarchical navigation (the single flat list of months is fine until users scroll past ~24 entries).
- Month-grouped totals dashboard (a follow-up — handoff #4 already mentions it).

## Architecture

### New
- `Pits/Models/MonthScope.swift` — value type `MonthScope { year: Int; month: Int }` with:
  - `static func current(in cal: Calendar) -> MonthScope`
  - `static func from(date: Date, in cal: Calendar) -> MonthScope`
  - `var dateRange: Range<Date>` (start-of-month inclusive, start-of-next-month exclusive)
  - `var displayName: String` ("April 2026" via `DateFormatter`)
  - `Comparable`, `Hashable`, `Codable`

### Modified
- `Pits/Models/Conversation.swift` — add `filtered(toMonth:)` returning a new `Conversation`. Pure function, no side effects.
- `Pits/Stores/ConversationStore.swift`:
  - Replace `@Published var daysLoaded: Int` with `@Published var selectedMonth: MonthScope` (init from `MonthScope.current()`).
  - Replace `loadMoreDays(_:)` with `setSelectedMonth(_:)`.
  - Add `@Published private(set) var availableMonths: [MonthScope]`.
  - Add `discoverActiveMonths()` (scans JSONL mtimes once).
  - `start()` no longer runs the progressive day chain; it sets the watcher range to `selectedMonth.dateRange` and runs one backfill.
- `Pits/Services/LogWatcher.swift` — replace `minMtime: Date` with `mtimeRange: Range<Date>?`. `backfill()` and FSEvents loop check both bounds.
- `Pits/Views/ConversationListView.swift`:
  - Add `MonthPickerBar` view at top.
  - Use `store.conversations.compactMap { $0.filtered(toMonth: store.selectedMonth) }` for the displayed list.
  - Remove `loadMoreRow`.
- `Pits/Models/PersistedState.swift` — remove `daysLoaded`. Bump cache schema in `SnapshotCache.currentSchemaVersion` to 3.

## Testing

TDD all the way. New tests:
- `MonthScopeTests` — date-range math, current-month derivation, display name, ordering.
- `ConversationTests`:
  - `filtered_dropsTurnsOutsideMonth`
  - `filtered_recomputesTotalCostFromFilteredTurns`
  - `filtered_returnsNilWhenNoTurnsInMonth` (or empty-conversation semantics — TBD in plan)
  - `filtered_subagentTurnsRespectFilter`
  - `filtered_lastActivityIsLastInMonthTimestamp`
- `LogWatcherTests`:
  - `backfill_skipsFilesAboveMaxMtime`
  - `backfill_skipsFilesBelowMinMtime`
- `ConversationStoreTests`:
  - `setSelectedMonth_updatesWatcherRange_andTriggersReload`
  - `discoverActiveMonths_returnsContiguousRangeFromEarliestMtime`
  - `init_defaultsToCurrentMonth`
- Update existing tests that referenced `daysLoaded` or "Load more" to use the new model.

## Out of scope this PR

- Month-grouped totals dashboard
- Year-collapsed month picker
- Persistence of last-selected month
- Cache compaction (handoff #4) — the cache will accumulate every month the user visits, which is fine until users have visited many months
