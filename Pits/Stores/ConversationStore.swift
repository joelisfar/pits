import Foundation
import SwiftUI
import Combine

@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []
    /// True while a backfill is running (initial or after a month switch).
    @Published private(set) var isLoading: Bool = false
    /// The calendar month currently in scope. Drives both watcher mtime
    /// range and the display-time filter.
    @Published private(set) var selectedMonth: MonthScope = MonthScope.current()
    /// Contiguous descending list of months that have at least one JSONL
    /// in the root directory tree. Computed by `discoverActiveMonths()`.
    @Published private(set) var availableMonths: [MonthScope] = []
    @Published var ttlSeconds: TimeInterval {
        didSet { rebuildSnapshot() }
    }

    var onNewTurn: ((Turn) -> Void)?

    private let rootDirectory: URL
    private let parser: LogParser
    private let watcher: LogWatcher
    private let cacheTimer = CacheTimer()
    private let sound: SoundManager
    private let cache: SnapshotCache?
    private var fileBySession: [String: URL]
    private var tickTimer: Timer?
    /// Turns with a timestamp strictly greater than this chime.
    /// Before `start()` is called, it is `.distantFuture` so ingested lines
    /// in tests never chime. `start()` sets it to the real launch time.
    private var chimeCutoff: Date = .distantFuture

    init(
        rootDirectory: URL,
        ttlSeconds: TimeInterval,
        sound: SoundManager = SoundManager(),
        cache: SnapshotCache? = nil
    ) {
        self.rootDirectory = rootDirectory
        self.ttlSeconds = ttlSeconds
        self.sound = sound
        self.cache = cache

        // Hydrate from cache if present. Pruning rule: drop sessions whose
        // backing JSONL file no longer exists on disk.
        let pruned = cache.flatMap { Self.prune(state: $0.load()) }

        self.parser = LogParser(seed: pruned?.parser)
        self.watcher = LogWatcher(rootDirectory: rootDirectory, initialOffsets: pruned?.offsets ?? [:])
        self.fileBySession = pruned?.fileBySession ?? [:]

        self.watcher.onLines = { [weak self] url, lines in
            DispatchQueue.main.async { self?.handleLines(url: url, lines: lines) }
        }
        // Defer the snapshot rebuild until *all* files in a rescan have been
        // ingested. On heavy users (1000+ JSONL files) this collapses 1000+
        // per-file rebuilds into one per rescan pass.
        self.watcher.onRescanComplete = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.rebuildSnapshot()
                self.isLoading = false
            }
        }

        if pruned != nil {
            // Cache hit — populate `conversations` synchronously so the view
            // appears with the list ready, no spinner.
            rebuildSnapshot()
        }
    }

    /// Filter a hydrated state: drop sessions whose JSONL file no longer
    /// exists on disk (and the matching offsets / parser entries).
    private static func prune(state: PersistedState?) -> PersistedState? {
        guard let state else { return nil }
        let fm = FileManager.default
        var files = state.fileBySession
        var offs = state.offsets
        var droppedSessions: Set<String> = []
        for (sid, url) in state.fileBySession where !fm.fileExists(atPath: url.path) {
            files.removeValue(forKey: sid)
            offs.removeValue(forKey: url)
            droppedSessions.insert(sid)
        }
        var turns = state.parser.turnsByRequestId
        for (rid, turn) in turns where droppedSessions.contains(turn.sessionId) {
            turns.removeValue(forKey: rid)
        }
        var humans = state.parser.humanTurnsBySession
        for sid in droppedSessions { humans.removeValue(forKey: sid) }
        var titles = state.parser.titleBySession
        for sid in droppedSessions { titles.removeValue(forKey: sid) }
        return PersistedState(
            schemaVersion: state.schemaVersion,
            savedAt: state.savedAt,
            fileBySession: files,
            offsets: offs,
            parser: PersistedParser(
                turnsByRequestId: turns,
                humanTurnsBySession: humans,
                titleBySession: titles
            )
        )
    }

    func start() {
        chimeCutoff = Date()
        isLoading = true
        discoverActiveMonths()
        watcher.mtimeRange = selectedMonth.dateRange()
        watcher.start()
        startTimer()
        let w = watcher
        DispatchQueue.global(qos: .userInitiated).async { w.backfill() }
    }

    /// Switch the active month scope. Backfills any not-yet-loaded files in
    /// the new month's range; already-ingested data stays in parser state so
    /// re-selecting a previously-visited month is instant.
    func setSelectedMonth(_ month: MonthScope) {
        guard month != selectedMonth else { return }
        selectedMonth = month
        isLoading = true
        watcher.mtimeRange = month.dateRange()
        let w = watcher
        DispatchQueue.global(qos: .userInitiated).async { w.backfill() }
    }

    /// Scans the root directory for JSONL mtimes once and computes the
    /// contiguous month range from earliest mtime through current month.
    /// Cheap (one stat per file). Sets `availableMonths` to a descending list.
    func discoverActiveMonths() {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: rootDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            availableMonths = [MonthScope.current()]
            return
        }
        var earliest: Date?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            if let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate {
                if earliest == nil || mtime < earliest! {
                    earliest = mtime
                }
            }
        }
        let earliestMonth = earliest.map { MonthScope.from(date: $0) } ?? MonthScope.current()
        availableMonths = MonthScope.range(from: earliestMonth, through: MonthScope.current())
    }

    func stop() {
        if let cache {
            try? cache.saveNow(snapshotState())
        }
        watcher.stop()
        tickTimer?.invalidate()
        tickTimer = nil
    }

    func rebuildSnapshot() {
        // Subagent turns share the parent session's `sessionId` (only the
        // per-line `agentId`/`isSubagent` flag distinguishes them), so one
        // session id → one Conversation whose `turns` already contain both
        // parent and subagent work. Subagent presentation is done in the view
        // layer via `Conversation.subagentTurns`.
        var result: [Conversation] = []
        for sid in parser.sessionIds() {
            let turns = parser.turns(sessionId: sid)
            let humans = parser.humanTurns(sessionId: sid)
            let url = fileBySession[sid] ?? URL(fileURLWithPath: "/dev/null")
            let projectName = Conversation.projectName(from: url)
            result.append(Conversation(
                id: sid, projectName: projectName,
                title: parser.title(sessionId: sid),
                firstMessageText: parser.firstMessageText(sessionId: sid),
                filePath: url, turns: turns, humanTurns: humans, ttlSeconds: ttlSeconds
            ))
        }
        result.sort { $0.lastActivityTimestamp > $1.lastActivityTimestamp }
        conversations = result
        cache?.scheduleSave(snapshotState())
    }

    private func snapshotState() -> PersistedState {
        PersistedState(
            schemaVersion: SnapshotCache.currentSchemaVersion,
            savedAt: Date(),
            fileBySession: fileBySession,
            offsets: watcher.currentOffsetsForPersistence(),
            parser: parser.snapshot()
        )
    }

    // MARK: - Testing hooks

    func ingestForTesting(url: URL, line: String) {
        handleLines(url: url, lines: [line])
        rebuildSnapshot()
    }

    func ingestBatchForTesting(url: URL, lines: [String]) {
        handleLines(url: url, lines: lines)
        rebuildSnapshot()
    }

    func setChimeCutoffForTesting(_ date: Date) {
        chimeCutoff = date
    }

    func snapshotStateForTesting() -> PersistedState {
        snapshotState()
    }

    /// Synchronous reconciliation for tests. Mirrors `start()`'s reconcile
    /// pass without touching FSEvents or async dispatch.
    func reconcileForTesting() {
        chimeCutoff = Date()
        watcher.mtimeRange = selectedMonth.dateRange()
        watcher.backfill()
        // Drain any onLines blocks the watcher dispatched to main.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        rebuildSnapshot()
    }

    // MARK: - Private

    private func handleLines(url: URL, lines: [String]) {
        for line in lines {
            if let entry = JSONLDecoder.decode(line: line) {
                let sid: String
                switch entry {
                case .turn(let t): sid = t.sessionId
                case .human(let h): sid = h.sessionId
                case .title(let st): sid = st.sessionId
                }
                if fileBySession[sid] == nil { fileBySession[sid] = url }
                // Chime only on *final* turns — the ones a human would notice
                // as "Claude is done talking". Intermediate tool_use turns (and
                // streaming fragments with no stop_reason yet) stay silent.
                if case .turn(let t) = entry,
                   t.timestamp > chimeCutoff,
                   let stop = t.stopReason, stop != "tool_use" {
                    sound.playMessageReceived()
                    onNewTurn?(t)
                }
            }
            parser.ingest(line: line)
        }
        // No per-file rebuild: the watcher's onRescanComplete drives a single
        // rebuild at the end of the rescan pass. Tests go through
        // ingestForTesting / ingestBatchForTesting, which explicitly rebuild.
    }

    private func startTimer() {
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // `.common` mode keeps the timer firing during window resize and menu tracking.
        RunLoop.main.add(t, forMode: .common)
        tickTimer = t
    }

    private func tick() {
        let events = cacheTimer.tick(conversations: conversations, at: Date())
        for e in events {
            switch e {
            case .oneMinuteWarning:
                sound.playOneMinuteWarning()
            case .transitionedToCold:
                // Derived values recompute on the next UI tick via
                // TimelineView — no snapshot rebuild required.
                break
            }
        }
        // Force a publish so SwiftUI pulls the latest `conversations` snapshot
        // and any subscribers (like TimelineView consumers) reflect new state.
        objectWillChange.send()
    }
}
