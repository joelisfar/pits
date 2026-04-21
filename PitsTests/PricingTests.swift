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
        XCTAssertEqual(rates?.cacheWrite, 6.25)
        XCTAssertEqual(rates?.cacheRead, 0.50)
        XCTAssertEqual(rates?.output, 25.00)
    }

    func test_rateLookup_unknownModelIsNil() {
        XCTAssertNil(Pricing.rates(for: "claude-unreleased-9-9"))
    }
}
