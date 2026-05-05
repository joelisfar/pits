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

    /// When set, `discoverFiles()` only returns JSONL files whose mtime falls
    /// in the half-open range. Files we've already started reading are kept
    /// regardless so live appends aren't lost. Thread-safe: read/written on `queue`.
    private var _mtimeRange: Range<Date>?
    var mtimeRange: Range<Date>? {
        get { queue.sync { _mtimeRange } }
        set { queue.sync { _mtimeRange = newValue } }
    }

    /// Invoked on the LogWatcher's internal serial queue once per
    /// `readNewBytes(from:)` call with all complete lines discovered in that
    /// pass (per-file, per-rescan batching). Not invoked with an empty array.
    /// Hop to another queue if your handler may re-enter the watcher —
    /// calling `rescan()` or `backfill()` from within `onLines` will deadlock.
    var onLines: ((URL, [String]) -> Void)?

    /// Invoked at the end of every `backfill()`/`rescan()` pass, *after* all
    /// `onLines` callbacks for that pass have fired. Useful for consumers that
    /// want to defer an expensive synthesis step (e.g. snapshot rebuild) until
    /// a whole batch of files has been ingested.
    var onRescanComplete: (() -> Void)?

    init(rootDirectory: URL, initialOffsets: [URL: UInt64] = [:]) {
        self.rootDirectory = rootDirectory
        self.offsets = initialOffsets
    }

    deinit {
        // deinit only runs when the LogWatcher's refcount hits zero. With an
        // active FSEventStream, our `Unmanaged.passRetained(self)` keeps a
        // strong ref alive — so `self.stream` is necessarily already nil
        // here (cleared by the explicit `stop()` that triggered the release
        // callback). Calling `_stopUnsafe()` directly handles the start()-
        // never-completed case without queue.sync (which would deadlock if
        // deinit happens to run on `queue`).
        _stopUnsafe()
    }

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
        queue.sync { _stopUnsafe() }
    }

    /// Inner cleanup. NOT queue-synchronized; only safe to call from contexts
    /// where serialization is guaranteed (queue.sync wrapper or deinit).
    private func _stopUnsafe() {
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            stream = nil
        }
    }

    /// Snapshot of file offsets for persistence. Each offset is adjusted to
    /// point *before* any trailing partial line so the partial bytes get
    /// re-read on next launch (avoids needing to persist `partials`).
    func currentOffsetsForPersistence() -> [URL: UInt64] {
        queue.sync {
            var result: [URL: UInt64] = [:]
            for (url, offset) in offsets {
                let partialLen = UInt64(partials[url]?.count ?? 0)
                result[url] = offset >= partialLen ? offset - partialLen : 0
            }
            return result
        }
    }

    // MARK: - Private

    private func rescanLocked() {
        let files = discoverFiles()
        for url in files {
            readNewBytes(from: url)
        }
        onRescanComplete?()
    }

    private func discoverFiles() -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        // The enumerator may resolve symlinks (e.g. /var -> /private/var on macOS),
        // producing URLs that differ lexically from the configured rootDirectory.
        // Re-base each result onto the configured root so callers see URLs that
        // match URLs they construct from the same rootDirectory.
        let resolvedRoot = rootDirectory.resolvingSymlinksInPath().path
        let configuredRoot = rootDirectory.path
        let range = _mtimeRange

        var results: [URL] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            if let range {
                // A file stays in the result set if (a) its mtime is in range,
                // OR (b) we've already read bytes from it (so we keep tracking
                // it for further appends). The latter avoids losing live
                // updates on a file we've already begun ingesting.
                let resolvedForOffsetLookup = url.resolvingSymlinksInPath().path
                let reboasedForOffsetLookup: URL
                if resolvedForOffsetLookup.hasPrefix(resolvedRoot + "/") {
                    let suffix = String(resolvedForOffsetLookup.dropFirst(resolvedRoot.count + 1))
                    reboasedForOffsetLookup = URL(fileURLWithPath: configuredRoot).appendingPathComponent(suffix)
                } else {
                    reboasedForOffsetLookup = url
                }
                let alreadyTracked = offsets[reboasedForOffsetLookup] != nil
                if !alreadyTracked {
                    let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate
                    if let mtime, !range.contains(mtime) { continue }
                }
            }
            let resolvedPath = url.resolvingSymlinksInPath().path
            if resolvedPath.hasPrefix(resolvedRoot + "/") {
                let suffix = String(resolvedPath.dropFirst(resolvedRoot.count + 1))
                results.append(URL(fileURLWithPath: configuredRoot).appendingPathComponent(suffix))
            } else {
                // Symlink escape: a `.jsonl` reachable via a symlink chain
                // that resolves outside `rootDirectory`. Skip — Pits should
                // only ingest content the user actually placed under
                // `~/.claude/projects/` (defense in depth; not a real attack
                // path on a single-user macOS but trivial to enforce).
                continue
            }
        }
        return results
    }

    /// Maximum bytes pulled from a single file in one rescan pass.
    /// Prevents a multi-gigabyte append (or first backfill of a heavy user's
    /// 100+ session history) from materializing all at once and OOMing the
    /// menu-bar app. Subsequent passes pick up from the new offset.
    private static let maxBytesPerRead: Int = 16 * 1024 * 1024

    /// Maximum size of an unfinished trailing partial line we'll buffer.
    /// A legitimate `tool_result` JSONL line can be 100s of KB; cap higher
    /// than expected, but bound to prevent unbounded growth from a malformed
    /// or malicious file with no newlines.
    private static let maxPartialBytes: Int = 4 * 1024 * 1024

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

        // Read at most `maxBytesPerRead` per call. If more is pending, the
        // FSEvents loop / next rescan picks up the rest. `read(upToCount:)`
        // may return fewer bytes than requested — that's fine; we just
        // process what we got.
        let newBytes = (try? handle.read(upToCount: Self.maxBytesPerRead)) ?? Data()
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
        if trailing.count > Self.maxPartialBytes {
            // Drop runaway partial: a single line bigger than the cap is
            // either corrupt or hostile. Reset state for this file so we
            // can recover on next rescan if the file gets fixed/rotated.
            partials[url] = nil
        } else {
            partials[url] = trailing.isEmpty ? nil : trailing
        }

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
