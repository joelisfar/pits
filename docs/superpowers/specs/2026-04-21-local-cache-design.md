# Pits v0.0.5 — Local Cache (Stale-While-Revalidate) Design

**Status:** Approved 2026-04-21
**Target version:** v0.0.5
**Branch:** `pits/v0.0.5-wip`

## Problem

Reopening Pits shows a loading spinner for several seconds while the first day's JSONL files are parsed. The work to render the conversation list is deterministic — every reopen redoes the same parse from byte zero. Cache the parsed state on disk so the list renders instantly on the next launch, and reconcile in the background.

Reference UX: Apple Mail. Everything is there immediately. Refresh happens unobtrusively. No big-deal loading state.

## Non-goals

- Network sync, multi-device cache, or shared cache
- Schema migration between versions (mismatched cache → discard, full backfill)
- Persisting `LogParser.partials` (trailing partial lines are re-read by adjusting the saved offset)
- Surfacing cache state to the user beyond a small activity spinner

## Architecture

A new `SnapshotCache` service owns reading and writing a single cache file. `ConversationStore` consults it on `init` (synchronous read) and registers itself for write notifications. `LogWatcher` and `LogParser` accept optional seed state at construction so hydration is set-at-birth, not patched-in. A small `ProgressView` is added to the trailing edge of the existing status bar; it observes `store.isLoading`.

**Cache file location:** the file `state.json` directly under `FileManager.default.url(for: .cachesDirectory, in: .userDomainMask)`. This resolves to `~/Library/Containers/net.farriswheel.Pits/Data/Library/Caches/state.json` when sandboxed, `~/Library/Caches/state.json` otherwise. No extra bundle-id subfolder — the container path is already keyed by bundle.

**Cache lifetime:** persists across launches. Replaced atomically via `Data.write(to:options:.atomic)`. Versioned by an integer field. The OS may evict the cache (Caches directory semantics); a missing file is the same as a cache miss.

## Components

### `Pits/Models/PersistedState.swift`

Pure data, all `Codable`. New file.

```swift
struct PersistedState: Codable {
    let schemaVersion: Int       // currently 1
    let savedAt: Date
    let daysLoaded: Int
    let fileBySession: [String: URL]
    let offsets: [URL: UInt64]
    let parser: PersistedParser
}

struct PersistedParser: Codable {
    let turnsByRequestId: [String: Turn]
    let humanTurnsBySession: [String: [HumanTurn]]
    let titleBySession: [String: String]
}
```

`Turn`, `HumanTurn`, and `SessionTitle` (if not already) get `Codable` conformance. `Conversation` does **not** — it is derived state, never persisted directly.

JSON encoding uses `.iso8601` for dates so timestamps are human-readable in the file (debuggability) and stable across encoder default changes.

### `Pits/Services/SnapshotCache.swift`

File I/O and write debouncing. New file.

```swift
final class SnapshotCache {
    init(fileURL: URL, debounceInterval: TimeInterval = 2.0)
    func load() -> PersistedState?           // sync, called from store init
    func scheduleSave(_ state: PersistedState) // debounced
    func saveNow(_ state: PersistedState) throws // for app quit / tests
}
```

`load()` returns `nil` for: missing file, JSON decode failure, schema version mismatch. It does not throw — callers do not care why the cache is unavailable.

`scheduleSave` resets a 2-second timer. The captured `state` is the *latest* one; if `scheduleSave` is called five times in two seconds, only the last state is written, and only once.

`saveNow` cancels any pending debounce timer and writes immediately. Used by the willTerminate observer and `ConversationStore.stop()`.

### `LogParser` additions

A new designated initializer:

```swift
init(seed: PersistedParser? = nil) {
    if let seed {
        self.turnsByRequestId = seed.turnsByRequestId
        self.humanTurnsBySession = seed.humanTurnsBySession
        self.titleBySession = seed.titleBySession
    }
}
```

A read-only accessor for persistence:

```swift
func snapshot() -> PersistedParser {
    PersistedParser(
        turnsByRequestId: turnsByRequestId,
        humanTurnsBySession: humanTurnsBySession,
        titleBySession: titleBySession
    )
}
```

### `LogWatcher` additions

Initializer takes initial offsets:

```swift
init(rootDirectory: URL, initialOffsets: [URL: UInt64] = [:]) {
    self.rootDirectory = rootDirectory
    self.offsets = initialOffsets
}
```

Public accessor for persistence — queue-safe, and *adjusted to point before any trailing partial line* so partial bytes get re-read next launch (no need to persist `partials`):

```swift
func currentOffsetsForPersistence() -> [URL: UInt64] {
    queue.sync {
        var result: [URL: UInt64] = [:]
        for (url, offset) in offsets {
            let partialLen = UInt64(partials[url]?.count ?? 0)
            result[url] = offset >= partialLen ? offset - partialLen : 0
        }
        return result
    }
}
```

This is the only offsets accessor — there is no separate "raw" accessor since persistence is the only consumer outside the watcher itself.

### `ConversationStore` changes

`init` accepts an optional `cache: SnapshotCache?` (default `nil` for tests; production wires the real one). The flow:

1. Call `cache.load()`. If hit (`PersistedState` returned):
   - Filter `fileBySession` by `FileManager.fileExists` — drop entries whose JSONL no longer exists. Drop matching offsets.
   - Construct `LogParser` with `seed: state.parser` (after pruning sessions whose file was dropped).
   - Construct `LogWatcher` with `initialOffsets:` from filtered offsets.
   - Set `daysLoaded = state.daysLoaded`, `fileBySession = (filtered)`.
   - Call `rebuildSnapshot()` — `conversations` is populated before the view appears.
   - `isLoading` stays `false`.
2. If miss: parser, watcher, store init empty (existing behavior).

`start()` always runs after `init`. It sets `chimeCutoff = Date()` (so cached turns never chime), sets `watcher.minMtime` from the current `daysLoaded`, sets `isLoading = true`, kicks `backfill()` in the background. The progressive day-load chain (`pendingLoadDays = 6`) only runs if the cache was empty; with a warm cache, the user's restored `daysLoaded` is already correct.

After every `rebuildSnapshot()`, the store calls `cache?.scheduleSave(snapshotState())`. `snapshotState()` is a private helper:

```swift
private func snapshotState() -> PersistedState {
    PersistedState(
        schemaVersion: 1,
        savedAt: Date(),
        daysLoaded: daysLoaded,
        fileBySession: fileBySession,
        offsets: watcher.currentOffsetsForPersistence(),
        parser: parser.snapshot()
    )
}
```

`stop()` calls `cache?.saveNow(snapshotState())`.

### `PitsApp` changes

Construct the `SnapshotCache` and pass it into the store:

```swift
let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
    .first!.appendingPathComponent("state.json")
let cache = SnapshotCache(fileURL: cacheURL)
_store = StateObject(wrappedValue: ConversationStore(rootDirectory: root, ttlSeconds: ttl, cache: cache))
```

Register the willTerminate observer (in `init` or via a small NSApplicationDelegate adapter):

```swift
NotificationCenter.default.addObserver(
    forName: NSApplication.willTerminateNotification,
    object: nil, queue: .main
) { _ in store.stop() }
```

### Status bar spinner

A small `ProgressView().controlSize(.small)` is added to the trailing edge of the existing status bar in `ConversationListView`, conditional on `store.isLoading`. No text. No "refreshing…" label. Mail-style — the icon is the indicator.

Existing in-list "loading" state (the one currently shown when `conversations.isEmpty && isLoading`) remains for the cold-launch path. On a warm-cache launch, conversations are already populated, so the in-list spinner doesn't show; only the small status-bar spinner blinks during reconciliation.

## Data flow

### Cold launch (no cache)
1. `cache.load()` returns `nil`.
2. Parser, watcher, store init empty.
3. `start()` sets `isLoading = true`, sets `pendingLoadDays = 6`, runs progressive backfill.
4. Each `rescanComplete` triggers `rebuildSnapshot()` and `cache.scheduleSave(...)`.

### Warm launch (cache hit)
1. `cache.load()` returns `PersistedState`.
2. Pruning: drop file/session/offset entries for files no longer on disk.
3. Parser constructed with `seed`; watcher constructed with `initialOffsets`; store restores `daysLoaded` + `fileBySession`.
4. `rebuildSnapshot()` runs synchronously — `conversations` ready before first frame. UI renders, no spinner.
5. `start()` sets `chimeCutoff = Date()`, sets `watcher.minMtime` from restored `daysLoaded`, sets `isLoading = true`, kicks `backfill()`.
6. Backfill reads only bytes appended since last save. Lines flow through normal `handleLines` → parser → `rescanComplete` → `rebuildSnapshot()` → `scheduleSave`. `isLoading` flips off.
7. Status-bar spinner is visible only during step 6. No new bytes → ~50ms blink. New bytes → visible until done.

### Live updates (post-launch)
Unchanged. FSEvents → `onLines` → `handleLines` → `rescanComplete` → `rebuildSnapshot()` → debounced `scheduleSave`.

### Write triggers
| Trigger | Action |
|---|---|
| After every `rebuildSnapshot()` | `cache.scheduleSave(...)` (2s debounce) |
| `ConversationStore.stop()` | `cache.saveNow(...)` (cancels debounce) |
| `NSApplication.willTerminateNotification` | `store.stop()` (which calls `saveNow`) |

## Error handling

| Failure | Behavior |
|---|---|
| Cache file missing | `load()` returns `nil` → cold-launch path |
| JSON decode fails | `load()` returns `nil` → cold-launch path; malformed file overwritten on next save |
| `schemaVersion` mismatch | `load()` returns `nil` → cold-launch path |
| Cached file URL no longer on disk | At hydrate: drop from `fileBySession` and `offsets`. Drop turns/humans/title for that session id. Silent. |
| Cached offset > current file size (rotation/truncation) | Existing `readNewBytes` self-heals: `seek(toOffset:)` throws, offset reset to 0, file re-read from start on next pass. Cache code does nothing special. |
| Mid-write crash | `Data.write(.atomic)` guarantees the destination is either pre-write or post-write, never partial. On next launch the older cache loads cleanly. |
| Cache write fails (disk full / permissions) | Log to console (`os_log` `.error`), do not surface to UI. Next save attempt retries. |
| Restored `daysLoaded` exceeds available history | Watcher only discovers what is on disk now; missing files contribute nothing. Restored `daysLoaded` is an upper bound, not a guarantee. |

## Testing

New unit tests under `PitsTests/`.

### `SnapshotCacheTests.swift`
- Roundtrip: encode known `PersistedState`, write to temp file via `saveNow`, `load()`, assert structural equality.
- Missing file: `load()` returns `nil`.
- Malformed JSON: write garbage to the cache file, `load()` returns `nil`, no throw.
- Schema mismatch: write a state with `schemaVersion: 999`, `load()` returns `nil`.
- Debounce: call `scheduleSave` 5x within 2s window, assert exactly 1 file write occurred.
- `saveNow` cancels pending debounce.

### `LogParserCacheTests.swift`
- Construct parser with a known `seed`. Assert `turns()`, `humanTurns()`, `title()`, `sessionIds()` return the same data as a parser that ingested the equivalent JSONL lines.
- `snapshot()` round-trips through `init(seed:)`.

### `LogWatcherCacheTests.swift`
- Construct watcher with `initialOffsets = [url: 100]` for a file with 200 bytes. After `backfill()`, assert only bytes 100–200 produced lines.
- `currentOffsets()` reflects state after a rescan.
- Trailing-partial alignment: append an unterminated line. Assert `currentOffsetsForPersistence()` returns an offset *before* the partial bytes (so they get re-read on next launch).

### `ConversationStoreCacheTests.swift`
- Cache-cold init: `isLoading == false` until `start()` is called; after `start()` and a rescan, `isLoading == false`.
- Cache-warm init: `conversations` populated synchronously before `start()`. After `start()`, no chime fires for cached turns (their timestamps are <= `chimeCutoff`).
- Roundtrip: cold init → ingest some lines → `saveNow` → reinit a fresh store with the saved cache → `conversations` identical.
- Pruning: cached `fileBySession` entry whose file does not exist on disk is dropped on hydrate; the corresponding session id is gone from `conversations`.
- Reconciliation: cache-warm init + new bytes appended to a tracked file → after `start()` + `backfill()`, `conversations` includes the new turns.

### Manual smoke (via `bash scripts/run.sh`)
- Cold launch (delete cache file first): big spinner shows, conversations populate, new cache file written.
- Quit, reopen: conversations appear instantly. Status-bar spinner blinks briefly.
- Append to a tracked JSONL while app is closed, reopen: new turns appear after a brief spinner pulse.
- Edit `schemaVersion` in cache file to `999`, reopen: cold-launch behavior.
- Delete cache file, reopen: cold-launch behavior.

## Out of scope (future work)

- Schema migration: when `schemaVersion` bumps, current behavior is "discard and re-parse." Real migration deferred until we have a v1 cache in the wild that's expensive to lose.
- Compaction: cache file currently grows monotonically with `daysLoaded`. If size becomes a problem, prune entries older than the current `daysLoaded` window at hydrate.
- Per-file write tracking: today we save the full state on every debounce fire. Could split out high-churn fields if write volume becomes a problem.
