import XCTest
@testable import Pits

final class LogParserCacheTests: XCTestCase {
    private func makeTurn(id: String, session: String, ts: TimeInterval = 1_700_000_000) -> Turn {
        Turn(
            requestId: id, sessionId: session,
            timestamp: Date(timeIntervalSince1970: ts),
            model: "claude-opus-4-6",
            inputTokens: 1, cacheCreationTokens: 0,
            cacheReadTokens: 0, outputTokens: 1,
            stopReason: "end_turn", isSubagent: false
        )
    }

    func test_initWithSeed_exposesSeedData() {
        let t = makeTurn(id: "r1", session: "s1")
        let h = HumanTurn(
            sessionId: "s1",
            timestamp: Date(timeIntervalSince1970: 1_700_000_001),
            isSubagent: false, agentId: nil
        )
        let seed = PersistedParser(
            turnsByRequestId: ["r1": t],
            humanTurnsBySession: ["s1": [h]],
            titleBySession: ["s1": "Hello"]
        )
        let parser = LogParser(seed: seed)

        XCTAssertEqual(parser.turns(sessionId: "s1"), [t])
        XCTAssertEqual(parser.humanTurns(sessionId: "s1"), [h])
        XCTAssertEqual(parser.title(sessionId: "s1"), "Hello")
        XCTAssertEqual(parser.sessionIds(), ["s1"])
    }

    func test_snapshot_roundtripsThroughInitSeed() {
        let original = LogParser()
        original.ingest(line: #"{"type":"assistant","sessionId":"s1","requestId":"r1","timestamp":"2026-04-21T10:00:00.000Z","message":{"model":"claude-opus-4-6","stop_reason":"end_turn","usage":{"input_tokens":3,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":4}}}"#)
        original.ingest(line: #"{"type":"ai-title","sessionId":"s1","aiTitle":"Cool"}"#)

        let revived = LogParser(seed: original.snapshot())

        XCTAssertEqual(revived.turns(sessionId: "s1"), original.turns(sessionId: "s1"))
        XCTAssertEqual(revived.title(sessionId: "s1"), original.title(sessionId: "s1"))
        XCTAssertEqual(revived.sessionIds(), original.sessionIds())
    }

    func test_initWithoutSeed_isEmpty() {
        let parser = LogParser(seed: nil)
        XCTAssertEqual(parser.sessionIds(), [])
    }
}
