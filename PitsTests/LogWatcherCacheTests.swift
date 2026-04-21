import XCTest
@testable import Pits

final class LogWatcherCacheTests: XCTestCase {
    private var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pits-watcher-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func test_initialOffsets_skipsPriorBytes() throws {
        let project = tmpDir.appendingPathComponent("-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("s.jsonl")
        try "first\nsecond\nthird\n".write(to: file, atomically: true, encoding: .utf8)

        // Byte offset of "third\n" is 13 ("first\nsecond\n".utf8.count == 13).
        let watcher = LogWatcher(rootDirectory: tmpDir, initialOffsets: [file: 13])
        var received: [String] = []
        watcher.onLines = { _, lines in received.append(contentsOf: lines) }
        watcher.backfill()

        XCTAssertEqual(received, ["third"])
    }

    func test_currentOffsetsForPersistence_pointsBeforeTrailingPartial() throws {
        let project = tmpDir.appendingPathComponent("-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("s.jsonl")
        // No terminating newline → "incomplete" is a partial.
        try "complete\nincomplete".write(to: file, atomically: true, encoding: .utf8)

        let watcher = LogWatcher(rootDirectory: tmpDir)
        watcher.onLines = { _, _ in }
        watcher.backfill()

        let persisted = watcher.currentOffsetsForPersistence()
        // "complete\n".utf8.count == 9 — offset should point right after the newline.
        XCTAssertEqual(persisted[file], 9)
    }

    func test_currentOffsetsForPersistence_equalsRawOffset_whenNoPartial() throws {
        let project = tmpDir.appendingPathComponent("-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("s.jsonl")
        try "a\nb\n".write(to: file, atomically: true, encoding: .utf8)

        let watcher = LogWatcher(rootDirectory: tmpDir)
        watcher.onLines = { _, _ in }
        watcher.backfill()

        let persisted = watcher.currentOffsetsForPersistence()
        XCTAssertEqual(persisted[file], 4)  // "a\nb\n" is 4 bytes, no partial
    }
}
