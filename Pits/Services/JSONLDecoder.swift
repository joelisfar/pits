import Foundation

/// Decoded kind of a JSONL line that is meaningful to Pits.
enum JSONLEntry {
    case turn(Turn)
    case human(HumanTurn)
    case title(SessionTitle)
}

/// Marker for a human turn (used by the classifier, not displayed).
struct HumanTurn: Equatable, Codable {
    let sessionId: String
    let timestamp: Date
    let isSubagent: Bool
    let agentId: String?
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
            return .human(HumanTurn(sessionId: sessionId, timestamp: ts, isSubagent: isSubagent, agentId: agentId))

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
}
