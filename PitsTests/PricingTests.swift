import XCTest
@testable import Pits

final class PricingTests: XCTestCase {
    func test_normalize_stripsDateSuffix() {
        XCTAssertEqual(Pricing.normalizeModel("claude-haiku-4-5-20251001"), "claude-haiku-4-5")
        XCTAssertEqual(Pricing.normalizeModel("claude-opus-4-6"), "claude-opus-4-6")
    }

    func test_normalize_returnsNilForSynthetic() {
        XCTAssertNil(Pricing.normalizeModel("<synthetic>"))
    }

    func test_rateLookup_knownModel() {
        let rates = Pricing.rates(for: "claude-opus-4-6")
        XCTAssertNotNil(rates)
        XCTAssertEqual(rates?.base, 5.00)
        XCTAssertEqual(rates?.cacheWrite5m, 6.25)
        XCTAssertEqual(rates?.cacheWrite1h, 10.00)
        XCTAssertEqual(rates?.cacheRead, 0.50)
        XCTAssertEqual(rates?.output, 25.00)
    }

    func test_rateLookup_unknownModelIsNil() {
        XCTAssertNil(Pricing.rates(for: "claude-unreleased-9-9"))
    }

    func test_rateLookup_opus47() {
        // Opus 4.7 was missing from the table; turns were silently $0.
        let rates = Pricing.rates(for: "claude-opus-4-7")
        XCTAssertNotNil(rates)
        XCTAssertEqual(rates?.base, 5.00)
        XCTAssertEqual(rates?.cacheWrite5m, 6.25)
        XCTAssertEqual(rates?.cacheWrite1h, 10.00)
        XCTAssertEqual(rates?.cacheRead, 0.50)
        XCTAssertEqual(rates?.output, 25.00)
    }

    func test_rateLookup_haiku45_correctedFromHaiku35Values() {
        // Haiku 4.5 was incorrectly priced at Haiku 3.5 rates.
        let rates = Pricing.rates(for: "claude-haiku-4-5")
        XCTAssertNotNil(rates)
        XCTAssertEqual(rates?.base, 1.00)
        XCTAssertEqual(rates?.cacheWrite5m, 1.25)
        XCTAssertEqual(rates?.cacheWrite1h, 2.00)
        XCTAssertEqual(rates?.cacheRead, 0.10)
        XCTAssertEqual(rates?.output, 5.00)
    }

    func test_rateLookup_haiku35_unchanged() {
        let rates = Pricing.rates(for: "claude-haiku-3-5")
        XCTAssertEqual(rates?.base, 0.80)
        XCTAssertEqual(rates?.output, 4.00)
    }

    func test_cacheWrite1h_isTwiceBase_forAllModels() {
        // Anthropic's documented multiplier: 1h cache = 2x input, 5m cache = 1.25x input.
        for (name, r) in Pricing.table {
            XCTAssertEqual(r.cacheWrite1h, r.base * 2.0, accuracy: 0.0001, "1h rate for \(name)")
            XCTAssertEqual(r.cacheWrite5m, r.base * 1.25, accuracy: 0.0001, "5m rate for \(name)")
            XCTAssertEqual(r.cacheRead, r.base * 0.10, accuracy: 0.0001, "read rate for \(name)")
        }
    }
}
