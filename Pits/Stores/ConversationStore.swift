import Foundation
import SwiftUI
import Combine

@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []
    /// True while the initial backfill is still running. UI uses this to show
    /// a loading state instead of the "no conversations" empty view.
    @Published private(set) var isLoading: Bool = false
    /// How many days back we've loaded (1 = today only). `loadMoreDays()`
    /// bumps this; the watcher's mtime range is derived from it.
    @Published private(set) var daysLoaded: Int
    /// Number of additional one-day chunks still queued for progressive load.
    /// Drives the chain of loads that runs each day sequentially so the UI
    /// gets a visible step per day instead of one long wait at the end.
    @Published private(set) var pendingLoadDays: Int = 0
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
        self.daysLoaded = pruned?.daysLoaded ?? 1

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
                // If the user requested a multi-day load, queue the next
                // one-day chunk so each day pops in individually instead of
                // the whole batch landing at the end.
                if self.pendingLoadDays > 0 {
                    self.pendingLoadDays -= 1
                    self.runOneDayChunk()
                } else {
                    self.isLoading = false
                }
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
            daysLoaded: state.daysLoaded,
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
        // Anything with a timestamp after this moment is "new" — anything
        // loaded during backfill is historical and does not chime.
        chimeCutoff = Date()
        isLoading = true
        // Cold launch (daysLoaded == 1, no cache hit): progressive 6-day
        // chain. Warm launch: daysLoaded already reflects the user's loaded
        // window — just reconcile once.
        pendingLoadDays = (daysLoaded == 1) ? 6 : 0
        watcher.mtimeRange = Self.cutoffDate(daysBack: daysLoaded)..<Date.distantFuture
        // Start live watching + the 1 Hz timer on main — both are non-blocking.
        watcher.start()
        startTimer()
        let w = watcher
        DispatchQueue.global(qos: .userInitiated).async {
            w.backfill()
        }
    }

    /// Extend the loaded window by `n` days. Loads proceed *one day at a
    /// time* so the list visibly grows day-by-day instead of beach-balling
    /// until all `n` days arrive together. Each chunk triggers its own
    /// `rebuildSnapshot()` via `onRescanComplete`.
    func loadMoreDays(_ n: Int = 7) {
        guard n > 0 else { return }
        isLoading = true
        pendingLoadDays = n - 1
        runOneDayChunk()
    }

    /// Extend the mtime window by exactly one more day and kick the watcher.
    /// Called recursively via `onRescanComplete` while `pendingLoadDays > 0`.
    private func runOneDayChunk() {
        daysLoaded += 1
        watcher.mtimeRange = Self.cutoffDate(daysBack: daysLoaded)..<Date.distantFuture
        let w = watcher
        DispatchQueue.global(qos: .userInitiated).async {
            w.backfill()
        }
    }

    private static func cutoffDate(daysBack: Int) -> Date {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        return cal.date(byAdding: .day, value: -(daysBack - 1), to: startOfToday) ?? startOfToday
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
                id: sid, projectName: projectName, title: parser.title(sessionId: sid),
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
            daysLoaded: daysLoaded,
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
        watcher.mtimeRange = Self.cutoffDate(daysBack: max(1, daysLoaded))..<Date.distantFuture
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
