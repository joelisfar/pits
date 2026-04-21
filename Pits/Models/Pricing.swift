import Foundation

/// Per-million-token pricing for Claude models, in USD.
/// Sourced from gh-claude-costs/extract.py.
enum Pricing {
    struct Rates: Equatable {
        let base: Double         // input tokens (no cache)
        let cacheWrite: Double   // cache_creation_input_tokens
        let cacheRead: Double    // cache_read_input_tokens
        let output: Double       // output_tokens
    }

    static let table: [String: Rates] = [
        "claude-opus-4-6":   Rates(base: 5.00,  cacheWrite: 6.25,  cacheRead: 0.50, output: 25.00),
        "claude-opus-4-5":   Rates(base: 5.00,  cacheWrite: 6.25,  cacheRead: 0.50, output: 25.00),
        "claude-opus-4":     Rates(base: 15.00, cacheWrite: 18.75, cacheRead: 1.50, output: 75.00),
        "claude-sonnet-4-6": Rates(base: 3.00,  cacheWrite: 3.75,  cacheRead: 0.30, output: 15.00),
        "claude-sonnet-4-5": Rates(base: 3.00,  cacheWrite: 3.75,  cacheRead: 0.30, output: 15.00),
        "claude-sonnet-4":   Rates(base: 3.00,  cacheWrite: 3.75,  cacheRead: 0.30, output: 15.00),
        "claude-haiku-4-5":  Rates(base: 0.80,  cacheWrite: 1.00,  cacheRead: 0.08, output: 4.00),
        "claude-haiku-3-5":  Rates(base: 0.80,  cacheWrite: 1.00,  cacheRead: 0.08, output: 4.00),
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
