import Foundation
import os.log

/// Persists `PersistedState` to a single JSON file. Reads are synchronous
/// (called once at store init). Writes go through a debounced scheduler so
/// bursts of FSEvents don't hammer the disk.
final class SnapshotCache {
    private let fileURL: URL
    private let debounceInterval: TimeInterval
    private let queue = DispatchQueue(label: "net.farriswheel.Pits.SnapshotCache")
    private var pendingWorkItem: DispatchWorkItem?

    // v4: HumanTurn gained an optional `text` preview for the row-title
    // fallback. Optional-Codable would technically decode v3 caches, but
    // we bump so existing sessions get re-parsed from byte zero and the
    // preview backfills retroactively.
    // v3: removed PersistedState.daysLoaded (month scope replaces the
    // rolling-day window). Old caches mismatch the version and get
    // discarded silently; next launch rebuilds from JSONL.
    static let currentSchemaVersion: Int = 4
    private static let log = OSLog(subsystem: "net.farriswheel.Pits", category: "SnapshotCache")

    init(fileURL: URL, debounceInterval: TimeInterval = 2.0) {
        self.fileURL = fileURL
        self.debounceInterval = debounceInterval
    }

    /// Synchronous load. Returns nil for missing file, decode failure, or
    /// schema mismatch — callers do not care why the cache is unavailable.
    func load() -> PersistedState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        // One-shot tighten of pre-existing cache files written before the
        // 0600 convention landed. Idempotent: if already 0600, no-op.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let state = try? decoder.decode(PersistedState.self, from: data) else { return nil }
        guard state.schemaVersion == Self.currentSchemaVersion else { return nil }
        return state
    }

    /// Immediate atomic write. Cancels any pending debounce.
    func saveNow(_ state: PersistedState) throws {
        queue.sync {
            pendingWorkItem?.cancel()
            pendingWorkItem = nil
        }
        try writeToDisk(state)
    }

    /// Debounced write. Multiple calls within `debounceInterval` collapse
    /// into one — only the last `state` is written.
    func scheduleSave(_ state: PersistedState) {
        queue.async {
            self.pendingWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                // Already on `queue` here — call writeToDisk directly so we
                // don't re-enter via saveNow's queue.sync (would deadlock).
                do {
                    try self.writeToDisk(state)
                } catch {
                    os_log("snapshot cache write failed: %{public}@", log: Self.log, type: .error, String(describing: error))
                }
                self.pendingWorkItem = nil
            }
            self.pendingWorkItem = item
            self.queue.asyncAfter(deadline: .now() + self.debounceInterval, execute: item)
        }
    }

    private func writeToDisk(_ state: PersistedState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        // Ensure parent directory exists (Caches dir is normally present).
        let parent = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        // Restrict to user-only read/write — cache contains user-message
        // previews; a 0644 file at ~/Library/Caches/state.json leaks chat
        // history to anyone reading the home dir (backups, shared accounts,
        // accidental chmod -R, etc.). Atomic write inherits umask (typically
        // 0644); chmod afterward to lock it down. Best-effort: ignore errors.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
