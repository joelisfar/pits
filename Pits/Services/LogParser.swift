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
            // Dedup any existing duplicates from caches written before the
            // dedup rule landed (warm-launch reconciliation could append the
            // same human turn twice if offsets were ever miscomputed). One-
            // shot cleanup on hydrate; subsequent ingest() prevents new dups.
            self.humanTurnsBySession = seed.humanTurnsBySession.mapValues { Self.dedupHumanTurns($0) }
            self.titleBySession = seed.titleBySession
        }
    }

    /// Dedup HumanTurn arrays by `(sessionId, timestamp)`. Real human turns
    /// have sub-millisecond timestamps; identical timestamps almost always
    /// mean the same JSONL line was processed twice (offset miscalc, replay
    /// after a crash, etc.). Keep the first occurrence — preview text is
    /// derived from the line content and stable.
    private static func dedupHumanTurns(_ turns: [HumanTurn]) -> [HumanTurn] {
        var seen: Set<Date> = []
        seen.reserveCapacity(turns.count)
        var out: [HumanTurn] = []
        out.reserveCapacity(turns.count)
        for t in turns {
            if seen.insert(t.timestamp).inserted {
                out.append(t)
            }
        }
        return out
    }

    func ingest(line: String) {
        guard let entry = JSONLDecoder.decode(line: line) else { return }
        switch entry {
        case .turn(let t):
            ingestTurn(t)
        case .human(let h):
            // Dedup by (sessionId, timestamp). Without this, a botched
            // reconciliation that re-reads bytes would silently grow
            // humanTurnsBySession unboundedly each launch.
            let existing = humanTurnsBySession[h.sessionId] ?? []
            if !existing.contains(where: { $0.timestamp == h.timestamp }) {
                humanTurnsBySession[h.sessionId, default: []].append(h)
            }
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

    /// Chronologically first user-message preview for a session, if any of
    /// its human turns carried one. Row-title fallback for sessions that
    /// never received an `ai-title` event (e.g. slash-command openers).
    func firstMessageText(sessionId: String) -> String? {
        humanTurns(sessionId: sessionId)
            .lazy
            .compactMap { $0.text }
            .first
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
