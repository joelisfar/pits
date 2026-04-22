import XCTest
@testable import Pits

@MainActor
final class ConversationStoreCacheTests: XCTestCase {
    private var tmpDir: URL!
    private var cacheURL: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pits-store-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        cacheURL = tmpDir.appendingPathComponent("state.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeStore(cache: SnapshotCache? = nil, root: URL? = nil) -> ConversationStore {
        let silentDefaults = UserDefaults(suiteName: "net.farriswheel.Pits.test-\(UUID().uuidString)")!
        let silentSound = SoundManager(defaults: silentDefaults, player: { _ in })
        return ConversationStore(
            rootDirectory: root ?? URL(fileURLWithPath: "/nonexistent"),
            ttlSeconds: 300,
            sound: silentSound,
            cache: cache
        )
    }

    func test_coldInit_isNotLoading_andHasNoConversations() {
        let cache = SnapshotCache(fileURL: cacheURL)
        let store = makeStore(cache: cache)

        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.conversations, [])
    }

    func test_warmInit_populatesConversationsSynchronously() throws {
        // Seed: ingest a line, save the cache, re-init from the same cache.
        // Use a real on-disk file so hydrate-time pruning doesn't drop it.
        let project = tmpDir.appendingPathComponent("-Users-j-Projects-demo")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let url = project.appendingPathComponent("abc.jsonl")
        try Data().write(to: url)

        let setupCache = SnapshotCache(fileURL: cacheURL)
        let setupStore = makeStore(cache: setupCache)
        setupStore.ingestForTesting(
            url: url,
            line: #"{"type":"assistant","sessionId":"s1","requestId":"r1","timestamp":"2026-04-21T10:00:00.000Z","message":{"model":"claude-opus-4-6","stop_reason":"end_turn","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#
        )
        try setupCache.saveNow(setupStore.snapshotStateForTesting())

        let warmCache = SnapshotCache(fileURL: cacheURL)
        let warmStore = makeStore(cache: warmCache)

        XCTAssertEqual(warmStore.conversations.count, 1)
        XCTAssertEqual(warmStore.conversations.first?.id, "s1")
        XCTAssertFalse(warmStore.isLoading)
    }

    func test_warmInit_pruneCachedFileThatNoLongerExists() throws {
        let setupCache = SnapshotCache(fileURL: cacheURL)
        let setupStore = makeStore(cache: setupCache)
        let goneURL = URL(fileURLWithPath: "/definitely/does/not/exist/abc.jsonl")
        setupStore.ingestForTesting(
            url: goneURL,
            line: #"{"type":"assistant","sessionId":"sgone","requestId":"r1","timestamp":"2026-04-21T10:00:00.000Z","message":{"model":"claude-opus-4-6","stop_reason":"end_turn","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#
        )
        try setupCache.saveNow(setupStore.snapshotStateForTesting())

        let warmCache = SnapshotCache(fileURL: cacheURL)
        let warmStore = makeStore(cache: warmCache)

        XCTAssertEqual(warmStore.conversations.count, 0,
                       "Session whose file is gone should be pruned at hydrate")
    }

    func test_warmInit_chimeDoesNotFireForCachedTurns() throws {
        let project = tmpDir.appendingPathComponent("-tmp-a")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("a.jsonl")
        try Data().write(to: file)

        let setupCache = SnapshotCache(fileURL: cacheURL)
        let setupStore = makeStore(cache: setupCache)
        setupStore.ingestForTesting(
            url: file,
            line: #"{"type":"assistant","sessionId":"s","requestId":"r","timestamp":"2026-04-21T10:00:00.000Z","message":{"model":"claude-opus-4-6","stop_reason":"end_turn","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#
        )
        try setupCache.saveNow(setupStore.snapshotStateForTesting())

        let warmCache = SnapshotCache(fileURL: cacheURL)
        let warmStore = makeStore(cache: warmCache)
        var chimes: [String] = []
        warmStore.onNewTurn = { chimes.append($0.requestId) }

        // Hydrate alone (without start()) should not chime.
        XCTAssertTrue(chimes.isEmpty)
    }

    func test_warmInit_reconciliationPicksUpNewBytes() throws {
        // Use a real directory + JSONL so the watcher's discoverFiles can find it.
        let projectsRoot = tmpDir.appendingPathComponent("projects")
        let project = projectsRoot.appendingPathComponent("-tmp-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("s.jsonl")
        let firstLine = #"{"type":"assistant","sessionId":"s1","requestId":"r1","timestamp":"2026-04-21T10:00:00.000Z","message":{"model":"claude-opus-4-6","stop_reason":"end_turn","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#
        try (firstLine + "\n").write(to: file, atomically: true, encoding: .utf8)

        // Cold setup: ingest the first line through the store, save the cache.
        let setupCache = SnapshotCache(fileURL: cacheURL)
        let setupStore = makeStore(cache: setupCache, root: projectsRoot)
        setupStore.ingestForTesting(url: file, line: firstLine)
        // ingestForTesting bypasses the watcher; manually persist with the
        // offset reflecting that the first line was already consumed.
        try setupCache.saveNow(PersistedState(
            schemaVersion: SnapshotCache.currentSchemaVersion,
            savedAt: Date(),
            daysLoaded: 1,
            fileBySession: ["s1": file],
            offsets: [file: UInt64((firstLine + "\n").utf8.count)],
            parser: setupStore.snapshotStateForTesting().parser
        ))

        // Append a second line to the file, simulating Claude writing more turns
        // while the app was closed.
        let secondLine = #"{"type":"assistant","sessionId":"s1","requestId":"r2","timestamp":"2026-04-21T10:05:00.000Z","message":{"model":"claude-opus-4-6","stop_reason":"end_turn","usage":{"input_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":2}}}"#
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: (secondLine + "\n").data(using: .utf8)!)
        try handle.close()

        // Warm launch: load cache, then trigger a reconciliation backfill.
        let warmCache = SnapshotCache(fileURL: cacheURL)
        let warmStore = makeStore(cache: warmCache, root: projectsRoot)

        warmStore.reconcileForTesting()

        XCTAssertEqual(warmStore.conversations.count, 1)
        XCTAssertEqual(warmStore.conversations.first?.turns.count, 2,
                       "Reconciliation should pick up the appended second turn")
    }

    func test_roundtrip_coldIngestSaveReinitMatches() throws {
        let project = tmpDir.appendingPathComponent("-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let url = project.appendingPathComponent("abc.jsonl")
        try Data().write(to: url)

        let cache1 = SnapshotCache(fileURL: cacheURL)
        let store1 = makeStore(cache: cache1)
        store1.ingestForTesting(
            url: url,
            line: #"{"type":"assistant","sessionId":"s1","requestId":"r1","timestamp":"2026-04-21T10:00:00.000Z","message":{"model":"claude-opus-4-6","stop_reason":"end_turn","usage":{"input_tokens":7,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":3}}}"#
        )
        try cache1.saveNow(store1.snapshotStateForTesting())

        let cache2 = SnapshotCache(fileURL: cacheURL)
        let store2 = makeStore(cache: cache2)

        XCTAssertEqual(store2.conversations.map(\.id), store1.conversations.map(\.id))
        XCTAssertEqual(
            store2.conversations.first?.turns.first?.inputTokens,
            store1.conversations.first?.turns.first?.inputTokens
        )
    }
}
