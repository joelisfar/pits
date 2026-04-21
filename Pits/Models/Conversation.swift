import Foundation

enum CacheStatus { case warm, cold }

/// A single Claude Code conversation aggregated from one JSONL file.
struct Conversation: Identifiable, Equatable {
    /// Session id; also doubles as the identity of the Conversation.
    let id: String
    /// Human-readable project path, parsed from the enclosing directory.
    let projectName: String
    /// JSONL file backing this session.
    let filePath: URL
    /// All retained turns, in chronological order.
    let turns: [Turn]
    /// Cache TTL in seconds (configurable via settings).
    let ttlSeconds: TimeInterval

    // MARK: - Derived

    var totalCost: Double {
        turns.reduce(0.0) { $0 + $1.totalCost }
    }

    var lastResponseTimestamp: Date? {
        turns.map(\.timestamp).max()
    }

    var lastActivityTimestamp: Date {
        lastResponseTimestamp ?? .distantPast
    }

    func cacheTTLRemaining(at now: Date) -> TimeInterval {
        guard let last = lastResponseTimestamp else { return 0 }
        let elapsed = now.timeIntervalSince(last)
        return max(0, ttlSeconds - elapsed)
    }

    func cacheStatus(at now: Date) -> CacheStatus {
        cacheTTLRemaining(at: now) > 0 ? .warm : .cold
    }

    /// Estimated cost of the next turn's input bill.
    /// Warm: context size × cache_read rate (cache is reused).
    /// Cold: context size × cache_write rate (cache must be rebuilt).
    func estimatedNextTurnCost(at now: Date) -> Double {
        guard let last = turns.max(by: { $0.timestamp < $1.timestamp }) else { return 0 }
        guard let rates = Pricing.rates(for: last.model) else { return 0 }
        let context = Double(last.contextSize)
        switch cacheStatus(at: now) {
        case .warm: return context * rates.cacheRead / 1_000_000.0
        case .cold: return context * rates.cacheWrite / 1_000_000.0
        }
    }

    // MARK: - Path parsing

    /// Convert a JSONL file URL like
    /// `~/.claude/projects/-Users-jifarris-Projects-pits/abc.jsonl`
    /// into a human-readable project path `/Users/jifarris/Projects/pits`.
    /// The directory uses `-` as a path separator substitute.
    static func projectName(from fileURL: URL) -> String {
        let dir = fileURL.deletingLastPathComponent().lastPathComponent
        // Claude encodes slashes as dashes; leading slash is also a dash.
        // e.g. "-Users-jifarris-Projects-pits" → "/Users/jifarris/Projects/pits"
        return dir.replacingOccurrences(of: "-", with: "/")
    }
}
