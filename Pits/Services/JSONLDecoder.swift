import Foundation

/// Decoded kind of a JSONL line that is meaningful to Pits.
enum JSONLEntry {
    case turn(Turn)
    case human(HumanTurn)
}

/// Marker for a human turn (used by the classifier, not displayed).
struct HumanTurn {
    let sessionId: String
    let timestamp: Date
    let isSubagent: Bool
    let agentId: String?
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
        guard let ts = parseTimestamp(obj["timestamp"] as? String) else { return nil }
        let sessionId = obj["sessionId"] as? String ?? ""
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

            let turn = Turn(
                requestId: requestId,
                sessionId: sessionId,
                timestamp: ts,
                model: model,
                inputTokens: usage["input_tokens"] as? Int ?? 0,
                cacheCreationTokens: usage["cache_creation_input_tokens"] as? Int ?? 0,
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
            let hasText = arr.contains { ($0["type"] as? String) == "text" }
            let allToolResults = !arr.isEmpty && arr.allSatisfy { ($0["type"] as? String) == "tool_result" }
            return hasText && !allToolResults
        }
        return false
    }
}
