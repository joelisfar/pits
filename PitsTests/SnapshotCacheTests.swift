import XCTest
@testable import Pits

final class SnapshotCacheTests: XCTestCase {
    private var tmpDir: URL!
    private var cacheURL: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pits-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        cacheURL = tmpDir.appendingPathComponent("state.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    fileprivate func sampleState(version: Int = SnapshotCache.currentSchemaVersion) -> PersistedState {
        let url = URL(fileURLWithPath: "/tmp/-proj/abc.jsonl")
        let turn = Turn(
            requestId: "r1", sessionId: "s1",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            model: "claude-opus-4-6",
            inputTokens: 1, cacheCreationTokens: 0,
            cacheReadTokens: 0, outputTokens: 1,
            stopReason: "end_turn", isSubagent: false
        )
        return PersistedState(
            schemaVersion: version,
            savedAt: Date(timeIntervalSince1970: 1_700_000_500),
            fileBySession: ["s1": url],
            offsets: [url: 100],
            parser: PersistedParser(
                turnsByRequestId: ["r1": turn],
                humanTurnsBySession: [:],
                titleBySession: [:]
            )
        )
    }

    func test_loadMissingFile_returnsNil() {
        let cache = SnapshotCache(fileURL: cacheURL)
        XCTAssertNil(cache.load())
    }

    func test_saveNow_thenLoad_roundtrips() throws {
        let cache = SnapshotCache(fileURL: cacheURL)
        let state = sampleState()
        try cache.saveNow(state)
        XCTAssertEqual(cache.load(), state)
    }

    func test_loadMalformedJSON_returnsNil() throws {
        try "not json".write(to: cacheURL, atomically: true, encoding: .utf8)
        let cache = SnapshotCache(fileURL: cacheURL)
        XCTAssertNil(cache.load())
    }

    func test_loadSchemaMismatch_returnsNil() throws {
        let cache = SnapshotCache(fileURL: cacheURL)
        try cache.saveNow(sampleState(version: 999))
        XCTAssertNil(cache.load())
    }

    func test_scheduleSave_debouncesMultipleCalls() throws {
        let cache = SnapshotCache(fileURL: cacheURL, debounceInterval: 0.2)
        let state = sampleState()
        for _ in 0..<5 {
            cache.scheduleSave(state)
        }
        // No write yet (debounce window still open).
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))

        // Wait for the debounce to elapse + a small grace period.
        let exp = expectation(description: "debounce fires")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path))
        XCTAssertEqual(cache.load(), state)
    }

    func test_saveNow_cancelsPendingDebounce() throws {
        let cache = SnapshotCache(fileURL: cacheURL, debounceInterval: 5.0)
        let s1 = sampleState()
        cache.scheduleSave(s1)
        // Immediately call saveNow with a different state.
        let s2SavedAt = Date(timeIntervalSince1970: 1_900_000_000)  // distinct from s1
        let s2 = PersistedState(
            schemaVersion: s1.schemaVersion,
            savedAt: s2SavedAt,
            fileBySession: s1.fileBySession,
            offsets: s1.offsets,
            parser: s1.parser
        )
        try cache.saveNow(s2)

        XCTAssertEqual(cache.load()?.savedAt, s2SavedAt)

        // Wait past a sane window — the cancelled scheduleSave must NOT
        // overwrite the saveNow value with s1.
        let exp = expectation(description: "no late write")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        XCTAssertEqual(cache.load()?.savedAt, s2SavedAt)
    }
}
