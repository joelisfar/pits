import Foundation

/// Decoded kind of a JSONL line that is meaningful to Pits.
enum JSONLEntry {
    case turn(Turn)
    case human(HumanTurn)
    case title(SessionTitle)
}

/// Marker for a human turn (used by the classifier, not displayed).
/// `text` carries a short, displayable preview of the user message — used as
/// a row-title fallback when Claude Code never wrote an `ai-title` for the
/// session (e.g. sessions opened with a slash command).
struct HumanTurn: Equatable, Codable {
    let sessionId: String
    let timestamp: Date
    let isSubagent: Bool
    let agentId: String?
    let text: String?

    init(sessionId: String, timestamp: Date, isSubagent: Bool, agentId: String?, text: String? = nil) {
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.isSubagent = isSubagent
        self.agentId = agentId
        self.text = text
    }
}

/// AI-generated session title — written as a one-shot `{"type":"ai-title",...}`
/// entry in the JSONL by Claude Code once the first few turns are summarized.
struct SessionTitle: Equatable, Codable {
    let sessionId: String
    let title: String
}

enum JSONLDecoder {
    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func decode(line: String) -> JSONLEntry? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }

        guard let type = obj["type"] as? String else { return nil }
        let sessionId = obj["sessionId"] as? String ?? ""

        // ai-title entries carry no timestamp — handle before the timestamp guard.
        if type == "ai-title" {
            guard !sessionId.isEmpty,
                  let title = obj["aiTitle"] as? String,
                  !title.isEmpty else { return nil }
            return .title(SessionTitle(sessionId: sessionId, title: title))
        }

        guard let ts = parseTimestamp(obj["timestamp"] as? String) else { return nil }
        let agentId = obj["agentId"] as? String
        let isSubagent = agentId != nil

        switch type {
        case "user":
            guard isHumanTurn(obj) else { return nil }
            let text = humanTurnPreview(obj)
            return .human(HumanTurn(sessionId: sessionId, timestamp: ts, isSubagent: isSubagent, agentId: agentId, text: text))

        case "assistant":
            guard let msg = obj["message"] as? [String: Any] else { return nil }
            guard let usage = msg["usage"] as? [String: Any] else { return nil }
            guard let rawModel = msg["model"] as? String,
                  let model = Pricing.normalizeModel(rawModel) else { return nil }
            let requestId = obj["requestId"] as? String ?? ""
            let stopReason = msg["stop_reason"] as? String

            // cache_creation is split into {ephemeral_5m_input_tokens,
            // ephemeral_1h_input_tokens} (different rates: 1.25× vs 2× base).
            // Older entries only carry the flat cache_creation_input_tokens —
            // treat those as 5m (the API default).
            let flatCacheCreation = usage["cache_creation_input_tokens"] as? Int ?? 0
            let cc5m: Int
            let cc1h: Int
            if let cc = usage["cache_creation"] as? [String: Any] {
                cc5m = cc["ephemeral_5m_input_tokens"] as? Int ?? 0
                cc1h = cc["ephemeral_1h_input_tokens"] as? Int ?? 0
            } else {
                cc5m = flatCacheCreation
                cc1h = 0
            }

            let turn = Turn(
                requestId: requestId,
                sessionId: sessionId,
                timestamp: ts,
                model: model,
                inputTokens: usage["input_tokens"] as? Int ?? 0,
                cacheCreation5mTokens: cc5m,
                cacheCreation1hTokens: cc1h,
                cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0,
                outputTokens: usage["output_tokens"] as? Int ?? 0,
                stopReason: stopReason,
                isSubagent: isSubagent
            )
            return .turn(turn)

        default:
            return nil
        }
    }

    private static func parseTimestamp(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return timestampFormatter.date(from: raw)
    }

    private static func isHumanTurn(_ obj: [String: Any]) -> Bool {
        if let compact = obj["isCompactSummary"] as? Bool, compact { return false }
        guard let msg = obj["message"] as? [String: Any] else { return false }
        let content = msg["content"]

        if let str = content as? String {
            return !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let arr = content as? [[String: Any]] {
            // Parity with gh-claude-costs/extract.py:is_human_turn — a user entry
            // counts as a human turn iff it has any text block and is not purely
            // tool-result continuations.
            let hasText = arr.contains { ($0["type"] as? String) == "text" }
            let allToolResults = !arr.isEmpty && arr.allSatisfy { ($0["type"] as? String) == "tool_result" }
            return hasText && !allToolResults
        }
        return false
    }

    /// Extracts a displayable preview of a user JSONL entry, or nil when the
    /// entry is a synthetic wrapper with no human-authored content. Used as
    /// a row-title fallback when Claude Code never emits an `ai-title` for
    /// the session (slash-command openers are the common case).
    ///
    /// Rules, in order:
    ///  - Concatenate all `{type:"text"}` blocks (or use the raw string).
    ///  - If the concatenated text is only a `<local-command-caveat>…`
    ///    wrapper, return nil so the caller falls through to the next turn.
    ///  - If it contains a `<command-name>…</command-name>` tag, return just
    ///    the command (e.g. `/context`). Slash-command openers pack the
    ///    invocation into this tag.
    ///  - Otherwise, strip any `<ide_*>…</ide_*>` tags that wrap IDE-
    ///    inserted context, trim, and return — or nil if nothing remains.
    private static func humanTurnPreview(_ obj: [String: Any]) -> String? {
        guard let msg = obj["message"] as? [String: Any] else { return nil }
        let content = msg["content"]

        let raw: String
        if let str = content as? String {
            raw = str
        } else if let arr = content as? [[String: Any]] {
            raw = arr
                .compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
        } else {
            return nil
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        if trimmed.hasPrefix("<local-command-caveat>") { return nil }

        if let range = trimmed.range(of: "<command-name>"),
           let end = trimmed.range(of: "</command-name>", range: range.upperBound..<trimmed.endIndex) {
            let cmd = trimmed[range.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !cmd.isEmpty { return cmd }
        }

        let stripped = stripTag("ide_opened_file", from: stripTag("ide_selection", from: trimmed))
        let final = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        if final.isEmpty { return nil }
        // Cap preview length: row UI only shows a single truncated line, so
        // storing the full prompt is wasteful and a privacy hazard if the
        // cache file is ever read (it lives at ~/Library/Caches/state.json).
        return final.count > previewCharLimit
            ? String(final.prefix(previewCharLimit))
            : final
    }

    private static let previewCharLimit = 200

    /// Removes `<name>…</name>` blocks (including tags). Non-greedy so multiple
    /// occurrences are each excised. Returns the input unchanged if the tag
    /// never appears.
    private static func stripTag(_ name: String, from s: String) -> String {
        var out = s
        let open = "<\(name)>"
        let close = "</\(name)>"
        while let o = out.range(of: open),
              let c = out.range(of: close, range: o.upperBound..<out.endIndex) {
            out.removeSubrange(o.lowerBound..<c.upperBound)
        }
        return out
    }
}
