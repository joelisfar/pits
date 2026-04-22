# Observed Cache TTL Design

**Date:** 2026-04-22
**Status:** Approved (design), pending implementation plan

## Problem

Pits today uses a user-configurable "Cache TTL" setting (5 minutes or 1 hour) to predict when each conversation's Anthropic prompt cache goes cold. This was a guess — Claude Code, not Pits, decides the real TTL on each API request, and the setting had no way to know which value Claude Code actually used.

The setting is unnecessary. Each assistant turn's JSONL event already contains `usage.cache_creation.ephemeral_5m_input_tokens` and `ephemeral_1h_input_tokens`, which tell us exactly what TTL Claude Code wrote with.

## Research findings

Analysis of 1063 JSONL session files and 29,817 assistant turns in the user's Claude projects directory (last ~30 days):

- **TTL mixing within a turn:** 0 / 29,817 turns (0.0%) have both `ephemeral_5m_input_tokens > 0` and `ephemeral_1h_input_tokens > 0`. Every turn is pure 5m or pure 1h.
- **Turn-level distribution:** 86% pure 1h, 14% pure 5m.
- **Session-level stability:** 149 pure-5m sessions, 782 pure-1h sessions, 4 mixed (0.4%) — all 4 are 200+-turn autocompact agent sessions. Normal user sessions are stable.
- **Visibility latency:** The TTL is carried by the assistant event, not the user event. Measured user-message → first assistant-event-with-usage delay across 204 real turns: median 9.3s, p75 21s, p90 41s. This is well before the 5m / 1h window matters, so latency is not a concern for the timer.

## Design

### Data model

**`enum CacheStatus`** expands to three cases:

```swift
enum CacheStatus { case new, warm, cold }
```

- `.new` — no assistant turn exists yet (no cache has been written to Anthropic's side)
- `.warm` — within the observed TTL window
- `.cold` — past the observed TTL window

**`Conversation`** loses the `ttlSeconds: TimeInterval` stored property and init parameter. It gains a computed:

```swift
var observedTTLSeconds: TimeInterval? {
    let sortedDesc = turns.sorted(by: { $0.timestamp > $1.timestamp })
    for turn in sortedDesc {
        if turn.cacheCreation1hTokens > 0 { return 3600 }
        if turn.cacheCreation5mTokens > 0 { return 300 }
    }
    return nil
}
```

- We walk assistant turns newest-first and return the TTL of the first turn that actually wrote to the cache.
- This handles the rare mid-session flip cases naturally (4/1063 sessions) and tolerates the ~0.16% of turns that carry zero `cache_creation` tokens — a prior cache-writing turn still anchors the TTL.
- Nil only when *no* assistant turn in the session has ever written to the cache → `.new`.

`cacheTTLRemaining(at:)` and `cacheStatus(at:)` use `observedTTLSeconds`:

```swift
func cacheTTLRemaining(at now: Date) -> TimeInterval {
    guard let ttl = observedTTLSeconds, let last = lastTurnTimestamp else { return 0 }
    return max(0, ttl - now.timeIntervalSince(last))
}

func cacheStatus(at now: Date) -> CacheStatus {
    guard observedTTLSeconds != nil else { return .new }
    return cacheTTLRemaining(at: now) > 0 ? .warm : .cold
}
```

The countdown anchor remains `lastTurnTimestamp` (max of assistant and human turn timestamps) — unchanged from today. A fresh human message still resets the countdown, but the TTL *duration* comes from the latest assistant turn's observed value.

### Cost estimation

`estimatedNextTurnCost(at:)` currently blends 5m and 1h rates via `frac1h`. Since mixed turns don't occur in practice, the blend collapses to a clean if/else:

```swift
case .cold:
    let writeRate: Double
    if last.cacheCreation1hTokens > 0 {
        writeRate = rates.cacheWrite1h
    } else {
        writeRate = rates.cacheWrite5m
    }
    return context * writeRate / 1_000_000.0
case .new:
    // No cache write has been observed; estimate the cold-5m path as a conservative default.
    return context * rates.cacheWrite5m / 1_000_000.0
```

### UI

**ConversationRowView**: the warm/cold timer pill gains a third branch for `.new`. It renders a neutral "new" label (no countdown text). Styling follows the existing pill.

**SettingsView**: the `Picker("Cache TTL:", ...)` block and its `@AppStorage("net.farriswheel.Pits.ttlSeconds")` declaration are removed. The Settings pane shrinks by one row.

**CacheTimer**: `transitionedToCold` still fires on warm→cold only. New cases (`new→warm`, `warm→new`) are not user-actionable and do not emit events. The one-minute warning only fires from `.warm`, unchanged.

### Plumbing removal

- `PitsApp.swift`: remove the `UserDefaults.standard.object(forKey: "net.farriswheel.Pits.ttlSeconds")` read at construction time, and the `ttlSeconds:` argument to `ConversationStore.init`.
- `ConversationStore.swift`: delete `@Published var ttlSeconds: TimeInterval`, its init parameter, and the `ttlSeconds: ttlSeconds` pass-through to `Conversation.init`.
- The orphaned `net.farriswheel.Pits.ttlSeconds` key in `UserDefaults` is left in place. Harmless.

### Tests

Updated call sites (remove the `ttlSeconds:` argument):
- `ConversationTests.swift`
- `ConversationStoreTests.swift`
- `ConversationStoreCacheTests.swift`
- `CacheTimerTests.swift`
- Preview in `ConversationRowView.swift:150`

New tests:
- `.new` — Conversation with no assistant turns → status is `.new`, `cacheTTLRemaining` is 0.
- `.warm` — latest assistant turn has 1h tokens, last timestamp 30min ago → status is `.warm`, remaining ≈ 30min.
- `.warm` — latest assistant turn has 5m tokens, last timestamp 2min ago → status is `.warm`, remaining ≈ 3min.
- `.cold` — latest assistant turn has 5m tokens, last timestamp 10min ago → status is `.cold`.
- Latest-turn-wins — conversation where turn 1 is 5m, turn 2 is 1h → TTL is 3600s.
- No-cache-turn fallback — conversation where turn 1 is 1h, turn 2 has zero cache_creation tokens → TTL is still 3600s (walks back to turn 1).

## Out of scope

- Changes to how Claude Code writes caches (Pits remains purely observational).
- Handling the 0.4% of mid-session TTL flips with any special logic — "latest turn wins" covers them.
- Cleanup / migration of the orphaned `ttlSeconds` AppStorage key.

## Success criteria

- Settings pane no longer shows the Cache TTL row.
- A conversation with no assistant turns shows a "new" indicator in its row.
- A conversation's warm/cold countdown reflects the TTL of its most recent assistant turn, not a global setting.
- All existing tests pass after removal of `ttlSeconds:` arguments.
- New tests cover `.new`, `.warm`, `.cold`, and the TTL-flip case.
