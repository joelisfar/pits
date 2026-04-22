import Foundation

/// On-disk cache of the LiteLLM-derived rates so we don't refetch on every
/// launch. One file at `~/Library/Caches/pricing.json`. TTL is enforced by
/// the caller, not the cache itself — `load()` always returns the file and
/// the caller decides whether `fetchedAt` is stale.
enum PricingCache {
    struct Snapshot: Codable, Equatable {
        let rates: [String: Pricing.Rates]
        let fetchedAt: Date
    }

    /// Default file location. Sandboxed apps land at the same spot inside
    /// the container — `urls(for:.cachesDirectory, in:.userDomainMask)`
    /// returns the right path either way.
    static var defaultURL: URL {
        FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("pricing.json")
    }

    static func save(rates: [String: Pricing.Rates], fetchedAt: Date, to url: URL) throws {
        let snap = Snapshot(rates: rates, fetchedAt: fetchedAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snap)
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    static func load(from url: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }
}
