import XCTest
@testable import Pits

final class OpenSessionsWatcherTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pits-open-sessions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func writeSessionFile(pid: Int, sessionId: String) throws {
        let url = tmpDir.appendingPathComponent("\(pid).json")
        let json = """
        {"pid":\(pid),"sessionId":"\(sessionId)","cwd":"/tmp","startedAt":1,"version":"2.1.116","kind":"interactive","entrypoint":"claude-vscode"}
        """
        try json.data(using: .utf8)!.write(to: url)
    }

    func test_emptyDirectory_returnsEmptySet() {
        let w = OpenSessionsWatcher(sessionsDirectory: tmpDir)
        XCTAssertEqual(w.openSessionIds(), [])
    }

    func test_missingDirectory_returnsEmptySet() {
        let missing = tmpDir.appendingPathComponent("does-not-exist")
        let w = OpenSessionsWatcher(sessionsDirectory: missing)
        XCTAssertEqual(w.openSessionIds(), [])
    }

    func test_readsSingleSessionId() throws {
        try writeSessionFile(pid: 1001, sessionId: "abc-123")
        let w = OpenSessionsWatcher(sessionsDirectory: tmpDir)
        XCTAssertEqual(w.openSessionIds(), ["abc-123"])
    }

    func test_readsMultipleSessionIds() throws {
        try writeSessionFile(pid: 1001, sessionId: "a")
        try writeSessionFile(pid: 1002, sessionId: "b")
        try writeSessionFile(pid: 1003, sessionId: "c")
        let w = OpenSessionsWatcher(sessionsDirectory: tmpDir)
        XCTAssertEqual(w.openSessionIds(), ["a", "b", "c"])
    }

    func test_ignoresNonJSONFiles() throws {
        try writeSessionFile(pid: 1001, sessionId: "a")
        try "not json".data(using: .utf8)!
            .write(to: tmpDir.appendingPathComponent("readme.txt"))
        try Data().write(to: tmpDir.appendingPathComponent(".DS_Store"))
        let w = OpenSessionsWatcher(sessionsDirectory: tmpDir)
        XCTAssertEqual(w.openSessionIds(), ["a"])
    }

    func test_skipsCorruptJSON_returnsOthers() throws {
        try writeSessionFile(pid: 1001, sessionId: "good")
        try "{not json".data(using: .utf8)!
            .write(to: tmpDir.appendingPathComponent("666.json"))
        let w = OpenSessionsWatcher(sessionsDirectory: tmpDir)
        XCTAssertEqual(w.openSessionIds(), ["good"])
    }

    func test_skipsJSONWithoutSessionIdField() throws {
        try writeSessionFile(pid: 1001, sessionId: "good")
        try #"{"pid":2222,"cwd":"/x"}"#.data(using: .utf8)!
            .write(to: tmpDir.appendingPathComponent("2222.json"))
        let w = OpenSessionsWatcher(sessionsDirectory: tmpDir)
        XCTAssertEqual(w.openSessionIds(), ["good"])
    }

    func test_picksUpNewFilesOnNextScan() throws {
        let w = OpenSessionsWatcher(sessionsDirectory: tmpDir)
        XCTAssertEqual(w.openSessionIds(), [])

        try writeSessionFile(pid: 1001, sessionId: "new-one")
        XCTAssertEqual(w.openSessionIds(), ["new-one"])
    }

    func test_dropsRemovedFilesOnNextScan() throws {
        try writeSessionFile(pid: 1001, sessionId: "will-be-removed")
        let w = OpenSessionsWatcher(sessionsDirectory: tmpDir)
        XCTAssertEqual(w.openSessionIds(), ["will-be-removed"])

        try FileManager.default.removeItem(
            at: tmpDir.appendingPathComponent("1001.json")
        )
        XCTAssertEqual(w.openSessionIds(), [])
    }
}
