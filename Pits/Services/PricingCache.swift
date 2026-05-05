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
        // Match SnapshotCache: lock to user-only. Pricing data isn't sensitive
        // on its own, but the convention keeps both caches at 0600 so future
        // additions to either don't have to be re-audited.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func load(from url: URL) -> Snapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        // One-shot tighten of pre-existing cache files (0644 → 0600).
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Snapshot.self, from: data)
    }
}
