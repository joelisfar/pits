import XCTest
@testable import Pits

@MainActor
final class ConversationStoreTests: XCTestCase {
    func test_ingestLine_producesConversation() {
        let store = ConversationStore(
            rootDirectory: URL(fileURLWithPath: "/nonexistent"),
            ttlSeconds: 300
        )
        let url = URL(fileURLWithPath: "/Users/j/.claude/projects/-Users-j-Projects-demo/abc.jsonl")
        store.ingestForTesting(url: url, line: #"{"type":"assistant","sessionId":"s1","requestId":"r1","timestamp":"2026-04-21T10:00:00.000Z","message":{"model":"claude-opus-4-6","stop_reason":"end_turn","usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}"#)

        XCTAssertEqual(store.conversations.count, 1)
        let c = store.conversations[0]
        XCTAssertEqual(c.id, "s1")
        XCTAssertEqual(c.projectName, "/Users/j/Projects/demo")
        XCTAssertEqual(c.turns.count, 1)
    }

    func test_conversations_sortedByMostRecentActivity() {
        let store = ConversationStore(rootDirectory: URL(fileURLWithPath: "/x"), ttlSeconds: 300)
        let urlA = URL(fileURLWithPath: "/tmp/-a/a.jsonl")
        let urlB = URL(fileURLWithPath: "/tmp/-b/b.jsonl")
        store.ingestForTesting(url: urlA, line: #"{"type":"assistant","sessionId":"sa","requestId":"r1","timestamp":"2026-04-21T10:00:00.000Z","message":{"model":"claude-opus-4-6","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#)
        store.ingestForTesting(url: urlB, line: #"{"type":"assistant","sessionId":"sb","requestId":"r2","timestamp":"2026-04-21T11:00:00.000Z","message":{"model":"claude-opus-4-6","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#)

        XCTAssertEqual(store.conversations.map(\.id), ["sb", "sa"])
    }

    func test_updatesWhenTTLChanges() {
        let store = ConversationStore(rootDirectory: URL(fileURLWithPath: "/x"), ttlSeconds: 300)
        store.ingestForTesting(
            url: URL(fileURLWithPath: "/tmp/-a/a.jsonl"),
            line: #"{"type":"assistant","sessionId":"s","requestId":"r","timestamp":"2026-04-21T10:00:00.000Z","message":{"model":"claude-opus-4-6","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#
        )
        XCTAssertEqual(store.conversations.first?.ttlSeconds, 300)

        store.ttlSeconds = 600
        XCTAssertEqual(store.conversations.first?.ttlSeconds, 600)
    }
}
