import XCTest
@testable import Pits

final class JSONLDecoderTests: XCTestCase {
    private func decode(_ line: String) -> JSONLEntry? {
        JSONLDecoder.decode(line: line)
    }

    func test_humanTurn_plainText() {
        let line = #"{"type":"user","sessionId":"s","timestamp":"2026-04-21T10:00:00.000Z","message":{"content":[{"type":"text","text":"hi"}]}}"#
        guard case .human(let h) = decode(line) else { return XCTFail("expected human") }
        XCTAssertEqual(h.sessionId, "s")
    }

    func test_humanTurn_stringContent() {
        let line = #"{"type":"user","sessionId":"s","timestamp":"2026-04-21T10:00:00.000Z","message":{"content":"hi"}}"#
        guard case .human = decode(line) else { return XCTFail("expected human") }
    }

    func test_userToolResultOnly_isNil() {
        let line = #"{"type":"user","sessionId":"s","timestamp":"2026-04-21T10:00:00.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"x"}]}}"#
        XCTAssertNil(decode(line))
    }

    func test_compactSummary_isNil() {
        let line = #"{"type":"user","sessionId":"s","timestamp":"2026-04-21T10:00:00.000Z","isCompactSummary":true,"message":{"content":[{"type":"text","text":"hi"}]}}"#
        XCTAssertNil(decode(line))
    }

    func test_assistantTurn_extractsUsage() {
        let line = #"{"type":"assistant","sessionId":"s","requestId":"req_1","timestamp":"2026-04-21T10:00:01.000Z","message":{"model":"claude-opus-4-6-20251001","stop_reason":"end_turn","usage":{"input_tokens":10,"cache_creation_input_tokens":100,"cache_read_input_tokens":900,"output_tokens":50}}}"#
        guard case .turn(let t) = decode(line) else { return XCTFail("expected turn") }
        XCTAssertEqual(t.requestId, "req_1")
        XCTAssertEqual(t.sessionId, "s")
        XCTAssertEqual(t.model, "claude-opus-4-6")
        XCTAssertEqual(t.inputTokens, 10)
        XCTAssertEqual(t.cacheCreationTokens, 100)
        XCTAssertEqual(t.cacheReadTokens, 900)
        XCTAssertEqual(t.outputTokens, 50)
        XCTAssertEqual(t.stopReason, "end_turn")
        XCTAssertFalse(t.isSubagent)
    }

    func test_assistantTurn_syntheticModelIsNil() {
        let line = #"{"type":"assistant","sessionId":"s","requestId":"req_1","timestamp":"2026-04-21T10:00:01.000Z","message":{"model":"<synthetic>","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#
        XCTAssertNil(decode(line))
    }

    func test_assistantTurn_subagent() {
        let line = #"{"type":"assistant","sessionId":"s","agentId":"a1","requestId":"req_1","timestamp":"2026-04-21T10:00:01.000Z","message":{"model":"claude-sonnet-4-6","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#
        guard case .turn(let t) = decode(line) else { return XCTFail("expected turn") }
        XCTAssertTrue(t.isSubagent)
    }

    func test_otherTypes_areNil() {
        XCTAssertNil(decode(#"{"type":"queue-operation","timestamp":"2026-04-21T10:00:00.000Z"}"#))
        XCTAssertNil(decode(#"{"type":"system","subtype":"compact_boundary","timestamp":"2026-04-21T10:00:00.000Z"}"#))
    }

    func test_malformedJson_isNil() {
        XCTAssertNil(decode("not json"))
        XCTAssertNil(decode(""))
    }
}
