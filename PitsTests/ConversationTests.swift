import XCTest
@testable import Pits

final class ConversationTests: XCTestCase {
    private func turn(
        ts: TimeInterval,
        input: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0, output: Int = 0,
        requestId: String = UUID().uuidString,
        model: String = "claude-opus-4-6"
    ) -> Turn {
        Turn(
            requestId: requestId, sessionId: "s",
            timestamp: Date(timeIntervalSince1970: ts),
            model: model,
            inputTokens: input, cacheCreationTokens: cacheWrite,
            cacheReadTokens: cacheRead, outputTokens: output,
            stopReason: "end_turn", isSubagent: false
        )
    }

    func test_projectName_fromPath() {
        let url = URL(fileURLWithPath: "/Users/j/.claude/projects/-Users-jifarris-Projects-pits/abc.jsonl")
        XCTAssertEqual(Conversation.projectName(from: url), "/Users/jifarris/Projects/pits")
    }

    func test_totalCost_sumOfTurns() {
        let c = Conversation(
            id: "s",
            projectName: "/x",
            filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
            turns: [turn(ts: 0, input: 1_000_000), turn(ts: 1, output: 1_000_000)],
            ttlSeconds: 300
        )
        XCTAssertEqual(c.totalCost, 30.00, accuracy: 0.0001)
    }

    func test_lastResponseTimestamp_isMostRecentTurn() {
        let c = Conversation(
            id: "s", projectName: "/x",
            filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
            turns: [turn(ts: 100), turn(ts: 50), turn(ts: 200)],
            ttlSeconds: 300
        )
        XCTAssertEqual(c.lastResponseTimestamp, Date(timeIntervalSince1970: 200))
    }

    func test_cacheStatus_warmWithinTTL() {
        let c = Conversation(
            id: "s", projectName: "/x",
            filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
            turns: [turn(ts: 1000)],
            ttlSeconds: 300
        )
        let now = Date(timeIntervalSince1970: 1100)
        XCTAssertEqual(c.cacheStatus(at: now), .warm)
        XCTAssertEqual(c.cacheTTLRemaining(at: now), 200)
    }

    func test_cacheStatus_coldAfterTTL() {
        let c = Conversation(
            id: "s", projectName: "/x",
            filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
            turns: [turn(ts: 1000)],
            ttlSeconds: 300
        )
        let now = Date(timeIntervalSince1970: 1500)
        XCTAssertEqual(c.cacheStatus(at: now), .cold)
        XCTAssertEqual(c.cacheTTLRemaining(at: now), 0)
    }

    func test_estimatedNextTurnCost_warmUsesCacheReadRate() {
        // Last turn has 1M tokens of context; opus 4.6 cache_read = $0.50/M.
        let c = Conversation(
            id: "s", projectName: "/x",
            filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
            turns: [turn(ts: 1000, input: 0, cacheWrite: 0, cacheRead: 1_000_000, output: 0)],
            ttlSeconds: 300
        )
        let now = Date(timeIntervalSince1970: 1100)  // warm
        XCTAssertEqual(c.estimatedNextTurnCost(at: now), 0.50, accuracy: 0.0001)
    }

    func test_estimatedNextTurnCost_coldUsesCacheWriteRate() {
        // Same 1M context; cold → cache_write $6.25/M on opus 4.6.
        let c = Conversation(
            id: "s", projectName: "/x",
            filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
            turns: [turn(ts: 1000, input: 0, cacheWrite: 0, cacheRead: 1_000_000, output: 0)],
            ttlSeconds: 300
        )
        let now = Date(timeIntervalSince1970: 1500)  // cold
        XCTAssertEqual(c.estimatedNextTurnCost(at: now), 6.25, accuracy: 0.0001)
    }

    func test_estimatedNextTurnCost_noTurns_isZero() {
        let c = Conversation(
            id: "s", projectName: "/x",
            filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
            turns: [], ttlSeconds: 300
        )
        XCTAssertEqual(c.estimatedNextTurnCost(at: Date()), 0.0)
    }
}
