import XCTest

final class SmokeTest: XCTestCase {
    func test_hostAppLoads() {
        XCTAssertNotNil(Bundle.main.bundleIdentifier)
    }
}
