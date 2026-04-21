import Foundation

enum CacheStatus { case warm, cold }

/// A single Claude Code conversation aggregated from one JSONL file.
struct Conversation: Identifiable, Equatable {
    /// Session id; also doubles as the identity of the Conversation.
    let id: String
    /// Human-readable project path, parsed from the enclosing directory.
    let projectName: String
    /// AI-generated session title, if Claude Code has written one yet.
    let title: String?
    /// JSONL file backing this session.
    let filePath: URL
    /// All retained turns, in chronological order.
    let turns: [Turn]
    /// Cache TTL in seconds (configurable via settings).
    let ttlSeconds: TimeInterval

    init(
        id: String,
        projectName: String,
        title: String? = nil,
        filePath: URL,
        turns: [Turn],
        ttlSeconds: TimeInterval
    ) {
        self.id = id
        self.projectName = projectName
        self.title = title
        self.filePath = filePath
        self.turns = turns
        self.ttlSeconds = ttlSeconds
    }

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
    /// into the project's leaf directory name, e.g. `pits`. Claude Code
    /// encodes the full project path as a dash-separated directory; we decode
    /// it back to a real path and keep only the last component so the row
    /// label stays compact.
    static func projectName(from fileURL: URL) -> String {
        let dir = fileURL.deletingLastPathComponent().lastPathComponent
        // "-Users-jifarris-Projects-pits" → "/Users/jifarris/Projects/pits" → "pits"
        let fullPath = dir.replacingOccurrences(of: "-", with: "/")
        return URL(fileURLWithPath: fullPath).lastPathComponent
    }
}
