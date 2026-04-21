import XCTest
@testable import Pits

final class PersistedStateTests: XCTestCase {
    fileprivate func iso8601Encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    fileprivate func iso8601Decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func test_turn_codableRoundtrip() throws {
        let turn = Turn(
            requestId: "r1",
            sessionId: "s1",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            model: "claude-opus-4-6",
            inputTokens: 10,
            cacheCreationTokens: 20,
            cacheReadTokens: 30,
            outputTokens: 40,
            stopReason: "end_turn",
            isSubagent: false
        )
        let data = try iso8601Encoder().encode(turn)
        let decoded = try iso8601Decoder().decode(Turn.self, from: data)
        XCTAssertEqual(decoded, turn)
    }

    func test_humanTurn_codableRoundtrip() throws {
        let h = HumanTurn(
            sessionId: "s1",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            isSubagent: true,
            agentId: "agent-x"
        )
        let data = try iso8601Encoder().encode(h)
        let decoded = try iso8601Decoder().decode(HumanTurn.self, from: data)
        XCTAssertEqual(decoded, h)
    }

    func test_sessionTitle_codableRoundtrip() throws {
        let t = SessionTitle(sessionId: "s1", title: "Test Title")
        let data = try iso8601Encoder().encode(t)
        let decoded = try iso8601Decoder().decode(SessionTitle.self, from: data)
        XCTAssertEqual(decoded.sessionId, t.sessionId)
        XCTAssertEqual(decoded.title, t.title)
    }
}
