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

    private static let currentSchemaVersion: Int = 1
    private static let log = OSLog(subsystem: "net.farriswheel.Pits", category: "SnapshotCache")

    init(fileURL: URL, debounceInterval: TimeInterval = 2.0) {
        self.fileURL = fileURL
        self.debounceInterval = debounceInterval
    }

    /// Synchronous load. Returns nil for missing file, decode failure, or
    /// schema mismatch — callers do not care why the cache is unavailable.
    func load() -> PersistedState? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        // Ensure parent directory exists (Caches dir is normally present).
        let parent = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Debounced write. Multiple calls within `debounceInterval` collapse
    /// into one — only the last `state` is written.
    func scheduleSave(_ state: PersistedState) {
        queue.async {
            self.pendingWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                do {
                    try self.saveNow(state)
                } catch {
                    os_log("snapshot cache write failed: %{public}@", log: Self.log, type: .error, String(describing: error))
                }
            }
            self.pendingWorkItem = item
            self.queue.asyncAfter(deadline: .now() + self.debounceInterval, execute: item)
        }
    }
}
