import XCTest
@testable import Pits

final class TurnTests: XCTestCase {
    private func makeTurn(
        input: Int = 0,
        cacheWrite: Int = 0,
        cacheRead: Int = 0,
        output: Int = 0,
        model: String = "claude-opus-4-6"
    ) -> Turn {
        Turn(
            requestId: "req_1",
            sessionId: "s",
            timestamp: Date(timeIntervalSince1970: 0),
            model: model,
            inputTokens: input,
            cacheCreationTokens: cacheWrite,
            cacheReadTokens: cacheRead,
            outputTokens: output,
            stopReason: nil,
            isSubagent: false
        )
    }

    func test_cost_opus46_inputOnly() {
        let t = makeTurn(input: 1_000_000)
        XCTAssertEqual(t.inputCost, 5.00, accuracy: 0.0001)
        XCTAssertEqual(t.totalCost, 5.00, accuracy: 0.0001)
    }

    func test_cost_opus46_allCategories() {
        let t = makeTurn(input: 1_000_000, cacheWrite: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        XCTAssertEqual(t.inputCost, 5.00, accuracy: 0.0001)
        XCTAssertEqual(t.cacheWriteCost, 6.25, accuracy: 0.0001)
        XCTAssertEqual(t.cacheReadCost, 0.50, accuracy: 0.0001)
        XCTAssertEqual(t.outputCost, 25.00, accuracy: 0.0001)
        XCTAssertEqual(t.totalCost, 36.75, accuracy: 0.0001)
    }

    func test_cost_unknownModel_isZero() {
        let t = makeTurn(input: 1_000_000, model: "unknown")
        XCTAssertEqual(t.totalCost, 0.0)
    }

    func test_contextSize_sumsCache() {
        let t = makeTurn(cacheWrite: 1000, cacheRead: 9000)
        XCTAssertEqual(t.contextSize, 10_000)
    }

    /// 5m and 1h cache writes are billed at different rates: 1.25× and 2× base.
    /// On opus 4.7 (base $5/M), a turn with 1M of 5m + 1M of 1h cache writes
    /// should cost 6.25 + 10.00 = $16.25 just for the cache_write portion.
    func test_cost_splitsCacheWriteByTier_opus47() {
        let t = Turn(
            requestId: "r", sessionId: "s",
            timestamp: Date(timeIntervalSince1970: 0),
            model: "claude-opus-4-7",
            inputTokens: 0,
            cacheCreation5mTokens: 1_000_000,
            cacheCreation1hTokens: 1_000_000,
            cacheReadTokens: 0,
            outputTokens: 0,
            stopReason: "end_turn",
            isSubagent: false
        )
        XCTAssertEqual(t.cacheWriteCost, 16.25, accuracy: 0.0001)
        XCTAssertEqual(t.totalCost, 16.25, accuracy: 0.0001)
    }

    /// `cacheCreationTokens` is the sum of the 5m and 1h fields.
    func test_cacheCreationTokens_isSumOf5mAnd1h() {
        let t = Turn(
            requestId: "r", sessionId: "s",
            timestamp: Date(timeIntervalSince1970: 0),
            model: "claude-opus-4-6",
            inputTokens: 0,
            cacheCreation5mTokens: 100,
            cacheCreation1hTokens: 250,
            cacheReadTokens: 0,
            outputTokens: 0,
            stopReason: nil,
            isSubagent: false
        )
        XCTAssertEqual(t.cacheCreationTokens, 350)
    }
}
