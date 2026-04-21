import XCTest
@testable import Pits

final class CacheTimerTests: XCTestCase {
    private func conversation(id: String, lastResponse: TimeInterval, ttl: TimeInterval) -> Conversation {
        Conversation(
            id: id, projectName: "/x",
            filePath: URL(fileURLWithPath: "/tmp/\(id).jsonl"),
            turns: [
                Turn(requestId: "r-\(id)", sessionId: id,
                     timestamp: Date(timeIntervalSince1970: lastResponse),
                     model: "claude-opus-4-6",
                     inputTokens: 0, cacheCreationTokens: 0,
                     cacheReadTokens: 0, outputTokens: 0,
                     stopReason: "end_turn", isSubagent: false)
            ],
            ttlSeconds: ttl
        )
    }

    func test_tick_emitsTransitionedToCold_onceOnly() {
        let timer = CacheTimer()
        let convs = [conversation(id: "s", lastResponse: 1000, ttl: 300)]

        // Warm at now=1100 (200s left).
        let events1 = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1100))
        XCTAssertTrue(events1.isEmpty)

        // Cold at now=1301 (past TTL).
        let events2 = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1301))
        XCTAssertEqual(events2, [.transitionedToCold("s")])

        // No repeat on subsequent ticks while still cold.
        let events3 = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1400))
        XCTAssertTrue(events3.isEmpty)
    }

    func test_tick_emitsOneMinuteWarning_onceOnly() {
        let timer = CacheTimer()
        let convs = [conversation(id: "s", lastResponse: 1000, ttl: 300)]

        // 61 seconds remaining: no warning yet.
        let events1 = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1239))
        XCTAssertTrue(events1.isEmpty)

        // 59 seconds remaining: warning fires.
        let events2 = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1241))
        XCTAssertEqual(events2, [.oneMinuteWarning("s")])

        // Subsequent ticks in the warning window: no repeat.
        let events3 = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1260))
        XCTAssertTrue(events3.isEmpty)
    }

    func test_warmAfterNewTurn_resetsTransitionState() {
        let timer = CacheTimer()
        var convs = [conversation(id: "s", lastResponse: 1000, ttl: 300)]

        _ = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1400)) // cold + transition emitted
        // Simulate a new assistant reply at ts=1500 — cache becomes warm again.
        convs = [conversation(id: "s", lastResponse: 1500, ttl: 300)]

        // New tick while warm: nothing.
        _ = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1550))

        // Cold transition should fire again once it times out.
        let events = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1801))
        XCTAssertEqual(events, [.transitionedToCold("s")])
    }
}
