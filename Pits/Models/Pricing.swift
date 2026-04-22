import Foundation

/// Per-million-token pricing for Claude models, in USD.
///
/// Anthropic's published multipliers (relative to base input):
///  - 5-minute cache write: 1.25x
///  - 1-hour cache write:   2.00x
///  - cache read:           0.10x
enum Pricing {
    struct Rates: Equatable, Codable {
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

    /// Bundled fallback. Used when the LiteLLM fetch fails or for models the
    /// upstream JSON doesn't list. `RemotePricing` overlays fetched values
    /// onto this at app launch.
    static let bundledTable: [String: Rates] = [
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

    /// Live table — starts as `bundledTable` and is overlay-updated by
    /// `RemotePricing` at app launch (and again when the cache expires).
    private(set) static var table: [String: Rates] = bundledTable

    /// Overlay fetched rates onto `table`. Existing entries we don't have a
    /// fetched rate for are preserved.
    static func overlay(_ fetched: [String: Rates]) {
        for (model, rate) in fetched {
            table[model] = rate
        }
    }

    /// Replace the entire table. Used by tests to restore state.
    static func replaceTable(with newTable: [String: Rates]) {
        table = newTable
    }

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
