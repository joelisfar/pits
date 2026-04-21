import Foundation

/// Stateful parser: feeds lines in, deduplicates by requestId (preferring
/// occurrences with a non-nil stop_reason), groups turns by sessionId.
/// Not thread-safe — call from a single queue.
final class LogParser {
    private var turnsByRequestId: [String: Turn] = [:]
    private var humanTurnsBySession: [String: [HumanTurn]] = [:]

    /// Called whenever a session's turn list changes. sessionId passed in.
    var onSessionUpdated: ((String) -> Void)?

    func ingest(line: String) {
        guard let entry = JSONLDecoder.decode(line: line) else { return }
        switch entry {
        case .turn(let t):
            ingestTurn(t)
        case .human(let h):
            humanTurnsBySession[h.sessionId, default: []].append(h)
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

    /// All session IDs currently tracked.
    func sessionIds() -> Set<String> {
        var ids = Set(turnsByRequestId.values.map(\.sessionId))
        for sid in humanTurnsBySession.keys { ids.insert(sid) }
        return ids
    }
}
