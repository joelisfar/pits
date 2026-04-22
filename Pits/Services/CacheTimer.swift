import Foundation

enum CacheTimerEvent: Equatable {
    case transitionedToCold(String)   // conversation id
    case oneMinuteWarning(String)     // conversation id
}

/// Pure state machine that, on each tick, diffs current vs. previous cache
/// status and remaining time to emit transition + warning events.
final class CacheTimer {
    private struct Snapshot {
        var status: CacheStatus
        var warnedOneMinute: Bool
        var lastResponse: Date?
    }

    private var states: [String: Snapshot] = [:]

    /// Advance all tracked conversations to `now`. Returns events to act on.
    ///
    /// `openSessionIds` gates user-facing warnings: sessions whose id is not in
    /// the set are treated as closed tabs and do not emit `oneMinuteWarning`
    /// events (there's no user to warn). Internal state still tracks warm/cold
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
                // has been refreshed — reset warning & transition state.
                if let prevLast = prev.lastResponse, let newLast = last, newLast > prevLast {
                    prev.warnedOneMinute = false
                    prev.status = .warm
                }
                // Transition warm → cold fires once.
                if prev.status == .warm && status == .cold {
                    events.append(.transitionedToCold(c.id))
                }
                // One-minute warning fires once per warm period, and only for
                // sessions the user currently has open. A closed session stays
                // with `warnedOneMinute = false` so reopening mid-window still
                // fires exactly once.
                if status == .warm, remaining <= 60, !prev.warnedOneMinute,
                   openSessionIds.contains(c.id) {
                    events.append(.oneMinuteWarning(c.id))
                    prev.warnedOneMinute = true
                }
                prev.status = status
                prev.lastResponse = last
                states[c.id] = prev
            } else {
                // First observation: no events, just record state.
                var snap = Snapshot(status: status, warnedOneMinute: false, lastResponse: last)
                if status == .warm, remaining <= 60 {
                    // If we first see it already inside the warning window,
                    // don't fire — we only alert on *entry* to that window.
                    snap.warnedOneMinute = true
                }
                states[c.id] = snap
            }
        }

        // Drop state for conversations that disappeared.
        states = states.filter { seen.contains($0.key) }
        return events
    }
}
