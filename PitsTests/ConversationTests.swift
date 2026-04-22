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
        XCTAssertEqual(Conversation.projectName(from: url), "pits")
    }

    func test_projectName_preservesLiteralDashesWhenDirExists() throws {
        // Create a real directory whose leaf name contains literal dashes,
        // then verify the encoded form resolves back to that leaf rather
        // than the last dash-separated word.
        let unique = String(Int(Date().timeIntervalSince1970 * 1000))
        let leafName = "one-two-three-\(unique)"
        let real = URL(fileURLWithPath: "/tmp").appendingPathComponent(leafName, isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: real) }

        let encoded = "-" + real.path.replacingOccurrences(of: "/", with: "-")
        let jsonl = URL(fileURLWithPath: "/anywhere/.claude/projects/\(encoded)/abc.jsonl")

        XCTAssertEqual(Conversation.projectName(from: jsonl), leafName)
    }

    func test_projectName_fallsBackToNaiveLeafWhenPathMissing() {
        // A completely fictitious path that can't exist on disk should still
        // return a sensible leaf (the naive last-segment behavior) rather
        // than crashing or returning empty.
        let url = URL(fileURLWithPath: "/x/.claude/projects/-nope-not-a-real-path-xyz/abc.jsonl")
        XCTAssertEqual(Conversation.projectName(from: url), "xyz")
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

    /// When the last turn used a mix of 5m and 1h cache writes, the cold
    /// estimate weights the write-rate by that mix instead of using a flat 5m.
    func test_estimatedNextTurnCost_coldWeightsWriteRateByLastTurnMix() {
        // 1M context: 200k cache_read, 800k cache_creation (200k 5m + 600k 1h).
        // On opus 4.7: 5m = $6.25/M, 1h = $10.00/M. Write fraction = 75% 1h.
        // Effective write rate = 0.25*6.25 + 0.75*10 = 9.0625
        // 1M * 9.0625 / 1M = $9.0625
        let t = Turn(
            requestId: "r", sessionId: "s",
            timestamp: Date(timeIntervalSince1970: 1000),
            model: "claude-opus-4-7",
            inputTokens: 0,
            cacheCreation5mTokens: 200_000,
            cacheCreation1hTokens: 600_000,
            cacheReadTokens: 200_000,
            outputTokens: 1,
            stopReason: "end_turn",
            isSubagent: false
        )
        let c = Conversation(
            id: "s", projectName: "/x",
            filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
            turns: [t], ttlSeconds: 300
        )
        let now = Date(timeIntervalSince1970: 1500)  // cold (TTL 300, elapsed 500)
        XCTAssertEqual(c.estimatedNextTurnCost(at: now), 9.0625, accuracy: 0.0001)
    }

    // MARK: - filtered(toMonth:)

    private func la_cal() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    private func turnAt(year: Int, month: Int, day: Int,
                        requestId: String = UUID().uuidString,
                        isSubagent: Bool = false) -> Turn {
        let ts = la_cal().date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
        return Turn(
            requestId: requestId, sessionId: "s",
            timestamp: ts, model: "claude-opus-4-6",
            inputTokens: 1_000_000, cacheCreationTokens: 0,
            cacheReadTokens: 0, outputTokens: 0,
            stopReason: "end_turn", isSubagent: isSubagent
        )
    }

    func test_filteredToMonth_dropsTurnsOutsideMonth() {
        let c = Conversation(
            id: "s", projectName: "p",
            filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
            turns: [
                turnAt(year: 2026, month: 3, day: 28),
                turnAt(year: 2026, month: 4, day: 2),
                turnAt(year: 2026, month: 4, day: 19),
            ],
            ttlSeconds: 300
        )
        let filtered = c.filtered(toMonth: MonthScope(year: 2026, month: 4), in: la_cal())
        XCTAssertEqual(filtered?.turns.count, 2)
        XCTAssertEqual(filtered?.totalCost ?? 0, 10.00, accuracy: 0.0001)
    }

    func test_filteredToMonth_returnsNilWhenNoTurnsOrHumansInMonth() {
        let c = Conversation(
            id: "s", projectName: "p",
            filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
            turns: [turnAt(year: 2026, month: 3, day: 28)],
            ttlSeconds: 300
        )
        XCTAssertNil(c.filtered(toMonth: MonthScope(year: 2026, month: 4), in: la_cal()))
    }

    func test_filteredToMonth_subagentTurnsRespectFilter() {
        let c = Conversation(
            id: "s", projectName: "p",
            filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
            turns: [
                turnAt(year: 2026, month: 4, day: 5, isSubagent: true),
                turnAt(year: 2026, month: 3, day: 28, isSubagent: true),
                turnAt(year: 2026, month: 4, day: 6, isSubagent: false),
            ],
            ttlSeconds: 300
        )
        let f = c.filtered(toMonth: MonthScope(year: 2026, month: 4), in: la_cal())!
        XCTAssertEqual(f.subagentTurns.count, 1)
        XCTAssertEqual(f.ownTurns.count, 1)
    }

    func test_filteredToMonth_preservesIdentityFields() {
        let c = Conversation(
            id: "abc", projectName: "demo", title: "My title",
            filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
            turns: [turnAt(year: 2026, month: 4, day: 5)],
            ttlSeconds: 300
        )
        let f = c.filtered(toMonth: MonthScope(year: 2026, month: 4), in: la_cal())!
        XCTAssertEqual(f.id, "abc")
        XCTAssertEqual(f.projectName, "demo")
        XCTAssertEqual(f.title, "My title")
        XCTAssertEqual(f.ttlSeconds, 300)
    }
}
