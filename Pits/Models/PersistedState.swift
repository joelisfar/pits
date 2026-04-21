import Foundation

/// On-disk snapshot of everything the store needs to render the conversation
/// list without re-parsing JSONLs from byte zero. Loaded synchronously at
/// `ConversationStore.init` and rewritten (debounced) after each rebuild.
struct PersistedState: Codable, Equatable {
    /// Bumped when the on-disk shape changes. Mismatch → discard cache.
    let schemaVersion: Int
    let savedAt: Date
    /// The user's loaded window at save time (1 = today only, 7 = today + 6).
    let daysLoaded: Int
    /// sessionId → originating JSONL file URL.
    let fileBySession: [String: URL]
    /// File URL → byte offset where the next read should start. Always points
    /// at or before the start of any trailing partial line so partials get
    /// re-read from disk on next launch.
    let offsets: [URL: UInt64]
    /// Deduplicated parser state — what `LogParser` knows.
    let parser: PersistedParser
}

struct PersistedParser: Codable, Equatable {
    let turnsByRequestId: [String: Turn]
    let humanTurnsBySession: [String: [HumanTurn]]
    let titleBySession: [String: String]
}
