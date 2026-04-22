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
    /// Displayable preview of the first user message. Used as a row-title
    /// fallback when `title` is nil (Claude Code skips title generation for
    /// sessions that open with a slash command).
    let firstMessageText: String?
    /// JSONL file backing this session.
    let filePath: URL
    /// All retained turns, in chronological order.
    let turns: [Turn]
    /// Cache TTL in seconds (configurable via settings).
    let ttlSeconds: TimeInterval
    /// User messages in this session, chronological. The cache TTL resets
    /// when a message is *sent*, not only when Claude replies, so these
    /// timestamps drive the warm-countdown alongside assistant turns.
    let humanTurns: [HumanTurn]

    init(
        id: String,
        projectName: String,
        title: String? = nil,
        firstMessageText: String? = nil,
        filePath: URL,
        turns: [Turn],
        humanTurns: [HumanTurn] = [],
        ttlSeconds: TimeInterval
    ) {
        self.id = id
        self.projectName = projectName
        self.title = title
        self.firstMessageText = firstMessageText
        self.filePath = filePath
        self.turns = turns
        self.humanTurns = humanTurns
        self.ttlSeconds = ttlSeconds
    }

    // MARK: - Derived

    /// Parent (non-subagent) turns only.
    var ownTurns: [Turn] {
        turns.filter { !$0.isSubagent }
    }

    /// Turns delegated to subagents. Same `sessionId` as the parent —
    /// distinguished only by the per-line `agentId` / `isSubagent` flag.
    var subagentTurns: [Turn] {
        turns.filter { $0.isSubagent }
    }

    /// True when this conversation delegated any work to subagents.
    var hasSubagentTurns: Bool { !subagentTurns.isEmpty }

    /// Parent + subagent cost — what a human cares about for "what did this
    /// conversation cost me".
    var totalCost: Double {
        turns.reduce(0.0) { $0 + $1.totalCost }
    }

    /// Cost contributed only by subagent turns.
    var subagentCost: Double {
        subagentTurns.reduce(0.0) { $0 + $1.totalCost }
    }

    /// Last assistant timestamp across parent + subagent turns.
    var lastResponseTimestamp: Date? {
        turns.map(\.timestamp).max()
    }

    /// Timestamp of the most recent interaction of any kind (human or
    /// assistant) in this session. This is what drives the cache-TTL
    /// countdown — a human message hitting the API resets the TTL even
    /// before Claude finishes replying.
    var lastTurnTimestamp: Date? {
        let t = [lastResponseTimestamp, humanTurns.map(\.timestamp).max()].compactMap { $0 }
        return t.max()
    }

    var lastActivityTimestamp: Date {
        lastTurnTimestamp ?? .distantPast
    }

    /// TTL of the most recent assistant turn that wrote to the cache
    /// (`.ephemeral_5m_input_tokens` → 300s, `.ephemeral_1h_input_tokens` → 3600s).
    /// Walks turns newest-first to tolerate occasional no-cache turns without
    /// losing the established TTL. Nil only when no turn in the session has
    /// ever written to the cache — represented as `.new` in `cacheStatus`.
    var observedTTLSeconds: TimeInterval? {
        let sortedDesc = turns.sorted(by: { $0.timestamp > $1.timestamp })
        for t in sortedDesc {
            if t.cacheCreation1hTokens > 0 { return 3600 }
            if t.cacheCreation5mTokens > 0 { return 300 }
        }
        return nil
    }

    func cacheTTLRemaining(at now: Date) -> TimeInterval {
        guard let last = lastTurnTimestamp else { return 0 }
        let elapsed = now.timeIntervalSince(last)
        return max(0, ttlSeconds - elapsed)
    }

    func cacheStatus(at now: Date) -> CacheStatus {
        cacheTTLRemaining(at: now) > 0 ? .warm : .cold
    }

    /// Estimated cost of the next turn's input bill.
    /// Warm: context size × cache_read rate (cache is reused).
    /// Cold: context size × cache-write rate, weighted by the last turn's
    ///       5m/1h split. Falls back to the 5m rate when the last turn had
    ///       no cache_creation tokens (no signal for the mix).
    func estimatedNextTurnCost(at now: Date) -> Double {
        guard let last = turns.max(by: { $0.timestamp < $1.timestamp }) else { return 0 }
        guard let rates = Pricing.rates(for: last.model) else { return 0 }
        let context = Double(last.contextSize)
        switch cacheStatus(at: now) {
        case .warm:
            return context * rates.cacheRead / 1_000_000.0
        case .cold:
            let total = last.cacheCreation5mTokens + last.cacheCreation1hTokens
            let writeRate: Double
            if total > 0 {
                let frac1h = Double(last.cacheCreation1hTokens) / Double(total)
                writeRate = rates.cacheWrite5m * (1.0 - frac1h) + rates.cacheWrite1h * frac1h
            } else {
                writeRate = rates.cacheWrite5m
            }
            return context * writeRate / 1_000_000.0
        }
    }

    // MARK: - Filtering

    /// Returns a new `Conversation` containing only `turns` and `humanTurns`
    /// whose timestamps fall in `month`'s `[start, nextMonthStart)` range.
    /// Returns nil when nothing remains in scope.
    func filtered(toMonth month: MonthScope, in cal: Calendar = Calendar.current) -> Conversation? {
        let range = month.dateRange(in: cal)
        let keptTurns = turns.filter { range.contains($0.timestamp) }
        let keptHumans = humanTurns.filter { range.contains($0.timestamp) }
        if keptTurns.isEmpty && keptHumans.isEmpty { return nil }
        return Conversation(
            id: id,
            projectName: projectName,
            title: title,
            firstMessageText: firstMessageText,
            filePath: filePath,
            turns: keptTurns,
            humanTurns: keptHumans,
            ttlSeconds: ttlSeconds
        )
    }

    // MARK: - Path parsing

    /// Convert a JSONL file URL like
    /// `~/.claude/projects/-Users-jifarris-Projects-pits/abc.jsonl`
    /// into the project's leaf directory name, e.g. `pits`. Claude Code
    /// encodes the full project path as a dash-separated directory; the
    /// encoding is lossy when a directory's own name contains a dash
    /// (e.g. `one-two-three` is indistinguishable from nested `one/two/three`),
    /// so we walk the split against the real filesystem to find the actual
    /// boundary between parent and leaf. Falls back to the naive split when
    /// nothing on disk matches (project may have been moved or deleted).
    static func projectName(from fileURL: URL) -> String {
        // Subagent files live at: .../projects/-<proj>/<parent-id>/subagents/<child>.jsonl
        // We want the project directory, not the "subagents" leaf or the parent-id dir.
        var dir = fileURL.deletingLastPathComponent()
        if dir.lastPathComponent == "subagents" {
            dir = dir.deletingLastPathComponent().deletingLastPathComponent()
        }
        let encoded = dir.lastPathComponent
        var parts = encoded.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        if parts.first == "" { parts.removeFirst() } // drop the leading empty from "-Users..."
        guard !parts.isEmpty else { return encoded }
        let naiveLeaf = parts.last!

        let fm = FileManager.default
        var matchedPath = ""
        var i = 0
        while i < parts.count {
            let candidate = matchedPath + "/" + parts[i]
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                matchedPath = candidate
                i += 1
            } else if i + 1 < parts.count {
                // The dash between parts[i] and parts[i+1] was literal, not a
                // separator — merge and retry at the same index.
                parts[i] = parts[i] + "-" + parts[i + 1]
                parts.remove(at: i + 1)
            } else {
                return naiveLeaf
            }
        }
        return (matchedPath as NSString).lastPathComponent
    }
}
