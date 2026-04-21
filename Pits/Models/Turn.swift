import Foundation

/// A single assistant API response parsed from a JSONL line.
struct Turn: Identifiable, Equatable, Codable {
    let requestId: String
    let sessionId: String
    let timestamp: Date
    /// Normalized model name (no date suffix).
    let model: String
    let inputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let outputTokens: Int
    /// Nil while streaming; set when the response completes. Used for dedup tie-breaks.
    let stopReason: String?
    let isSubagent: Bool

    var id: String { requestId.isEmpty ? "\(sessionId)-\(timestamp.timeIntervalSince1970)" : requestId }

    /// Total tokens in the model's context window for this request.
    var contextSize: Int { cacheCreationTokens + cacheReadTokens + inputTokens }

    private var rates: Pricing.Rates? { Pricing.rates(for: model) }

    var inputCost: Double {
        guard let r = rates else { return 0 }
        return Double(inputTokens) * r.base / 1_000_000.0
    }

    var cacheWriteCost: Double {
        guard let r = rates else { return 0 }
        return Double(cacheCreationTokens) * r.cacheWrite / 1_000_000.0
    }

    var cacheReadCost: Double {
        guard let r = rates else { return 0 }
        return Double(cacheReadTokens) * r.cacheRead / 1_000_000.0
    }

    var outputCost: Double {
        guard let r = rates else { return 0 }
        return Double(outputTokens) * r.output / 1_000_000.0
    }

    var totalCost: Double {
        inputCost + cacheWriteCost + cacheReadCost + outputCost
    }
}
