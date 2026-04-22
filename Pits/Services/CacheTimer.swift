import Foundation

enum CacheTimerEvent: Equatable {
    case transitionedToCold(String)     // conversation id
    case oneMinuteWarning(String)       // conversation id
    case fifteenSecondWarning(String)   // conversation id
}

/// Pure state machine that, on each tick, diffs current vs. previous cache
/// status and remaining time to emit transition + warning events.
final class CacheTimer {
    private struct Snapshot {
        var status: CacheStatus
        var warnedOneMinute: Bool
        var warnedFifteenSeconds: Bool
        var lastResponse: Date?
    }

    private var states: [String: Snapshot] = [:]

    /// Advance all tracked conversations to `now`. Returns events to act on.
    ///
    /// `openSessionIds` gates user-facing warnings: sessions whose id is not in
    /// the set are treated as closed tabs and do not emit warning events
    /// (there's no user to warn). Internal state still tracks warm/cold
    /// transitions so that a subsequent reopen-within-window can fire normally.
    func tick(conversations: [Conversation], at now: Date, openSessionIds: Set<String>) -> [CacheTimerEvent] {
        var events: [CacheTimerEvent] = []
        var seen = Set<String>()

        for c in conversations {
            seen.insert(c.id)
            let status = c.cacheStatus(at: now)
            let remaining = c.cacheTTLRemaining(at: now)
            let last = c.lastResponseTimestamp

            if var prev = states[c.id] {
                // If there's a newer response than we last knew about, the cache
                // has been refreshed — reset both warnings so they can fire again
                // in the new warm period. `prev.status` is overwritten below
                // with the freshly-computed status; we don't pretend it was `.warm`.
                if let prevLast = prev.lastResponse, let newLast = last, newLast > prevLast {
                    prev.warnedOneMinute = false
                    prev.warnedFifteenSeconds = false
                }
                // Transition warm → cold fires once, only for open sessions.
                // A closed tab going cold while the user isn't watching shouldn't
                // make noise. Unlike the warning events, we don't defer-fire on
                // reopen — by the time the user looks again, the announcement
                // is stale ("this expired some time ago" isn't actionable).
                if prev.status == .warm && status == .cold,
                   openSessionIds.contains(c.id) {
                    events.append(.transitionedToCold(c.id))
                }
                // One-minute warning fires once per warm period, only for open sessions.
                if status == .warm, remaining <= 60, !prev.warnedOneMinute,
                   openSessionIds.contains(c.id) {
                    events.append(.oneMinuteWarning(c.id))
                    prev.warnedOneMinute = true
                }
                // Fifteen-second warning fires once per warm period, only for open sessions.
                if status == .warm, remaining <= 15, !prev.warnedFifteenSeconds,
                   openSessionIds.contains(c.id) {
                    events.append(.fifteenSecondWarning(c.id))
                    prev.warnedFifteenSeconds = true
                }
                prev.status = status
                prev.lastResponse = last
                states[c.id] = prev
            } else {
                // First observation: no events, just record state. If we first
                // see the conversation already inside a warning window, mark
                // that warning as already-fired — we only alert on *entry*.
                var snap = Snapshot(
                    status: status,
                    warnedOneMinute: false,
                    warnedFifteenSeconds: false,
                    lastResponse: last
                )
                if status == .warm, remaining <= 60 { snap.warnedOneMinute = true }
                if status == .warm, remaining <= 15 { snap.warnedFifteenSeconds = true }
                states[c.id] = snap
            }
        }

        // Drop state for conversations that disappeared.
        states = states.filter { seen.contains($0.key) }
        return events
    }
}
