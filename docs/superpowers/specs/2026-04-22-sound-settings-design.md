# Per-Sound Settings + Subagent Chime Filter

**Status:** approved (design)
**Date:** 2026-04-22
**Branch:** TBD (separate `vX.Y.Z` branch per project convention)

## Summary

Replace the single "Play notification sounds" toggle with a macOS-style sound settings section: master toggle plus per-event sound pickers (with system sounds list and "None" to disable). Wire up two new chime events. Fix a latent bug where subagent turn completions trigger the "agent turn completed" chime.

## Motivation

- **Personal taste.** Today there are two hard-coded sounds (Ping, Blow). Users want to swap or silence individual sounds without disabling all chimes.
- **Subagent noise.** Subagent turn-completion currently fires the chime, which is unwanted noise — only the top-level agent's "I'm done talking" should chime.
- **Missing signals.** The cache-state machine already emits useful events (`transitionedToCold`) that are dropped on the floor, and a "you typed into a cold conversation" signal would help cost-awareness.

## Scope

**In:**
1. Subagent filter on the existing turn-completed chime
2. Per-event sound picker UI (mimics System Settings → Sound)
3. Two new chime events wired up: `New cold` and `Cold human turn`
4. One new chime event added to `CacheTimer`: `15s until cold`

**Out:**
- Custom user sound files (system sounds only)
- Per-conversation sound preferences
- "New warm status" event (redundant with "Agent turn completed")
- Volume control (defer to system)

## Event Set (5 sounds)

| ID | Label | Preferred defaults (priority list) | Trigger |
|---|---|---|---|
| `agentTurnCompleted` | Agent turn completed | Ping, Boop, Pluck | Top-level agent turn with terminal `stop_reason` (existing — gain subagent filter) |
| `fifteenSecondsUntilCold` | 15 seconds until cold | Sosumi, Sonumi, Funk, Funky | New `CacheTimer` event when an open warm conversation drops to ≤15s remaining |
| `oneMinuteUntilCold` | 1 minute until cold | Blow, Breeze | Existing `oneMinuteWarning` event |
| `newCold` | New cold status | Submarine, Submerge, Sonar | Existing `transitionedToCold` event (currently unhandled) |
| `coldHumanTurn` | Cold human turn | Tink, Pluck, Pebble | New: a non-subagent human turn lands in a conversation whose `cacheStatus` is `.cold` |

Each event's preferred list is tried in order against the enumerated system sounds; the first match wins. Fallback to the first enumerated sound if none match. This handles the macOS 13 → 14 sound-name rename cleanly.

## UI Design

`SettingsView` is split into two `Section`s. The "Sounds" section nests per-event rows under the master toggle. Per-event rows render only when the master is on (per user preference; SwiftUI handles the disclosure).

```
┌─ Sounds ─────────────────────────────────────────────────┐
│  Play notification sounds                          [ON]  │
│      Agent turn completed              🔊   [Ping  ▾]    │
│      15 seconds until cold             🔊   [Sosumi ▾]   │
│      1 minute until cold               🔊   [Blow  ▾]    │
│      New cold status                   🔊   [Submarine▾] │
│      Cold human turn                   🔊   [Tink  ▾]    │
├─ Window ─────────────────────────────────────────────────┤
│  Keep window on top                              [OFF]   │
│  Launch at login                                  [ON]   │
└──────────────────────────────────────────────────────────┘
```

**Picker contents (in order):**
1. **None** — disables this individual chime (stored as empty string)
2. The available macOS system sounds, enumerated at runtime from `/System/Library/Sounds/*.aiff` (stripped of extension, sorted alphabetically).

We enumerate at runtime because the classic macOS sound names (Ping, Blow, Sosumi, Submarine, Tink) were replaced in macOS 14 Sonoma with new names (Boop, Pluck, Sonumi, Submerge, etc.). Hardcoding a list would drift from reality. Enumerating from the system directory is version-correct.

**Default sound resolution:** `SoundEvent.defaultSoundName` returns a priority-ordered list per event; `SoundManager` at first launch picks the first one that exists in the enumerated system sounds. If none of the preferred names exist, fall back to the first enumerated sound. Example for `agentTurnCompleted`: `["Ping", "Boop", "Pluck"]` — tries modern-macOS-absent "Ping" first, falls through to whatever's available.

**Behavior:**
- Picker selection change immediately plays the new sound (matches System Settings behavior). Selecting "None" plays nothing.
- The 🔊 button replays the currently-selected sound. Disabled when current selection is "None".
- Drop the current `.frame(width: 440, height: 180)` height constant and `.scrollDisabled(true)`. Keep `.frame(width: 440)`. Let the form size to its content; if a future addition makes it taller than the screen, the scroll fallback will kick in naturally. This handles the dynamic reveal (master off = 3 rows; master on = 8 rows) without a hard-coded height.

## Storage

Five new `@AppStorage` keys, each holding the selected sound name (empty string = None):

```
net.farriswheel.Pits.sound.agentTurnCompleted
net.farriswheel.Pits.sound.fifteenSecondsUntilCold
net.farriswheel.Pits.sound.oneMinuteUntilCold
net.farriswheel.Pits.sound.newCold
net.farriswheel.Pits.sound.coldHumanTurn
```

On first launch, each key is seeded with the first preferred default that exists in the enumerated system sounds (see table above). Subsequent launches read whatever the user picked.

Existing `net.farriswheel.Pits.soundsEnabled` master key is unchanged.

A `SoundEvent` enum centralizes id + storage key + default sound + display label, so `SettingsView` and `SoundManager` share one source of truth.

```swift
enum SoundEvent: String, CaseIterable {
    case agentTurnCompleted, fifteenSecondsUntilCold, oneMinuteUntilCold,
         newCold, coldHumanTurn

    var label: String { ... }
    var defaultSoundName: String { ... }
    var storageKey: String { "net.farriswheel.Pits.sound.\(rawValue)" }
}
```

## SoundManager Changes

Replace the two hard-coded methods with one event-keyed entry point. Master gate stays as the outermost check; per-event sound name "" means muted.

```swift
final class SoundManager {
    static let soundsEnabledKey = "net.farriswheel.Pits.soundsEnabled"

    /// Plays the configured sound for `event` if the master toggle is on
    /// and the per-event sound is not "None". Used by the chime triggers.
    func play(_ event: SoundEvent) { ... }

    /// Plays the configured sound for `event` ignoring the master toggle.
    /// Used by the Settings preview button. No-op when sound is "None".
    func preview(_ event: SoundEvent) { ... }
}
```

The two existing methods (`playMessageReceived`, `playOneMinuteWarning`) are removed; callers updated.

## Trigger Changes

### `agentTurnCompleted` (subagent fix)

In [ConversationStore.swift:278-283](../../Pits/Stores/ConversationStore.swift#L278-L283), add `!t.isSubagent` to the predicate. Update the comment to mention subagent filtering.

### `fifteenSecondsUntilCold` (new CacheTimer event)

Extend `CacheTimerEvent` with `.fifteenSecondWarning(String)`. In `CacheTimer.tick`, mirror the existing 1-minute logic: emit once when an open conversation crosses from `>15s` to `≤15s` remaining. Track per-conversation "fired 15s warning" state alongside the existing per-conversation tracking. Reset when remaining time goes back up (i.e., a new turn warms the cache).

### `oneMinuteUntilCold` (no logic change)

Wire to `play(.oneMinuteUntilCold)` instead of `playOneMinuteWarning()`.

### `newCold` (wire up existing event)

In [ConversationStore.swift:312-315](../../Pits/Stores/ConversationStore.swift#L312-L315), the `case .transitionedToCold` branch currently does nothing. Replace the "no-op" comment with `sound.play(.newCold)`. Keep the existing comment about not needing a snapshot rebuild.

### `coldHumanTurn` (new in handleLines)

In `handleLines`, on `case .human(let h)`:
- Skip if `h.isSubagent` (subagent humans don't count as user typing)
- Skip if `h.timestamp <= chimeCutoff` (don't chime on backfill)
- Look up the conversation by `h.sessionId` in the current `conversations` snapshot
- Read `c.cacheStatus(at: h.timestamp)`. If `.cold`, fire `sound.play(.coldHumanTurn)`.

Note: `cacheStatus` returns `.new` for conversations with no observed TTL yet, which we explicitly do NOT chime on (a fresh conversation isn't "re-engagement after cooling"). The `== .cold` check handles this.

There is a sequencing subtlety: the human turn is being ingested in this same `handleLines` call, but it doesn't yet appear in `self.conversations` (rebuild happens later). That's fine — `cacheStatus(at:)` only depends on the prior assistant turn's `observedTTLSeconds` and `lastTurnTimestamp`, both already present in the pre-ingestion snapshot. The new human entry doesn't change cache state.

## Tests

`SoundManagerTests`:
- `play(event)` respects master off.
- `play(event)` respects per-event "None" (empty string).
- `preview(event)` ignores master.
- `preview(event)` no-op when sound is "None".

`ConversationStoreTests` (extend existing):
- Subagent turn with `end_turn` stop_reason does NOT call player.
- Top-level turn with `end_turn` calls player exactly once.
- Cold human turn: ingest a conversation that's gone cold, then ingest a non-subagent human turn → assert `play(.coldHumanTurn)` was called.
- Cold human turn skipped when conversation status is `.warm` or `.new`.
- Cold human turn skipped when human is a subagent.

`CacheTimerTests`:
- `fifteenSecondWarning` fires once per warm-period transition (≤15s).
- `fifteenSecondWarning` does not re-fire on subsequent ticks within the same warm period.
- Resets after a turn warms the cache (next cooldown can fire again).

## Migration

No migration code needed:
- Existing master-toggle UserDefaults key (`soundsEnabled`) is unchanged.
- New per-event keys are seeded on first read using the priority-list resolution against enumerated system sounds. On macOS 13 and earlier this typically picks the classic names (Ping, Blow, Sosumi, Submarine, Tink); on macOS 14+ it falls through to the new equivalents (Boop, Breeze, Sonumi, Submerge, Pluck).
- After upgrade, users hear three chimes they didn't hear before (15s, new cold, cold human turn). Trivially turn off via the picker.

## Build Sequence

1. Subagent filter (one-line predicate change + test)
2. `SoundEvent` enum + new `@AppStorage` keys
3. `SoundManager` rewrite (`play(event)` + `preview(event)`); update existing call sites
4. New `CacheTimer` `.fifteenSecondWarning` event + test
5. Wire `newCold` and `15s` events in `tick()`
6. Wire `coldHumanTurn` in `handleLines`
7. `SettingsView` rewrite: split sections, add per-event picker rows
8. Manual smoke test in the Pits app
