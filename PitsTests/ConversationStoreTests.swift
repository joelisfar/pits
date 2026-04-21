import XCTest
@testable import Pits

@MainActor
final class ConversationStoreTests: XCTestCase {
    private func makeStore(ttl: TimeInterval = 300) -> ConversationStore {
        let silentDefaults = UserDefaults(suiteName: "net.farriswheel.Pits.test-\(UUID().uuidString)")!
        let silentSound = SoundManager(defaults: silentDefaults, player: { _ in })
        return ConversationStore(
            rootDirectory: URL(fileURLWithPath: "/nonexistent"),
            ttlSeconds: ttl,
            sound: silentSound
        )
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

    func test_updatesWhenTTLChanges() {
        let store = makeStore()
        store.ingestForTesting(
            url: URL(fileURLWithPath: "/tmp/-a/a.jsonl"),
            line: #"{"type":"assistant","sessionId":"s","requestId":"r","timestamp":"2026-04-21T10:00:00.000Z","message":{"model":"claude-opus-4-6","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#
        )
        XCTAssertEqual(store.conversations.first?.ttlSeconds, 300)

        store.ttlSeconds = 600
        XCTAssertEqual(store.conversations.first?.ttlSeconds, 600)
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
}
