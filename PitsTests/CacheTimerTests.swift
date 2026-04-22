import XCTest
@testable import Pits

final class CacheTimerTests: XCTestCase {
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

    func test_tick_emitsTransitionedToCold_onceOnly() {
        let timer = CacheTimer()
        let convs = [conversation(id: "s", lastResponse: 1000, ttl: 300)]

        // Warm at now=1100 (200s left).
        let events1 = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1100), openSessionIds: ["s"])
        XCTAssertTrue(events1.isEmpty)

        // Cold at now=1301 (past TTL).
        let events2 = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1301), openSessionIds: ["s"])
        XCTAssertEqual(events2, [.transitionedToCold("s")])

        // No repeat on subsequent ticks while still cold.
        let events3 = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1400), openSessionIds: ["s"])
        XCTAssertTrue(events3.isEmpty)
    }

    func test_tick_emitsOneMinuteWarning_onceOnly() {
        let timer = CacheTimer()
        let convs = [conversation(id: "s", lastResponse: 1000, ttl: 300)]

        // 61 seconds remaining: no warning yet.
        let events1 = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1239), openSessionIds: ["s"])
        XCTAssertTrue(events1.isEmpty)

        // 59 seconds remaining: warning fires.
        let events2 = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1241), openSessionIds: ["s"])
        XCTAssertEqual(events2, [.oneMinuteWarning("s")])

        // Subsequent ticks in the warning window: no repeat.
        let events3 = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1260), openSessionIds: ["s"])
        XCTAssertTrue(events3.isEmpty)
    }

    func test_warmAfterNewTurn_resetsTransitionState() {
        let timer = CacheTimer()
        var convs = [conversation(id: "s", lastResponse: 1000, ttl: 300)]

        _ = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1400), openSessionIds: ["s"]) // cold + transition emitted
        // Simulate a new assistant reply at ts=1500 — cache becomes warm again.
        convs = [conversation(id: "s", lastResponse: 1500, ttl: 300)]

        // New tick while warm: nothing.
        _ = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1550), openSessionIds: ["s"])

        // Cold transition should fire again once it times out.
        let events = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1801), openSessionIds: ["s"])
        XCTAssertEqual(events, [.transitionedToCold("s")])
    }

    // MARK: - Open-session gating for the one-minute warning

    func test_tick_suppressesOneMinuteWarning_whenSessionNotOpen() {
        let timer = CacheTimer()
        let convs = [conversation(id: "s", lastResponse: 1000, ttl: 300)]

        // Establish warm state well before the warning window so the warning
        // would otherwise fire on the next tick.
        _ = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1100), openSessionIds: [])

        // Cross into the warning window with the session still closed.
        let events = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1241), openSessionIds: [])
        XCTAssertTrue(events.isEmpty, "expected no warning for a closed session, got \(events)")
    }

    func test_tick_firesOneMinuteWarning_onReopen_withinWindow() {
        let timer = CacheTimer()
        let convs = [conversation(id: "s", lastResponse: 1000, ttl: 300)]

        // Warm, session closed, cross into window: suppressed.
        _ = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1100), openSessionIds: [])
        _ = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1241), openSessionIds: [])

        // User reopens the tab while still inside the warning window.
        let events = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1250), openSessionIds: ["s"])
        XCTAssertEqual(events, [.oneMinuteWarning("s")])

        // Does not re-fire on subsequent ticks.
        let events2 = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1260), openSessionIds: ["s"])
        XCTAssertTrue(events2.isEmpty)
    }

    func test_tick_suppressesOneMinuteWarning_onFirstObservation_whenAlreadyInWindow() {
        // App just launched; a conversation is already inside the warning
        // window and closed. We must not fire a retroactive warning even if
        // the user later reopens it — the warning is for *entry* to the
        // window, not for already being inside it.
        let timer = CacheTimer()
        let convs = [conversation(id: "s", lastResponse: 1000, ttl: 300)]

        // First observation already inside the window, closed.
        _ = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1250), openSessionIds: [])

        // Reopen later, still in window: no warning.
        let events = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1255), openSessionIds: ["s"])
        XCTAssertTrue(events.isEmpty)
    }

    func test_tick_emitsFifteenSecondWarning_onceOnly() {
        let timer = CacheTimer()
        let convs = [conversation(id: "s", lastResponse: 1000, ttl: 300)]

        // 16 seconds remaining: no 15s warning yet.
        let events1 = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1284), openSessionIds: ["s"])
        XCTAssertFalse(events1.contains(.fifteenSecondWarning("s")), "got: \(events1)")

        // 14 seconds remaining: warning fires.
        let events2 = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1286), openSessionIds: ["s"])
        XCTAssertTrue(events2.contains(.fifteenSecondWarning("s")), "got: \(events2)")

        // Subsequent ticks in the warning window: no repeat.
        let events3 = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1290), openSessionIds: ["s"])
        XCTAssertFalse(events3.contains(.fifteenSecondWarning("s")), "got: \(events3)")
    }

    func test_tick_suppressesFifteenSecondWarning_whenSessionNotOpen() {
        let timer = CacheTimer()
        let convs = [conversation(id: "s", lastResponse: 1000, ttl: 300)]
        // Establish state outside both warning windows.
        _ = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1100), openSessionIds: [])
        // Cross into 15s window with session closed.
        let events = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1289), openSessionIds: [])
        XCTAssertFalse(events.contains(.fifteenSecondWarning("s")), "got: \(events)")
    }

    func test_tick_suppressesFifteenSecondWarning_onFirstObservation_whenAlreadyInWindow() {
        let timer = CacheTimer()
        let convs = [conversation(id: "s", lastResponse: 1000, ttl: 300)]
        // First observation already inside the 15s window.
        _ = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1289), openSessionIds: [])
        // Reopen later, still inside: no warning.
        let events = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1292), openSessionIds: ["s"])
        XCTAssertFalse(events.contains(.fifteenSecondWarning("s")), "got: \(events)")
    }

    func test_warmAfterNewTurn_resetsFifteenSecondWarning() {
        let timer = CacheTimer()
        var convs = [conversation(id: "s", lastResponse: 1000, ttl: 300)]
        // Fire and consume the 15s warning.
        _ = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1100), openSessionIds: ["s"])
        _ = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1289), openSessionIds: ["s"])
        // New assistant reply at ts=1500 — cache warmed again.
        convs = [conversation(id: "s", lastResponse: 1500, ttl: 300)]
        // Tick well outside warning window first to refresh state.
        _ = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1550), openSessionIds: ["s"])
        // Cross into 15s window of the *new* warm period.
        let events = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1789), openSessionIds: ["s"])
        XCTAssertTrue(events.contains(.fifteenSecondWarning("s")), "got: \(events)")
    }
}
