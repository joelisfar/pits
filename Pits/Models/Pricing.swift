import Foundation

/// Per-million-token pricing for Claude models, in USD.
///
/// Anthropic's published multipliers (relative to base input):
///  - 5-minute cache write: 1.25x
///  - 1-hour cache write:   2.00x
///  - cache read:           0.10x
enum Pricing {
    struct Rates: Equatable {
        let base: Double         // input_tokens (no cache)
        let cacheWrite5m: Double // cache_creation.ephemeral_5m_input_tokens
        let cacheWrite1h: Double // cache_creation.ephemeral_1h_input_tokens
        let cacheRead: Double    // cache_read_input_tokens
        let output: Double       // output_tokens
    }

    private static func rates(input: Double, output: Double) -> Rates {
        Rates(
            base: input,
            cacheWrite5m: input * 1.25,
            cacheWrite1h: input * 2.00,
            cacheRead:    input * 0.10,
            output: output
        )
    }

    static let table: [String: Rates] = [
        "claude-opus-4-7":   rates(input: 5.00,  output: 25.00),
        "claude-opus-4-6":   rates(input: 5.00,  output: 25.00),
        "claude-opus-4-5":   rates(input: 5.00,  output: 25.00),
        "claude-opus-4":     rates(input: 15.00, output: 75.00),
        "claude-sonnet-4-6": rates(input: 3.00,  output: 15.00),
        "claude-sonnet-4-5": rates(input: 3.00,  output: 15.00),
        "claude-sonnet-4":   rates(input: 3.00,  output: 15.00),
        "claude-haiku-4-5":  rates(input: 1.00,  output: 5.00),
        "claude-haiku-3-5":  Rates(base: 0.80, cacheWrite5m: 1.00, cacheWrite1h: 1.60, cacheRead: 0.08, output: 4.00),
    ]

    /// Strip trailing `-YYYYMMDD` date suffix. Returns nil for synthetic names like `<synthetic>`.
    static func normalizeModel(_ raw: String) -> String? {
        if raw.hasPrefix("<") { return nil }
        guard let regex = try? NSRegularExpression(pattern: #"-\d{8,}$"#) else { return raw }
        let range = NSRange(raw.startIndex..., in: raw)
        return regex.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
    }

    /// Rates for a normalized model name, or nil if unknown.
    static func rates(for normalizedModel: String) -> Rates? {
        table[normalizedModel]
    }
}
