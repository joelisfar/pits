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
}
