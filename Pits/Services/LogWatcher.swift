import Foundation
import CoreServices

/// Watches a directory tree for `.jsonl` file changes.
/// Exposes `onLine(url, line)` for every newly appended complete line.
/// Call `backfill()` once at startup to emit every existing line.
/// Call `start()` to begin live watching via FSEvents; `rescan()` is called automatically on events.
final class LogWatcher {
    private let rootDirectory: URL
    private var offsets: [URL: UInt64] = [:]
    private var partials: [URL: Data] = [:]
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "net.farriswheel.Pits.LogWatcher")

    /// Invoked on the LogWatcher's internal serial queue once per
    /// `readNewBytes(from:)` call with all complete lines discovered in that
    /// pass (per-file, per-rescan batching). Not invoked with an empty array.
    /// Hop to another queue if your handler may re-enter the watcher —
    /// calling `rescan()` or `backfill()` from within `onLines` will deadlock.
    var onLines: ((URL, [String]) -> Void)?

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
    }

    deinit { stop() }

    // MARK: - Public API

    /// Read every line from every discovered JSONL file from its current offset.
    func backfill() {
        queue.sync { self.rescanLocked() }
    }

    /// Re-scan all discovered JSONL files for newly appended data.
    /// Safe to call from the FSEvents callback or manually in tests.
    func rescan() {
        queue.sync { self.rescanLocked() }
    }

    func start() {
        guard stream == nil else { return }
        let cfPaths = [rootDirectory.path] as CFArray
        // Retained pointer: the FSEventStream system holds a strong reference
        // for the stream's lifetime, and releases it via the `release` callback
        // when the stream is invalidated. This prevents a race between a
        // late-arriving callback and `deinit`.
        let retainedInfo = Unmanaged.passRetained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: retainedInfo,
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<LogWatcher>.fromOpaque(info).release()
            },
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<LogWatcher>.fromOpaque(info).takeUnretainedValue()
            // Callback is already dispatched to `queue` via
            // FSEventStreamSetDispatchQueue(_, queue), so invoke the locked
            // work directly. Calling `rescan()` here would deadlock
            // (queue.sync from queue).
            watcher.rescanLocked()
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            cfPaths,
            UInt64(kFSEventStreamEventIdSinceNow),
            0.5,  // latency: 500ms coalescing
            flags
        ) else {
            // Balance the `passRetained` on the failure path so we don't leak.
            Unmanaged<LogWatcher>.fromOpaque(retainedInfo).release()
            return
        }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }

    // MARK: - Private

    private func rescanLocked() {
        let files = discoverFiles()
        for url in files {
            readNewBytes(from: url)
        }
    }

    private func discoverFiles() -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        // The enumerator may resolve symlinks (e.g. /var -> /private/var on macOS),
        // producing URLs that differ lexically from the configured rootDirectory.
        // Re-base each result onto the configured root so callers see URLs that
        // match URLs they construct from the same rootDirectory.
        let resolvedRoot = rootDirectory.resolvingSymlinksInPath().path
        let configuredRoot = rootDirectory.path

        var results: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let resolvedPath = url.resolvingSymlinksInPath().path
            if resolvedPath.hasPrefix(resolvedRoot + "/") {
                let suffix = String(resolvedPath.dropFirst(resolvedRoot.count + 1))
                results.append(URL(fileURLWithPath: configuredRoot).appendingPathComponent(suffix))
            } else {
                results.append(url)
            }
        }
        return results
    }

    private func readNewBytes(from url: URL) {
        let offset = offsets[url] ?? 0
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: offset)
        } catch {
            // File shrunk (rotated?) — restart from 0.
            offsets[url] = 0
            partials[url] = nil
            return
        }

        let newBytes = (try? handle.readToEnd()) ?? Data()
        guard !newBytes.isEmpty else { return }

        let newEnd = (try? handle.offset()) ?? (offset + UInt64(newBytes.count))
        offsets[url] = newEnd

        var buffer = partials[url] ?? Data()
        buffer.append(newBytes)

        // Split on \n. Keep trailing partial (if any) in the buffer.
        let nl: UInt8 = 0x0A
        var lines: [Data] = []
        var start = buffer.startIndex
        for i in buffer.indices where buffer[i] == nl {
            lines.append(buffer[start..<i])
            start = buffer.index(after: i)
        }
        let trailing = Data(buffer[start..<buffer.endIndex])
        partials[url] = trailing.isEmpty ? nil : trailing

        var emitted: [String] = []
        for lineData in lines {
            if let raw = String(data: lineData, encoding: .utf8) {
                // Tolerate CRLF endings by stripping a trailing \r.
                let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
                if !line.isEmpty { emitted.append(line) }
            }
        }
        if !emitted.isEmpty {
            onLines?(url, emitted)
        }
    }
}
