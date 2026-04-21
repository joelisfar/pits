import Foundation

/// Stateful parser: feeds lines in, deduplicates by requestId (preferring
/// occurrences with a non-nil stop_reason), groups turns by sessionId.
/// Not thread-safe — call from a single queue.
final class LogParser {
    private var turnsByRequestId: [String: Turn] = [:]
    private var humanTurnsBySession: [String: [HumanTurn]] = [:]
    private var titleBySession: [String: String] = [:]

    /// Called whenever a session's turn list changes. sessionId passed in.
    var onSessionUpdated: ((String) -> Void)?

    init(seed: PersistedParser? = nil) {
        if let seed {
            self.turnsByRequestId = seed.turnsByRequestId
            self.humanTurnsBySession = seed.humanTurnsBySession
            self.titleBySession = seed.titleBySession
        }
    }

    func ingest(line: String) {
        guard let entry = JSONLDecoder.decode(line: line) else { return }
        switch entry {
        case .turn(let t):
            ingestTurn(t)
        case .human(let h):
            humanTurnsBySession[h.sessionId, default: []].append(h)
        case .title(let st):
            // Claude Code occasionally overwrites the title mid-session; take
            // the most recently seen value.
            titleBySession[st.sessionId] = st.title
        }
    }

    private func ingestTurn(_ t: Turn) {
        if !t.requestId.isEmpty, let existing = turnsByRequestId[t.requestId] {
            // Dedup rule: prefer the occurrence with a non-nil stop_reason.
            if t.stopReason != nil && existing.stopReason == nil {
                turnsByRequestId[t.requestId] = t
                onSessionUpdated?(t.sessionId)
            }
            return
        }
        let key = t.requestId.isEmpty ? t.id : t.requestId
        turnsByRequestId[key] = t
        onSessionUpdated?(t.sessionId)
    }

    /// All retained turns for a session, sorted chronologically.
    func turns(sessionId: String) -> [Turn] {
        turnsByRequestId.values
            .filter { $0.sessionId == sessionId }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// All human turns for a session, sorted chronologically. Used by the classifier.
    func humanTurns(sessionId: String) -> [HumanTurn] {
        (humanTurnsBySession[sessionId] ?? []).sorted { $0.timestamp < $1.timestamp }
    }

    /// AI-generated title for a session, if one has been seen.
    func title(sessionId: String) -> String? {
        titleBySession[sessionId]
    }

    /// All session IDs currently tracked.
    func sessionIds() -> Set<String> {
        var ids = Set(turnsByRequestId.values.map(\.sessionId))
        for sid in humanTurnsBySession.keys { ids.insert(sid) }
        return ids
    }

    /// Snapshot of internal state for persistence. Safe to call from the same
    /// queue that owns the parser.
    func snapshot() -> PersistedParser {
        PersistedParser(
            turnsByRequestId: turnsByRequestId,
            humanTurnsBySession: humanTurnsBySession,
            titleBySession: titleBySession
        )
    }
}
