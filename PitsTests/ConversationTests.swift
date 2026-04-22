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
            turns: [turn(ts: 0, input: 1_000_000), turn(ts: 1, output: 1_000_000)]
        )
        XCTAssertEqual(c.totalCost, 30.00, accuracy: 0.0001)
    }

    func test_lastResponseTimestamp_isMostRecentTurn() {
        let c = Conversation(
            id: "s", projectName: "/x",
            filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
            turns: [turn(ts: 100), turn(ts: 50), turn(ts: 200)]
        )
        XCTAssertEqual(c.lastResponseTimestamp, Date(timeIntervalSince1970: 200))
    }

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

    func test_estimatedNextTurnCost_warmUsesCacheReadRate() {
        // Last turn has 1M tokens of context; opus 4.6 cache_read = $0.50/M.
        // Inject 1k cache_creation tokens so observedTTLSeconds = 300s; offset
        // cacheRead by the same amount so the total context stays at exactly 1M.
        let c = Conversation(
            id: "s", projectName: "/x",
            filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
            turns: [turn(ts: 1000, input: 0, cacheWrite: 1_000, cacheRead: 999_000, output: 0)]
        )
        let now = Date(timeIntervalSince1970: 1100)  // 100s elapsed — warm under 5m TTL
        XCTAssertEqual(c.estimatedNextTurnCost(at: now), 0.50, accuracy: 0.0001)
    }

    func test_estimatedNextTurnCost_coldUsesCacheWriteRate() {
        // Same 1M context, with a cache_creation token so observedTTLSeconds = 300s.
        // cold → cache_write_5m $6.25/M on opus 4.6.
        let c = Conversation(
            id: "s", projectName: "/x",
            filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
            turns: [turn(ts: 1000, input: 0, cacheWrite: 1_000, cacheRead: 999_000, output: 0)]
        )
        let now = Date(timeIntervalSince1970: 1500)  // 500s elapsed — past 5m TTL → cold
        XCTAssertEqual(c.estimatedNextTurnCost(at: now), 6.25, accuracy: 0.0001)
    }

    func test_estimatedNextTurnCost_noTurns_isZero() {
        let c = Conversation(
            id: "s", projectName: "/x",
            filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
            turns: []
        )
        XCTAssertEqual(c.estimatedNextTurnCost(at: Date()), 0.0)
    }

    /// The cold-state estimate picks the 1h write rate when the last
    /// cache-writing turn used the 1h slot. Observed data shows cache-writing
    /// turns are pure 5m or pure 1h (no mix across 29k samples).
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

    func test_estimatedNextTurnCost_newStateUses5mRate() {
        // Assistant turn with no cache writes → .new state → conservative 5m rate.
        // 1M tokens context on opus 4.6: cache_write_5m = $6.25/M.
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
        XCTAssertEqual(c.estimatedNextTurnCost(at: Date(timeIntervalSince1970: 1100)), 6.25, accuracy: 0.0001)
    }

    // MARK: - observedTTLSeconds

    func test_observedTTL_nilWhenNoTurns() {
        let c = Conversation(
            id: "s", projectName: "/x",
            filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
            turns: []
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
            turns: [t]
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
            turns: [t]
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
            turns: [t1, t2]
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
            turns: [t1, t2]
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
            turns: [t]
        )
        XCTAssertNil(c.observedTTLSeconds)
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
            ]
        )
        let filtered = c.filtered(toMonth: MonthScope(year: 2026, month: 4), in: la_cal())
        XCTAssertEqual(filtered?.turns.count, 2)
        XCTAssertEqual(filtered?.totalCost ?? 0, 10.00, accuracy: 0.0001)
    }

    func test_filteredToMonth_returnsNilWhenNoTurnsOrHumansInMonth() {
        let c = Conversation(
            id: "s", projectName: "p",
            filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
            turns: [turnAt(year: 2026, month: 3, day: 28)]
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
            ]
        )
        let f = c.filtered(toMonth: MonthScope(year: 2026, month: 4), in: la_cal())!
        XCTAssertEqual(f.subagentTurns.count, 1)
        XCTAssertEqual(f.ownTurns.count, 1)
    }

    func test_filteredToMonth_preservesIdentityFields() {
        let c = Conversation(
            id: "abc", projectName: "demo", title: "My title",
            filePath: URL(fileURLWithPath: "/tmp/x.jsonl"),
            turns: [turnAt(year: 2026, month: 4, day: 5)]
        )
        let f = c.filtered(toMonth: MonthScope(year: 2026, month: 4), in: la_cal())!
        XCTAssertEqual(f.id, "abc")
        XCTAssertEqual(f.projectName, "demo")
        XCTAssertEqual(f.title, "My title")
    }
}
