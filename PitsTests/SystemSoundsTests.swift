import XCTest
@testable import Pits

final class SystemSoundsTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pits-system-sounds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func touch(_ name: String) throws {
        try Data().write(to: tmp.appendingPathComponent(name))
    }

    func test_enumerate_returnsAiffNamesWithoutExtension_sortedAlphabetically() throws {
        try touch("Pluck.aiff")
        try touch("Boop.aiff")
        try touch("Sonumi.aiff")
        XCTAssertEqual(SystemSounds.enumerate(at: tmp), ["Boop", "Pluck", "Sonumi"])
    }

    func test_enumerate_skipsNonAiffFiles() throws {
        try touch("Boop.aiff")
        try touch("README.txt")
        try touch(".DS_Store")
        XCTAssertEqual(SystemSounds.enumerate(at: tmp), ["Boop"])
    }

    func test_enumerate_returnsEmptyForMissingDirectory() {
        let bogus = URL(fileURLWithPath: "/nonexistent/path-\(UUID().uuidString)")
        XCTAssertEqual(SystemSounds.enumerate(at: bogus), [])
    }
}
