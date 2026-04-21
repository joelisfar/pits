import XCTest
@testable import Pits

final class LogWatcherTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pits-watcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func test_backfill_readsAllExistingLines() throws {
        let project = tmpDir.appendingPathComponent("-tmp-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("s.jsonl")
        try "line1\nline2\n".write(to: file, atomically: true, encoding: .utf8)

        var received: [(URL, String)] = []
        let watcher = LogWatcher(rootDirectory: tmpDir)
        watcher.onLine = { url, line in received.append((url, line)) }
        watcher.backfill()

        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received.map(\.1), ["line1", "line2"])
        XCTAssertEqual(received.first?.0, file)
    }

    func test_onAppend_onlyReadsNewBytes() throws {
        let project = tmpDir.appendingPathComponent("-tmp-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("s.jsonl")
        try "line1\n".write(to: file, atomically: true, encoding: .utf8)

        var received: [String] = []
        let watcher = LogWatcher(rootDirectory: tmpDir)
        watcher.onLine = { _, line in received.append(line) }
        watcher.backfill()
        XCTAssertEqual(received, ["line1"])

        // Append using FileHandle so we don't replace the inode.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("line2\nline3\n".utf8))
        try handle.close()

        watcher.rescan()
        XCTAssertEqual(received, ["line1", "line2", "line3"])
    }

    func test_partialLine_bufferedUntilNewline() throws {
        let project = tmpDir.appendingPathComponent("-tmp-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("s.jsonl")
        try "complete1\npart".write(to: file, atomically: true, encoding: .utf8)

        var received: [String] = []
        let watcher = LogWatcher(rootDirectory: tmpDir)
        watcher.onLine = { _, line in received.append(line) }
        watcher.backfill()
        XCTAssertEqual(received, ["complete1"])

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("ial\n".utf8))
        try handle.close()

        watcher.rescan()
        XCTAssertEqual(received, ["complete1", "partial"])
    }

    func test_newFile_discoveredOnRescan() throws {
        let watcher = LogWatcher(rootDirectory: tmpDir)
        var received: [String] = []
        watcher.onLine = { _, line in received.append(line) }
        watcher.backfill()
        XCTAssertTrue(received.isEmpty)

        let project = tmpDir.appendingPathComponent("-tmp-new")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("new.jsonl")
        try "hello\n".write(to: file, atomically: true, encoding: .utf8)

        watcher.rescan()
        XCTAssertEqual(received, ["hello"])
    }
}
