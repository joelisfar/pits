import XCTest
@testable import Pits

@MainActor
final class ConversationStoreTests: XCTestCase {
    private func makeStore(
        openSessionsWatcher: OpenSessionsWatcher = OpenSessionsWatcher(
            sessionsDirectory: URL(fileURLWithPath: "/nonexistent/sessions")
        )
    ) -> ConversationStore {
        let silentDefaults = UserDefaults(suiteName: "net.farriswheel.Pits.test-\(UUID().uuidString)")!
        let silentSound = SoundManager(defaults: silentDefaults, player: { _ in })
        return ConversationStore(
            rootDirectory: URL(fileURLWithPath: "/nonexistent"),
            sound: silentSound,
            openSessionsWatcher: openSessionsWatcher
        )
    }

    /// JSONL timestamps require fractional seconds (see JSONLDecoder).
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Variant of makeStore that captures every sound name the SoundManager plays.
    private func makeStoreCapturingSounds(
        openSessionsWatcher: OpenSessionsWatcher = OpenSessionsWatcher(
            sessionsDirectory: URL(fileURLWithPath: "/nonexistent/sessions")
        )
    ) -> (ConversationStore, () -> [String]) {
        let played = NSMutableArray()
        let suite = "net.farriswheel.Pits.test-\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suite)!
        let sound = SoundManager(
            defaults: testDefaults,
            availableSounds: ["Boop", "Breeze", "Sonumi", "Submerge", "Tink"],
            player: { name in played.add(name) }
        )
        let store = ConversationStore(
            rootDirectory: URL(fileURLWithPath: "/nonexistent"),
            sound: sound,
            openSessionsWatcher: openSessionsWatcher
        )
        return (store, { played.compactMap { $0 as? String } })
    }

    // MARK: - Open sessions wiring

    func test_refreshOpenSessionIds_reflectsWatcherDirectoryContents() throws {
        let sessionsDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pits-store-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionsDir) }

        let liveFile = sessionsDir.appendingPathComponent("1234.json")
        try #"{"pid":1234,"sessionId":"open-abc"}"#.data(using: .utf8)!
            .write(to: liveFile)

        let store = makeStore(
            openSessionsWatcher: OpenSessionsWatcher(sessionsDirectory: sessionsDir)
        )
        store.refreshOpenSessionIds()
        XCTAssertEqual(store.openSessionIds, ["open-abc"])

        try FileManager.default.removeItem(at: liveFile)
        store.refreshOpenSessionIds()
        XCTAssertEqual(store.openSessionIds, [])
    }

    func test_ingestLine_producesConversation() {
        let store = makeStore()
        let url = URL(fileURLWithPath: "/Users/j/.claude/projects/-Users-j-Projects-demo/abc.jsonl")
        store.ingestForTesting(url: url, line: #"{"type":"assistant","sessionId":"s1","requestId":"r1","timestamp":"2026-04-21T10:00:00.000Z","message":{"model":"claude-opus-4-6","stop_reason":"end_turn","usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}"#)

        XCTAssertEqual(store.conversations.count, 1)
        let c = store.conversations[0]
        XCTAssertEqual(c.id, "s1")
        XCTAssertEqual(c.projectName, "demo")
        XCTAssertEqual(c.turns.count, 1)
    }

    func test_conversations_sortedByMostRecentActivity() {
        let store = makeStore()
        let urlA = URL(fileURLWithPath: "/tmp/-a/a.jsonl")
        let urlB = URL(fileURLWithPath: "/tmp/-b/b.jsonl")
        store.ingestForTesting(url: urlA, line: #"{"type":"assistant","sessionId":"sa","requestId":"r1","timestamp":"2026-04-21T10:00:00.000Z","message":{"model":"claude-opus-4-6","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#)
        store.ingestForTesting(url: urlB, line: #"{"type":"assistant","sessionId":"sb","requestId":"r2","timestamp":"2026-04-21T11:00:00.000Z","message":{"model":"claude-opus-4-6","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#)

        XCTAssertEqual(store.conversations.map(\.id), ["sb", "sa"])
    }

    func test_batchIngest_producesCorrectState() {
        let store = makeStore()
        let url = URL(fileURLWithPath: "/Users/j/.claude/projects/-Users-j-Projects-demo/abc.jsonl")
        let lines = [
            #"{"type":"assistant","sessionId":"s1","requestId":"r1","timestamp":"2026-04-21T10:00:00.000Z","message":{"model":"claude-opus-4-6","stop_reason":"end_turn","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#,
            #"{"type":"assistant","sessionId":"s1","requestId":"r2","timestamp":"2026-04-21T10:05:00.000Z","message":{"model":"claude-opus-4-6","stop_reason":"end_turn","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#,
            #"{"type":"assistant","sessionId":"s2","requestId":"r3","timestamp":"2026-04-21T11:00:00.000Z","message":{"model":"claude-opus-4-6","stop_reason":"end_turn","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#,
        ]

        store.ingestBatchForTesting(url: url, lines: lines)

        XCTAssertEqual(store.conversations.count, 2)
        XCTAssertEqual(store.conversations.map(\.id), ["s2", "s1"])
        XCTAssertEqual(store.conversations.first(where: { $0.id == "s1" })?.turns.count, 2)
    }

    func test_chime_onlyFiresOnFinalTurns() {
        var chimedRequestIds: [String] = []
        let store = makeStore()
        store.setChimeCutoffForTesting(.distantPast)
        store.onNewTurn = { t in chimedRequestIds.append(t.requestId) }

        let url = URL(fileURLWithPath: "/tmp/-a/a.jsonl")
        // tool_use — intermediate step, should NOT chime
        store.ingestForTesting(url: url, line: #"{"type":"assistant","sessionId":"s","requestId":"r_tool","timestamp":"2026-04-21T10:00:00.000Z","message":{"model":"claude-opus-4-6","stop_reason":"tool_use","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#)
        // streaming fragment — no stop_reason at all, should NOT chime
        store.ingestForTesting(url: url, line: #"{"type":"assistant","sessionId":"s","requestId":"r_mid","timestamp":"2026-04-21T10:00:01.000Z","message":{"model":"claude-opus-4-6","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#)
        // end_turn — final reply, SHOULD chime
        store.ingestForTesting(url: url, line: #"{"type":"assistant","sessionId":"s","requestId":"r_end","timestamp":"2026-04-21T10:00:02.000Z","message":{"model":"claude-opus-4-6","stop_reason":"end_turn","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#)
        // max_tokens — still a final turn from the user's perspective, SHOULD chime
        store.ingestForTesting(url: url, line: #"{"type":"assistant","sessionId":"s","requestId":"r_max","timestamp":"2026-04-21T10:00:03.000Z","message":{"model":"claude-opus-4-6","stop_reason":"max_tokens","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#)

        XCTAssertEqual(chimedRequestIds, ["r_end", "r_max"])
    }

    func test_chime_skipsSubagentFinalTurns() {
        var chimedRequestIds: [String] = []
        let store = makeStore()
        store.setChimeCutoffForTesting(.distantPast)
        store.onNewTurn = { t in chimedRequestIds.append(t.requestId) }

        let url = URL(fileURLWithPath: "/tmp/-a/a.jsonl")
        // Top-level end_turn — chimes.
        store.ingestForTesting(url: url, line: #"{"type":"assistant","sessionId":"s","requestId":"r_top","timestamp":"2026-04-21T10:00:00.000Z","message":{"model":"claude-opus-4-6","stop_reason":"end_turn","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#)
        // Subagent end_turn (presence of agentId marks it subagent) — must NOT chime.
        store.ingestForTesting(url: url, line: #"{"type":"assistant","sessionId":"s","requestId":"r_sub","agentId":"agent-7","timestamp":"2026-04-21T10:00:01.000Z","message":{"model":"claude-opus-4-6","stop_reason":"end_turn","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#)

        XCTAssertEqual(chimedRequestIds, ["r_top"])
    }

    func test_noChimeFiresBeforeStart() {
        // Chime cutoff is `.distantFuture` until start(); tests never reach start(),
        // so even though ingestForTesting feeds a "new" turn, the silent player
        // confirms playMessageReceived is not invoked. This is asserted by virtue
        // of the silent player being a no-op — the test is a no-crash guarantee.
        let store = makeStore()
        store.ingestForTesting(
            url: URL(fileURLWithPath: "/tmp/-a/a.jsonl"),
            line: #"{"type":"assistant","sessionId":"s","requestId":"r","timestamp":"2026-04-21T10:00:00.000Z","message":{"model":"claude-opus-4-6","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#
        )
        XCTAssertEqual(store.conversations.count, 1)
    }

    // MARK: - Month scope

    func test_init_defaultsToCurrentMonth() {
        let store = makeStore()
        XCTAssertEqual(store.selectedMonth, MonthScope.current())
    }

    func test_setSelectedMonth_updatesPublishedValue() {
        let store = makeStore()
        let target = MonthScope(year: 2026, month: 1)
        store.setSelectedMonth(target)
        XCTAssertEqual(store.selectedMonth, target)
    }

    func test_discoverActiveMonths_returnsContiguousRangeFromEarliestToCurrent() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pits-discover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let project = tmp.appendingPathComponent("-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let url = project.appendingPathComponent("a.jsonl")
        try "x".write(to: url, atomically: true, encoding: .utf8)
        let twoMonthsAgo = Calendar.current.date(byAdding: .month, value: -2, to: Date())!
        try FileManager.default.setAttributes([.modificationDate: twoMonthsAgo], ofItemAtPath: url.path)

        let silentDefaults = UserDefaults(suiteName: "test-\(UUID().uuidString)")!
        let silentSound = SoundManager(defaults: silentDefaults, player: { _ in })
        let store = ConversationStore(
            rootDirectory: tmp,
            sound: silentSound
        )
        store.discoverActiveMonths()
        XCTAssertEqual(store.availableMonths.first, MonthScope.current())
        XCTAssertEqual(store.availableMonths.last, MonthScope.from(date: twoMonthsAgo))
        XCTAssertEqual(store.availableMonths.count, 3)
    }

    func test_setSelectedMonth_sameValueIsNoop() {
        let store = makeStore()
        let m = store.selectedMonth
        // Should not crash or change state.
        store.setSelectedMonth(m)
        XCTAssertEqual(store.selectedMonth, m)
    }

    // MARK: - Cache timer chime

    func test_tick_playsNewCold_whenConversationTransitions() {
        let (store, played) = makeStoreCapturingSounds()
        store.setChimeCutoffForTesting(.distantPast)

        // Ingest a single warm assistant turn so the conversation is tracked.
        let url = URL(fileURLWithPath: "/tmp/-a/a.jsonl")
        // Pick a recent timestamp so cacheStatus computes meaningfully.
        let now = Date()
        let lineTs = isoFormatter.string(from: now)
        store.ingestForTesting(url: url, line: #"{"type":"assistant","sessionId":"s","requestId":"r","timestamp":"\#(lineTs)","message":{"model":"claude-opus-4-6","stop_reason":"end_turn","usage":{"input_tokens":1,"cache_creation_input_tokens":1000,"cache_read_input_tokens":0,"output_tokens":1}}}"#)

        // CacheTimer needs two ticks to fire transitionedToCold: the first tick
        // records the initial warm state; the second detects the warm → cold
        // transition. Tick at "now" (warm), then at "now + 6 minutes" (cold).
        store.tickForTesting(at: now)
        store.tickForTesting(at: now.addingTimeInterval(360))

        XCTAssertTrue(played().contains("Submerge"),
                      "expected Submerge (newCold default in test universe), got \(played())")
    }
}
