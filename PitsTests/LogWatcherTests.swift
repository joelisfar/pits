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

    func test_backfill_emitsOneBatchPerFile() throws {
        let projectA = tmpDir.appendingPathComponent("-tmp-a")
        let projectB = tmpDir.appendingPathComponent("-tmp-b")
        try FileManager.default.createDirectory(at: projectA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectB, withIntermediateDirectories: true)
        let fileA = projectA.appendingPathComponent("a.jsonl")
        let fileB = projectB.appendingPathComponent("b.jsonl")
        try "a1\na2\na3\n".write(to: fileA, atomically: true, encoding: .utf8)
        try "b1\nb2\n".write(to: fileB, atomically: true, encoding: .utf8)

        var batches: [(URL, [String])] = []
        let watcher = LogWatcher(rootDirectory: tmpDir)
        watcher.onLines = { url, lines in batches.append((url, lines)) }
        watcher.backfill()

        // One batch per file, never per-line.
        XCTAssertEqual(batches.count, 2)
        let byURL = Dictionary(uniqueKeysWithValues: batches.map { ($0.0, $0.1) })
        XCTAssertEqual(byURL[fileA], ["a1", "a2", "a3"])
        XCTAssertEqual(byURL[fileB], ["b1", "b2"])
    }

    func test_backfill_readsAllExistingLines() throws {
        let project = tmpDir.appendingPathComponent("-tmp-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("s.jsonl")
        try "line1\nline2\n".write(to: file, atomically: true, encoding: .utf8)

        var received: [(URL, String)] = []
        let watcher = LogWatcher(rootDirectory: tmpDir)
        watcher.onLines = { url, lines in for l in lines { received.append((url, l)) } }
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
        watcher.onLines = { _, lines in received.append(contentsOf: lines) }
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
        watcher.onLines = { _, lines in received.append(contentsOf: lines) }
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
        watcher.onLines = { _, lines in received.append(contentsOf: lines) }
        watcher.backfill()
        XCTAssertTrue(received.isEmpty)

        let project = tmpDir.appendingPathComponent("-tmp-new")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("new.jsonl")
        try "hello\n".write(to: file, atomically: true, encoding: .utf8)

        watcher.rescan()
        XCTAssertEqual(received, ["hello"])
    }

    func test_liveStart_emitsLineOnAppend() throws {
        let project = tmpDir.appendingPathComponent("-tmp-live")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("live.jsonl")
        try "seed\n".write(to: file, atomically: true, encoding: .utf8)

        let watcher = LogWatcher(rootDirectory: tmpDir)
        let expectation = expectation(description: "received appended line")
        // We'll count both the backfilled "seed" and at least one appended line.
        var received: [String] = []
        let lock = NSLock()
        watcher.onLines = { _, lines in
            lock.lock(); received.append(contentsOf: lines); lock.unlock()
            if lines.contains("fresh") { expectation.fulfill() }
        }
        watcher.backfill()
        watcher.start()

        // Append a new line — FSEvents should deliver within a few seconds.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("fresh\n".utf8))
        try handle.close()

        wait(for: [expectation], timeout: 10.0)
        watcher.stop()

        lock.lock()
        let snapshot = received
        lock.unlock()
        XCTAssertTrue(snapshot.contains("seed"))
        XCTAssertTrue(snapshot.contains("fresh"))
    }
}
