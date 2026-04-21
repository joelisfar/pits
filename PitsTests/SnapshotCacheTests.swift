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

    fileprivate func sampleState(version: Int = 1) -> PersistedState {
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
            daysLoaded: 7,
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
}
