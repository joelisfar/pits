import Foundation

/// A single assistant API response parsed from a JSONL line.
struct Turn: Identifiable, Equatable, Codable {
    let requestId: String
    let sessionId: String
    let timestamp: Date
    /// Normalized model name (no date suffix).
    let model: String
    let inputTokens: Int
    /// `cache_creation.ephemeral_5m_input_tokens` — billed at 1.25× base.
    let cacheCreation5mTokens: Int
    /// `cache_creation.ephemeral_1h_input_tokens` — billed at 2× base.
    let cacheCreation1hTokens: Int
    let cacheReadTokens: Int
    let outputTokens: Int
    /// Nil while streaming; set when the response completes. Used for dedup tie-breaks.
    let stopReason: String?
    let isSubagent: Bool

    init(
        requestId: String,
        sessionId: String,
        timestamp: Date,
        model: String,
        inputTokens: Int,
        cacheCreation5mTokens: Int,
        cacheCreation1hTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int,
        stopReason: String?,
        isSubagent: Bool
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.model = model
        self.inputTokens = inputTokens
        self.cacheCreation5mTokens = cacheCreation5mTokens
        self.cacheCreation1hTokens = cacheCreation1hTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens
        self.stopReason = stopReason
        self.isSubagent = isSubagent
    }

    /// Convenience initializer for tests / call sites that don't care about
    /// the 5m/1h split. The supplied count is treated as 5m cache writes.
    init(
        requestId: String,
        sessionId: String,
        timestamp: Date,
        model: String,
        inputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int,
        stopReason: String?,
        isSubagent: Bool
    ) {
        self.init(
            requestId: requestId,
            sessionId: sessionId,
            timestamp: timestamp,
            model: model,
            inputTokens: inputTokens,
            cacheCreation5mTokens: cacheCreationTokens,
            cacheCreation1hTokens: 0,
            cacheReadTokens: cacheReadTokens,
            outputTokens: outputTokens,
            stopReason: stopReason,
            isSubagent: isSubagent
        )
    }

    var id: String { requestId.isEmpty ? "\(sessionId)-\(timestamp.timeIntervalSince1970)" : requestId }

    /// Total cache_creation tokens (5m + 1h). For display and for `contextSize`.
    var cacheCreationTokens: Int { cacheCreation5mTokens + cacheCreation1hTokens }

    /// Total tokens in the model's context window for this request.
    var contextSize: Int { cacheCreationTokens + cacheReadTokens + inputTokens }

    private var rates: Pricing.Rates? { Pricing.rates(for: model) }

    var inputCost: Double {
        guard let r = rates else { return 0 }
        return Double(inputTokens) * r.base / 1_000_000.0
    }

    var cacheWriteCost: Double {
        guard let r = rates else { return 0 }
        let fivem = Double(cacheCreation5mTokens) * r.cacheWrite5m / 1_000_000.0
        let oneh  = Double(cacheCreation1hTokens) * r.cacheWrite1h / 1_000_000.0
        return fivem + oneh
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
