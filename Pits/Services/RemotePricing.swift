import Foundation
import os.log

/// Fetches model rates from LiteLLM's public pricing JSON and parses the
/// Anthropic-direct entries into `Pricing.Rates`. The 1h cache rate is not
/// in LiteLLM — derived locally as `base * 2.0` per Anthropic's docs.
enum RemotePricing {
    static let url = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    static let timeoutSeconds: TimeInterval = 5
    /// Cap on the response size we'll buffer + parse. The real file is ~150KB
    /// today; allowing 4MB leaves headroom while preventing a malicious
    /// upstream (or compromised TLS chain) from feeding gigabytes that
    /// `JSONSerialization.jsonObject(with:)` would happily try to parse.
    static let maxResponseBytes: Int = 4 * 1024 * 1024

    private static let log = OSLog(subsystem: "net.farriswheel.Pits", category: "RemotePricing")

    /// Fetch + parse. Returns empty on any failure (network, HTTP error,
    /// malformed JSON, or oversized response). Caller is expected to overlay
    /// the result onto a bundled fallback table.
    static func fetch(session: URLSession = .shared) async -> [String: Pricing.Rates] {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeoutSeconds
        do {
            let (data, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                os_log("LiteLLM HTTP %d", log: log, type: .info, http.statusCode)
                return [:]
            }
            if data.count > maxResponseBytes {
                os_log("LiteLLM response too large: %d bytes", log: log, type: .info, data.count)
                return [:]
            }
            return parse(jsonData: data)
        } catch {
            os_log("LiteLLM fetch failed: %{private}@", log: log, type: .info, String(describing: error))
            return [:]
        }
    }

    /// Pure parser — split out so tests don't need to hit the network.
    static func parse(jsonData: Data) -> [String: Pricing.Rates] {
        guard let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return [:]
        }
        var result: [String: Pricing.Rates] = [:]
        for (rawName, value) in obj {
            guard let entry = value as? [String: Any] else { continue }
            guard (entry["litellm_provider"] as? String) == "anthropic" else { continue }
            guard let normalized = Pricing.normalizeModel(rawName) else { continue }
            // Restrict to Claude families we care about.
            guard normalized.range(of: #"^claude-(opus|sonnet|haiku)-\d"#,
                                   options: .regularExpression) != nil else { continue }
            guard let inputPer = entry["input_cost_per_token"] as? Double,
                  let outputPer = entry["output_cost_per_token"] as? Double,
                  let cacheReadPer = entry["cache_read_input_token_cost"] as? Double,
                  let cacheCreationPer = entry["cache_creation_input_token_cost"] as? Double
            else { continue }
            let base = inputPer * 1_000_000
            // Last-write-wins for duplicate normalized names — prices are
            // identical across the duplicates so this is safe.
            result[normalized] = Pricing.Rates(
                base: base,
                cacheWrite5m: cacheCreationPer * 1_000_000,
                cacheWrite1h: base * 2.0,  // not in LiteLLM; derived per Anthropic docs
                cacheRead: cacheReadPer * 1_000_000,
                output: outputPer * 1_000_000
            )
        }
        return result
    }
}
