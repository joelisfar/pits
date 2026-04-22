# Observed Cache TTL Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Pits' user-configurable "Cache TTL" setting with per-conversation TTL derived from each session's observed `cache_creation` tokens in the JSONL transcript.

**Architecture:** `Conversation` gains a computed `observedTTLSeconds: TimeInterval?` that walks assistant turns newest-first and returns the TTL of the first turn that actually wrote to the cache (5m or 1h). `CacheStatus` expands to `{ new, warm, cold }`: `.new` when no cache-writing turn exists yet. The `ttlSeconds` stored property / init parameter, `ConversationStore.ttlSeconds`, the `@AppStorage("net.farriswheel.Pits.ttlSeconds")` binding, and the `Picker("Cache TTL:", ...)` in Settings are removed.

**Tech Stack:** Swift 5.9+, SwiftUI, XCTest, macOS 14 deployment target. XcodeGen generates `Pits.xcodeproj` from `project.yml`; `xcodebuild` drives build & test.

**Spec:** [docs/superpowers/specs/2026-04-22-observed-cache-ttl-design.md](../specs/2026-04-22-observed-cache-ttl-design.md)

---

## File Map

| File | Role in this plan |
|------|-------------------|
| `Pits/Models/Conversation.swift` | Add `observedTTLSeconds`, expand `CacheStatus`, rewrite `cacheStatus`/`cacheTTLRemaining`/`estimatedNextTurnCost`, drop `ttlSeconds` field |
| `Pits/Views/ConversationRowView.swift` | Handle `.new` state (status pill label, accent, countdown visibility, opacity) + update preview |
| `Pits/Views/SettingsView.swift` | Remove Cache TTL `Picker` and its `@AppStorage` declaration |
| `Pits/Stores/ConversationStore.swift` | Drop `@Published var ttlSeconds`, init parameter, and `ttlSeconds:` pass-through in `rebuildSnapshot` |
| `Pits/PitsApp.swift` | Drop `UserDefaults` TTL read and the `ttlSeconds:` argument to `ConversationStore.init` |
| `PitsTests/ConversationTests.swift` | Drop `ttlSeconds:` from test call sites; add `observedTTLSeconds` / tri-state tests; fix existing tests that relied on the old setting |
| `PitsTests/ConversationStoreTests.swift` | Drop `ttlSeconds:` from `makeStore`; remove the `test_updatesWhenTTLChanges` test |
| `PitsTests/ConversationStoreCacheTests.swift` | Drop `ttlSeconds:` from store construction |
| `PitsTests/CacheTimerTests.swift` | Update the test helper so turns write cache_creation tokens (so observed TTL resolves) |

---

## Task 1: Add `observedTTLSeconds` computed property (additive)

**Files:**
- Modify: `Pits/Models/Conversation.swift`
- Test: `PitsTests/ConversationTests.swift`

Pure addition, no behavior change elsewhere. We add the computed property on `Conversation` and unit-test the walk-back logic. `CacheStatus`, `cacheStatus`, `cacheTTLRemaining`, and `estimatedNextTurnCost` are untouched in this task.

- [ ] **Step 1: Write failing tests for `observedTTLSeconds`**

Add these tests to `PitsTests/ConversationTests.swift` (anywhere after the existing status tests, e.g., after `test_cacheStatus_coldAfterTTL` at line ~93):

```swift
func test_observedTTL_nilWhenNoTurns() {
    let c = Conversation(
        id: "s", projectName: "/x",
        filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
        turns: [],
        ttlSeconds: 300
    )
    XCTAssertNil(c.observedTTLSeconds)
}

func test_observedTTL_5mWhenLatestTurnHas5mTokens() {
    let t = Turn(
        requestId: "r", sessionId: "s",
        timestamp: Date(timeIntervalSince1970: 1000),
        model: "claude-opus-4-6",
        inputTokens: 0,
        cacheCreation5mTokens: 1_000,
        cacheCreation1hTokens: 0,
        cacheReadTokens: 0, outputTokens: 0,
        stopReason: "end_turn", isSubagent: false
    )
    let c = Conversation(
        id: "s", projectName: "/x",
        filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
        turns: [t], ttlSeconds: 300
    )
    XCTAssertEqual(c.observedTTLSeconds, 300)
}

func test_observedTTL_1hWhenLatestTurnHas1hTokens() {
    let t = Turn(
        requestId: "r", sessionId: "s",
        timestamp: Date(timeIntervalSince1970: 1000),
        model: "claude-opus-4-6",
        inputTokens: 0,
        cacheCreation5mTokens: 0,
        cacheCreation1hTokens: 1_000,
        cacheReadTokens: 0, outputTokens: 0,
        stopReason: "end_turn", isSubagent: false
    )
    let c = Conversation(
        id: "s", projectName: "/x",
        filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
        turns: [t], ttlSeconds: 300
    )
    XCTAssertEqual(c.observedTTLSeconds, 3600)
}

func test_observedTTL_latestCacheWritingTurnWins() {
    // Turn 1 (earlier): 5m. Turn 2 (later): 1h. Expect 1h.
    let t1 = Turn(
        requestId: "r1", sessionId: "s",
        timestamp: Date(timeIntervalSince1970: 1000),
        model: "claude-opus-4-6",
        inputTokens: 0,
        cacheCreation5mTokens: 1_000,
        cacheCreation1hTokens: 0,
        cacheReadTokens: 0, outputTokens: 0,
        stopReason: "end_turn", isSubagent: false
    )
    let t2 = Turn(
        requestId: "r2", sessionId: "s",
        timestamp: Date(timeIntervalSince1970: 2000),
        model: "claude-opus-4-6",
        inputTokens: 0,
        cacheCreation5mTokens: 0,
        cacheCreation1hTokens: 1_000,
        cacheReadTokens: 0, outputTokens: 0,
        stopReason: "end_turn", isSubagent: false
    )
    let c = Conversation(
        id: "s", projectName: "/x",
        filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
        turns: [t1, t2], ttlSeconds: 300
    )
    XCTAssertEqual(c.observedTTLSeconds, 3600)
}

func test_observedTTL_walksBackPastZeroCacheTurn() {
    // Turn 1 (earlier): 1h. Turn 2 (later): zero cache_creation tokens.
    // Expect 1h — walk back through the no-cache turn to the last cache-writing turn.
    let t1 = Turn(
        requestId: "r1", sessionId: "s",
        timestamp: Date(timeIntervalSince1970: 1000),
        model: "claude-opus-4-6",
        inputTokens: 0,
        cacheCreation5mTokens: 0,
        cacheCreation1hTokens: 1_000,
        cacheReadTokens: 0, outputTokens: 0,
        stopReason: "end_turn", isSubagent: false
    )
    let t2 = Turn(
        requestId: "r2", sessionId: "s",
        timestamp: Date(timeIntervalSince1970: 2000),
        model: "claude-opus-4-6",
        inputTokens: 0,
        cacheCreation5mTokens: 0,
        cacheCreation1hTokens: 0,
        cacheReadTokens: 5_000, outputTokens: 0,
        stopReason: "end_turn", isSubagent: false
    )
    let c = Conversation(
        id: "s", projectName: "/x",
        filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
        turns: [t1, t2], ttlSeconds: 300
    )
    XCTAssertEqual(c.observedTTLSeconds, 3600)
}

func test_observedTTL_nilWhenNoCacheWritingTurnsExist() {
    // Single assistant turn that only read from cache (no creation tokens).
    let t = Turn(
        requestId: "r", sessionId: "s",
        timestamp: Date(timeIntervalSince1970: 1000),
        model: "claude-opus-4-6",
        inputTokens: 5, cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
        cacheReadTokens: 5_000, outputTokens: 3,
        stopReason: "end_turn", isSubagent: false
    )
    let c = Conversation(
        id: "s", projectName: "/x",
        filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
        turns: [t], ttlSeconds: 300
    )
    XCTAssertNil(c.observedTTLSeconds)
}
```

- [ ] **Step 2: Run tests to verify they fail (compile error — no such property)**

```bash
cd /Users/jifarris/Projects/pits && xcodegen generate && xcodebuild -project Pits.xcodeproj -scheme Pits -destination 'platform=macOS' test 2>&1 | tail -30
```

Expected: build fails with `value of type 'Conversation' has no member 'observedTTLSeconds'`.

- [ ] **Step 3: Add `observedTTLSeconds` to `Conversation`**

In `Pits/Models/Conversation.swift`, add this after the existing `lastActivityTimestamp` var (around line 91) and before `cacheTTLRemaining`:

```swift
/// TTL of the most recent assistant turn that wrote to the cache
/// (`.ephemeral_5m_input_tokens` → 300s, `.ephemeral_1h_input_tokens` → 3600s).
/// Walks turns newest-first to tolerate occasional no-cache turns without
/// losing the established TTL. Nil only when no turn in the session has
/// ever written to the cache — represented as `.new` in `cacheStatus`.
var observedTTLSeconds: TimeInterval? {
    let sortedDesc = turns.sorted(by: { $0.timestamp > $1.timestamp })
    for t in sortedDesc {
        if t.cacheCreation1hTokens > 0 { return 3600 }
        if t.cacheCreation5mTokens > 0 { return 300 }
    }
    return nil
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/jifarris/Projects/pits && xcodegen generate && xcodebuild -project Pits.xcodeproj -scheme Pits -destination 'platform=macOS' test 2>&1 | tail -30
```

Expected: all tests pass (new ones plus all existing).

- [ ] **Step 5: Commit**

```bash
git add Pits/Models/Conversation.swift PitsTests/ConversationTests.swift
git commit -m "$(cat <<'EOF'
feat: derive observedTTLSeconds from turn cache_creation split

Pure addition — no callers yet. Walks turns newest-first and returns
the first cache-writing turn's TTL (5m or 1h), or nil when no turn has
ever written to the cache.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Expand `CacheStatus` to tri-state & switch to observed TTL

**Files:**
- Modify: `Pits/Models/Conversation.swift`
- Modify: `Pits/Views/ConversationRowView.swift` (exhaustive switch fix + preview)
- Modify: `Pits/Stores/ConversationStore.swift` (drop `ttlSeconds:` arg in rebuildSnapshot)
- Test: `PitsTests/ConversationTests.swift`, `PitsTests/CacheTimerTests.swift`, `PitsTests/ConversationStoreCacheTests.swift`, `PitsTests/ConversationStoreTests.swift`

This task replaces the old setting-driven TTL with the observed-TTL logic across the whole data model. `ConversationStore.ttlSeconds` and the Settings picker are still in place after this task (removed in Task 4). `ConversationRowView` gets a minimal `.new` branch (treating it like `.cold` visually); proper UX polish is Task 3.

### TDD cycle — tri-state `cacheStatus`

- [ ] **Step 1: Update existing status tests and add `.new` tests**

In `PitsTests/ConversationTests.swift`, the existing `turn()` helper sets `cacheCreationTokens: cacheWrite` which routes to the 5m field. Existing `test_cacheStatus_warmWithinTTL` and `test_cacheStatus_coldAfterTTL` pass `cacheWrite: 0` (no cache tokens), which after the refactor would make the session `.new`, not `.warm` / `.cold`. Change those tests to inject a 5m cache_creation token so the observed TTL resolves to 300s:

Replace `test_cacheStatus_warmWithinTTL`:

```swift
func test_cacheStatus_warmWithinTTL() {
    let c = Conversation(
        id: "s", projectName: "/x",
        filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
        turns: [turn(ts: 1000, cacheWrite: 1_000)]  // cacheWrite goes to 5m field (TTL = 300s)
    )
    let now = Date(timeIntervalSince1970: 1100)
    XCTAssertEqual(c.cacheStatus(at: now), .warm)
    XCTAssertEqual(c.cacheTTLRemaining(at: now), 200)
}
```

Replace `test_cacheStatus_coldAfterTTL`:

```swift
func test_cacheStatus_coldAfterTTL() {
    let c = Conversation(
        id: "s", projectName: "/x",
        filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
        turns: [turn(ts: 1000, cacheWrite: 1_000)]
    )
    let now = Date(timeIntervalSince1970: 1500)
    XCTAssertEqual(c.cacheStatus(at: now), .cold)
    XCTAssertEqual(c.cacheTTLRemaining(at: now), 0)
}
```

Add new tri-state tests:

```swift
func test_cacheStatus_newWhenNoAssistantTurns() {
    let c = Conversation(
        id: "s", projectName: "/x",
        filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
        turns: []
    )
    XCTAssertEqual(c.cacheStatus(at: Date()), .new)
    XCTAssertEqual(c.cacheTTLRemaining(at: Date()), 0)
}

func test_cacheStatus_newWhenNoCacheWritingTurns() {
    // Assistant replied but no cache_creation tokens.
    let t = Turn(
        requestId: "r", sessionId: "s",
        timestamp: Date(timeIntervalSince1970: 1000),
        model: "claude-opus-4-6",
        inputTokens: 5, cacheCreation5mTokens: 0, cacheCreation1hTokens: 0,
        cacheReadTokens: 0, outputTokens: 3,
        stopReason: "end_turn", isSubagent: false
    )
    let c = Conversation(
        id: "s", projectName: "/x",
        filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
        turns: [t]
    )
    XCTAssertEqual(c.cacheStatus(at: Date(timeIntervalSince1970: 1100)), .new)
}

func test_cacheStatus_warmUses1hTTLWhenLatestTurnIs1h() {
    let t = Turn(
        requestId: "r", sessionId: "s",
        timestamp: Date(timeIntervalSince1970: 1000),
        model: "claude-opus-4-6",
        inputTokens: 0,
        cacheCreation5mTokens: 0,
        cacheCreation1hTokens: 5_000,
        cacheReadTokens: 0, outputTokens: 0,
        stopReason: "end_turn", isSubagent: false
    )
    let c = Conversation(
        id: "s", projectName: "/x",
        filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
        turns: [t]
    )
    // 30 minutes after the turn — inside a 1h window, outside a 5m window.
    let now = Date(timeIntervalSince1970: 1000 + 1800)
    XCTAssertEqual(c.cacheStatus(at: now), .warm)
    XCTAssertEqual(c.cacheTTLRemaining(at: now), 1800)
}
```

Note: these tests *remove* the `ttlSeconds:` argument, which will also fail to compile until Step 3.

- [ ] **Step 2: Run tests to verify they fail to compile**

```bash
cd /Users/jifarris/Projects/pits && xcodegen generate && xcodebuild -project Pits.xcodeproj -scheme Pits -destination 'platform=macOS' test 2>&1 | tail -40
```

Expected: compile errors referencing `ttlSeconds:` argument and missing enum case `.new`.

- [ ] **Step 3: Update `Conversation.swift` — expand enum, rewrite methods, drop `ttlSeconds` field**

Replace [Pits/Models/Conversation.swift:3](../../../Pits/Models/Conversation.swift#L3):

```swift
enum CacheStatus { case new, warm, cold }
```

Remove the `ttlSeconds: TimeInterval` stored property and the `ttlSeconds:` init parameter. The init should now be:

```swift
init(
    id: String,
    projectName: String,
    title: String? = nil,
    firstMessageText: String? = nil,
    filePath: URL,
    turns: [Turn],
    humanTurns: [HumanTurn] = []
) {
    self.id = id
    self.projectName = projectName
    self.title = title
    self.firstMessageText = firstMessageText
    self.filePath = filePath
    self.turns = turns
    self.humanTurns = humanTurns
}
```

Rewrite the status methods:

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

Rewrite `estimatedNextTurnCost` to handle three cases and drop the blend:

```swift
func estimatedNextTurnCost(at now: Date) -> Double {
    guard let last = turns.max(by: { $0.timestamp < $1.timestamp }) else { return 0 }
    guard let rates = Pricing.rates(for: last.model) else { return 0 }
    let context = Double(last.contextSize)
    switch cacheStatus(at: now) {
    case .warm:
        return context * rates.cacheRead / 1_000_000.0
    case .cold:
        // Observed data: every cache-writing turn is pure 5m or pure 1h (0/29,817 mix).
        let writeRate = last.cacheCreation1hTokens > 0 ? rates.cacheWrite1h : rates.cacheWrite5m
        return context * writeRate / 1_000_000.0
    case .new:
        // No cache has been written yet; estimate using the conservative 5m write rate.
        return context * rates.cacheWrite5m / 1_000_000.0
    }
}
```

Update `filtered(toMonth:)` to drop the `ttlSeconds:` arg from its reconstruction call.

- [ ] **Step 4: Update `ConversationRowView.swift` switches + preview**

In [Pits/Views/ConversationRowView.swift:18-22](../../../Pits/Views/ConversationRowView.swift#L18-L22), add the `.new` branch to the `accent` switch (placeholder — real UX in Task 3):

```swift
private var accent: Color {
    switch status {
    case .warm: return remaining <= 60 ? .red : .orange
    case .cold: return .secondary
    case .new: return .secondary
    }
}
```

In the preview at line 146-151, drop `ttlSeconds: 300`:

```swift
let c = Conversation(
    id: "s", projectName: "/Users/j/Projects/demo",
    title: "Wire session titles into the row view",
    filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
    turns: [turn]
)
```

- [ ] **Step 5: Update `ConversationStore.rebuildSnapshot`**

In [Pits/Stores/ConversationStore.swift:215-220](../../../Pits/Stores/ConversationStore.swift#L215-L220), drop `ttlSeconds: ttlSeconds` from the `Conversation(...)` call:

```swift
result.append(Conversation(
    id: sid, projectName: projectName,
    title: parser.title(sessionId: sid),
    firstMessageText: parser.firstMessageText(sessionId: sid),
    filePath: url, turns: turns, humanTurns: humans
))
```

Leave the `@Published var ttlSeconds` field itself for now — removing it changes `SettingsView` and `PitsApp`, which is Task 4's job.

- [ ] **Step 6: Strip `ttlSeconds:` from all existing test call sites**

All 18 `ttlSeconds: ...` references in the test suite (see the explorer grep) need to be removed. Work through each file:

**`PitsTests/ConversationTests.swift`** — strike `ttlSeconds: 300` from every `Conversation(...)` call (lines 56, 66, 76, 88, 101, 113, 123, 150, 186, 198, 212, 224). Remove the `XCTAssertEqual(f.ttlSeconds, 300)` assertion at line 230.

Two existing tests need semantic fixes, not just argument stripping:

1. `test_estimatedNextTurnCost_warmUsesCacheReadRate` (line 95-105) passes `cacheWrite: 0` with its turn, which after the refactor yields `.new`, not `.warm`. Fix by giving the turn a 5m cache_creation token so `observedTTLSeconds` resolves to 300s:

```swift
func test_estimatedNextTurnCost_warmUsesCacheReadRate() {
    // Last turn has 1M tokens of context; opus 4.6 cache_read = $0.50/M.
    // Inject a cache_creation token so observedTTLSeconds = 300s.
    let c = Conversation(
        id: "s", projectName: "/x",
        filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
        turns: [turn(ts: 1000, input: 0, cacheWrite: 1_000, cacheRead: 1_000_000, output: 0)]
    )
    let now = Date(timeIntervalSince1970: 1100)  // 100s elapsed — warm under 5m TTL
    XCTAssertEqual(c.estimatedNextTurnCost(at: now), 0.50, accuracy: 0.0001)
}
```

2. `test_estimatedNextTurnCost_coldUsesCacheWriteRate` (line 107-117) likewise uses `cacheWrite: 0`, which would yield `.new` instead of `.cold` after the refactor. Its expected value ($6.25/M on opus 4.6) happens to equal the `.new` path's conservative 5m rate, so the assertion would still pass — but the test name and comment would be misleading. Either rename the test or (cleaner) make it test `.cold` properly:

```swift
func test_estimatedNextTurnCost_coldUsesCacheWriteRate() {
    // Same 1M context, with a cache_creation token so observedTTLSeconds = 300s.
    // cold → cache_write_5m $6.25/M on opus 4.6.
    let c = Conversation(
        id: "s", projectName: "/x",
        filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
        turns: [turn(ts: 1000, input: 0, cacheWrite: 1_000, cacheRead: 1_000_000, output: 0)]
    )
    let now = Date(timeIntervalSince1970: 1500)  // 500s elapsed — past 5m TTL → cold
    XCTAssertEqual(c.estimatedNextTurnCost(at: now), 6.25, accuracy: 0.0001)
}
```

**`PitsTests/CacheTimerTests.swift:5-19`** — the `conversation(id:lastResponse:ttl:)` helper needs a different shape since TTL is now inferred from turn tokens. Rewrite:

```swift
private func conversation(id: String, lastResponse: TimeInterval, ttl: TimeInterval) -> Conversation {
    // Encode the desired TTL into the turn's cache_creation tokens so that
    // observedTTLSeconds resolves to the value the test asked for.
    let fivem: Int = (ttl == 300) ? 1_000 : 0
    let oneh: Int = (ttl == 3600) ? 1_000 : 0
    return Conversation(
        id: id, projectName: "/x",
        filePath: URL(fileURLWithPath: "/tmp/\(id).jsonl"),
        turns: [
            Turn(requestId: "r-\(id)", sessionId: id,
                 timestamp: Date(timeIntervalSince1970: lastResponse),
                 model: "claude-opus-4-6",
                 inputTokens: 0,
                 cacheCreation5mTokens: fivem,
                 cacheCreation1hTokens: oneh,
                 cacheReadTokens: 0, outputTokens: 0,
                 stopReason: "end_turn", isSubagent: false)
        ]
    )
}
```

**`PitsTests/ConversationStoreCacheTests.swift:25`** — remove `ttlSeconds: 300,`.

**`PitsTests/ConversationStoreTests.swift:16`** — remove `ttlSeconds: ttl,`.

**`PitsTests/ConversationStoreTests.swift:67-77`** — the `test_updatesWhenTTLChanges` test verifies the now-deleted observable behavior. Delete the entire test.

**`PitsTests/ConversationStoreTests.swift:157`** — remove `ttlSeconds: 300,`.

**`PitsTests/ConversationTests.swift:130-154`** — the test `test_estimatedNextTurnCost_coldWeightsWriteRateByLastTurnMix` asserts the old 5m/1h blend behavior, which is deleted. Replace it with a test of the clean 1h-only cold path:

```swift
func test_estimatedNextTurnCost_coldUses1hRateWhenLastTurnIs1h() {
    // 1M tokens pure-1h cache_creation on opus 4.7: cache_write_1h = $10.00/M,
    // so the context size (1M) × rate / 1M = $10.00.
    let t = Turn(
        requestId: "r", sessionId: "s",
        timestamp: Date(timeIntervalSince1970: 1000),
        model: "claude-opus-4-7",
        inputTokens: 0,
        cacheCreation5mTokens: 0,
        cacheCreation1hTokens: 1_000_000,
        cacheReadTokens: 0, outputTokens: 1,
        stopReason: "end_turn", isSubagent: false
    )
    let c = Conversation(
        id: "s", projectName: "/x",
        filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
        turns: [t]
    )
    // 2 hours after the turn — past the 1h window → cold.
    let now = Date(timeIntervalSince1970: 1000 + 7200)
    XCTAssertEqual(c.estimatedNextTurnCost(at: now), 10.00, accuracy: 0.0001)
}
```

Add a `.new`-state cost test:

```swift
func test_estimatedNextTurnCost_newStateUses5mRate() {
    // Assistant turn with no cache writes → .new state → conservative 5m rate.
    // 1M tokens context on opus 4.6: cache_write_5m = $3.75/M.
    let t = Turn(
        requestId: "r", sessionId: "s",
        timestamp: Date(timeIntervalSince1970: 1000),
        model: "claude-opus-4-6",
        inputTokens: 0,
        cacheCreation5mTokens: 0,
        cacheCreation1hTokens: 0,
        cacheReadTokens: 1_000_000, outputTokens: 1,
        stopReason: "end_turn", isSubagent: false
    )
    let c = Conversation(
        id: "s", projectName: "/x",
        filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
        turns: [t]
    )
    XCTAssertEqual(c.estimatedNextTurnCost(at: Date(timeIntervalSince1970: 1100)), 3.75, accuracy: 0.0001)
}
```

Verify the opus 4.6 `cacheWrite5m` rate by reading `Pits/Models/Pricing.swift`. The cost equals `1_000_000 * rate / 1_000_000 = rate`, so the assertion must match the current value in `Pricing.swift`. If the project has overridden that via `Pricing.overlay`, read from `Pricing.rates(for: "claude-opus-4-6")!.cacheWrite5m` instead of hard-coding.

- [ ] **Step 7: Run full test suite**

```bash
cd /Users/jifarris/Projects/pits && xcodegen generate && xcodebuild -project Pits.xcodeproj -scheme Pits -destination 'platform=macOS' test 2>&1 | tail -40
```

Expected: all tests pass.

- [ ] **Step 8: Commit**

```bash
git add Pits/Models/Conversation.swift Pits/Views/ConversationRowView.swift Pits/Stores/ConversationStore.swift PitsTests/*.swift
git commit -m "$(cat <<'EOF'
feat: tri-state CacheStatus driven by observed TTL

CacheStatus gains a .new case for conversations with no cache-writing
turn yet. cacheStatus/cacheTTLRemaining now derive from the turn-level
cache_creation split instead of the ttlSeconds setting.
estimatedNextTurnCost drops its 5m/1h blend (observed data shows 0%
mixed turns across 29k samples) and handles the .new state with a
conservative 5m write-rate estimate.

The Conversation.ttlSeconds field is gone; the setting / AppStorage /
Settings picker plumbing still exists and is removed in a follow-up.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Distinct `.new` rendering in `ConversationRowView`

**Files:**
- Modify: `Pits/Views/ConversationRowView.swift`

This task gives `.new` its own label and behavior in the row, so users can tell "waiting for first response" apart from cold.

- [ ] **Step 1: Update visible pill text**

In [Pits/Views/ConversationRowView.swift:126](../../../Pits/Views/ConversationRowView.swift#L126), replace:

```swift
Text(status == .warm ? "warm" : "cold")
```

with:

```swift
Text({
    switch status {
    case .warm: return "warm"
    case .cold: return "cold"
    case .new: return "new"
    }
}())
```

- [ ] **Step 2: Update `showCountdown` and `dotFill` for `.new`**

The countdown only ever shows for `.warm`, so `showCountdown` is unchanged. Update `dotFill` so `.new` displays as a neutral dot (same as cold) — no special-case:

```swift
private var dotFill: Color {
    guard isOpen else { return .clear }
    return status == .warm ? accent : .secondary
}
```

(Already correct — `.new` falls through to `.secondary`. Verify no change needed here.)

- [ ] **Step 3: Update `rowOpacity` so `.new` doesn't dim the row**

In [Pits/Views/ConversationRowView.swift:39-42](../../../Pits/Views/ConversationRowView.swift#L39-L42), change:

```swift
private var rowOpacity: Double {
    if !isOpen { return 0.45 }
    return status == .cold ? 0.65 : 1.0
}
```

(Already correct — `.new` falls through to `1.0`, which makes sense: a brand-new conversation is active work, not stale. Verify no change needed.)

- [ ] **Step 4: Build and spot-check**

```bash
cd /Users/jifarris/Projects/pits && xcodegen generate && xcodebuild -project Pits.xcodeproj -scheme Pits -destination 'platform=macOS' build 2>&1 | tail -10
```

Expected: clean build. No test changes — the row-view output isn't unit tested.

- [ ] **Step 5: Commit**

```bash
git add Pits/Views/ConversationRowView.swift
git commit -m "$(cat <<'EOF'
feat: distinct 'new' label in conversation row for pre-response state

Rows for conversations with no cache-writing turn now render "new" in
the status pill instead of "cold". Row opacity and dot fill already
handle the new case correctly — no change needed there.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Remove Settings picker & orphaned plumbing

**Files:**
- Modify: `Pits/Views/SettingsView.swift`
- Modify: `Pits/Stores/ConversationStore.swift`
- Modify: `Pits/PitsApp.swift`

With nothing in the data model reading `ttlSeconds` anymore, strip the setting, store property, and AppStorage/UserDefaults plumbing.

- [ ] **Step 1: Remove the Cache TTL picker from `SettingsView`**

In [Pits/Views/SettingsView.swift](../../../Pits/Views/SettingsView.swift):

Delete line 7:
```swift
@AppStorage("net.farriswheel.Pits.ttlSeconds") private var ttlSeconds: Double = 300
```

Delete the first `Section` block (lines 14-25):
```swift
Section {
    Picker("Cache TTL:", selection: Binding(
        get: { [300.0, 3600.0].contains(ttlSeconds) ? ttlSeconds : 300.0 },
        set: { new in
            ttlSeconds = new
            store.ttlSeconds = new
        }
    )) {
        Text("5 minutes").tag(300.0)
        Text("1 hour").tag(3600.0)
    }
}
```

The form height may look too tall now. Reduce the frame at line 52:

```swift
.frame(width: 440, height: 180)
```

- [ ] **Step 2: Remove `ttlSeconds` from `ConversationStore`**

In [Pits/Stores/ConversationStore.swift](../../../Pits/Stores/ConversationStore.swift):

Delete lines 23-25:
```swift
@Published var ttlSeconds: TimeInterval {
    didSet { rebuildSnapshot() }
}
```

Remove the `ttlSeconds: TimeInterval,` parameter from `init(...)` (line 45) and the `self.ttlSeconds = ttlSeconds` assignment (line 51).

- [ ] **Step 3: Remove `ttlSeconds` read from `PitsApp`**

In [Pits/PitsApp.swift](../../../Pits/PitsApp.swift):

Delete line 82:
```swift
let ttl = UserDefaults.standard.object(forKey: "net.farriswheel.Pits.ttlSeconds") as? Double ?? 300
```

Update line 97 to remove the `ttlSeconds:` argument:
```swift
let s = ConversationStore(rootDirectory: root, cache: cache)
```

- [ ] **Step 4: Update remaining test call sites that construct the store**

The `makeStore(...)` helper at `PitsTests/ConversationStoreTests.swift:6-20` currently takes a `ttl` parameter and passes it to `ConversationStore(...)`. Rewrite:

```swift
private func makeStore(
    openSessionsWatcher: OpenSessionsWatcher = OpenSessionsWatcher(
        sessionsDirectory: URL(fileURLWithPath: "/nonexistent/sessions")
    )
) -> ConversationStore {
    let silentDefaults = UserDefaults(suiteName: "net.farriswheel.Pits.test-\(UUID().uuidString)")!
    let silentSound = SoundManager(defaults: silentDefaults, player: { _ in })
    return ConversationStore(
        rootDirectory: URL(fileURLWithPath: "/nonexistent"),
        sound: silentSound,
        openSessionsWatcher: openSessionsWatcher
    )
}
```

Check `PitsTests/ConversationStoreCacheTests.swift` for any remaining `ttlSeconds:` — likely already removed in Task 2 Step 6. If any call site still passes it, strip it now.

- [ ] **Step 5: Run the full test suite**

```bash
cd /Users/jifarris/Projects/pits && xcodegen generate && xcodebuild -project Pits.xcodeproj -scheme Pits -destination 'platform=macOS' test 2>&1 | tail -30
```

Expected: all tests pass.

- [ ] **Step 6: Grep for orphaned references**

```bash
cd /Users/jifarris/Projects/pits && git grep -n "ttlSeconds\|Cache TTL" -- 'Pits/**/*.swift' 'PitsTests/**/*.swift'
```

Expected: no matches in Swift sources. (Docs under `docs/` may still reference historical TTL — leave those alone.)

- [ ] **Step 7: Commit**

```bash
git add Pits/Views/SettingsView.swift Pits/Stores/ConversationStore.swift Pits/PitsApp.swift PitsTests/ConversationStoreTests.swift
git commit -m "$(cat <<'EOF'
refactor: remove Cache TTL setting and its plumbing

The setting was a guess at what Claude Code was actually doing;
observedTTLSeconds now reads the real TTL from each conversation's
transcript. Removes the SettingsView picker, the @Published store
field, the UserDefaults read at launch, and the ttlSeconds: init
params threaded through callers and tests.

The orphaned net.farriswheel.Pits.ttlSeconds AppStorage key is left in
place — harmless, and migration code is more risk than it's worth.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Manual smoke test

**Files:** none (verification only)

Automated tests cover the logic; this task confirms the UI behaves correctly end-to-end with real JSONL data.

- [ ] **Step 1: Build & run**

```bash
cd /Users/jifarris/Projects/pits && xcodegen generate && xcodebuild -project Pits.xcodeproj -scheme Pits -destination 'platform=macOS' -configuration Debug build 2>&1 | tail -5
open Pits.xcodeproj  # run from Xcode, or:
# xcodebuild run via xcrun simctl equivalent doesn't apply for macOS apps —
# use `open` on the built .app bundle under DerivedData, or launch from Xcode.
```

- [ ] **Step 2: Verify a live conversation with response history**

Find an active Claude Code session in the Pits list. Confirm:
- Status pill says "warm" or "cold" (not "new")
- Countdown matches expected window: under ~5 min for 5m-TTL conversations, up to ~1h for 1h-TTL
- "next turn ~" estimate looks reasonable

- [ ] **Step 3: Verify a brand-new conversation shows "new"**

Open a new Claude Code conversation and send a message. Before the response lands (or with a small test conversation that has only user messages in the JSONL), confirm the row displays:
- Status pill text: "new"
- No countdown value
- Row not dimmed (full opacity)
- After the first response lands, status transitions to "warm"

If you can't easily create this state manually, inspect the screen briefly after Pits starts — a conversation whose JSONL is mid-write may momentarily show `.new`.

- [ ] **Step 4: Verify Settings pane no longer shows Cache TTL row**

Open Pits Settings (⌘,). Confirm the Cache TTL picker is gone and the remaining toggles (sounds, keep-on-top, launch-at-login) render without visual gaps. Form height should feel appropriate.

- [ ] **Step 5: Commit any polish needed**

If smoke test uncovers issues (typography, spacing, label wording), fix and commit. Otherwise nothing to commit — this is verification.

---

## Done Definition

- `observedTTLSeconds` reads the real TTL from the latest cache-writing turn.
- `CacheStatus` is `{ new, warm, cold }`; conversations with no cache-writing turn show `.new`.
- The Cache TTL row is gone from Settings.
- `ConversationStore.ttlSeconds`, the `ttlSeconds:` init params, and the `UserDefaults` TTL read are all deleted.
- Existing tests pass; new tests cover `.new`, walk-back logic, and latest-turn-wins.
- Manual smoke test confirms the live app shows correct pill labels for new / warm / cold conversations.
