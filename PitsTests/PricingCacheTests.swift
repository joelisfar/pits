import XCTest
@testable import Pits

final class PricingCacheTests: XCTestCase {
    private var tmpURL: URL!

    override func setUpWithError() throws {
        tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pits-pricing-\(UUID().uuidString).json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpURL)
    }

    func test_saveThenLoad_roundtrips() throws {
        let rates = ["claude-opus-4-7": Pricing.Rates(
            base: 5.0, cacheWrite5m: 6.25, cacheWrite1h: 10.0,
            cacheRead: 0.5, output: 25.0
        )]
        try PricingCache.save(rates: rates, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
                              to: tmpURL)
        let loaded = PricingCache.load(from: tmpURL)
        XCTAssertEqual(loaded?.rates["claude-opus-4-7"]?.base, 5.0)
        XCTAssertEqual(loaded?.fetchedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func test_load_returnsNilForMissingFile() {
        XCTAssertNil(PricingCache.load(from: tmpURL))
    }

    func test_load_returnsNilForCorruptFile() throws {
        try "not json".write(to: tmpURL, atomically: true, encoding: .utf8)
        XCTAssertNil(PricingCache.load(from: tmpURL))
    }
}
