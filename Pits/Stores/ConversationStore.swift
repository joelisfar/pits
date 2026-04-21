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
    /// bumps this; the watcher's `minMtime` is derived from it.
    @Published private(set) var daysLoaded: Int = 1
    /// Number of additional one-day chunks still queued for progressive load.
    /// Drives the chain of loads that runs each day sequentially so the UI
    /// gets a visible step per day instead of one long wait at the end.
    @Published private(set) var pendingLoadDays: Int = 0
    @Published var ttlSeconds: TimeInterval {
        didSet { rebuildSnapshot() }
    }

    var onNewTurn: ((Turn) -> Void)?

    private let rootDirectory: URL
    private let parser = LogParser()
    private let watcher: LogWatcher
    private let cacheTimer = CacheTimer()
    private let sound: SoundManager
    private var fileBySession: [String: URL] = [:]
    private var tickTimer: Timer?
    /// Turns with a timestamp strictly greater than this chime.
    /// Before `start()` is called, it is `.distantFuture` so ingested lines
    /// in tests never chime. `start()` sets it to the real launch time.
    private var chimeCutoff: Date = .distantFuture

    init(
        rootDirectory: URL,
        ttlSeconds: TimeInterval,
        sound: SoundManager = SoundManager()
    ) {
        self.rootDirectory = rootDirectory
        self.ttlSeconds = ttlSeconds
        self.sound = sound
        self.watcher = LogWatcher(rootDirectory: rootDirectory)
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
    }

    func start() {
        // Anything with a timestamp after this moment is "new" — anything
        // loaded during backfill is historical and does not chime.
        chimeCutoff = Date()
        isLoading = true
        // Initial load: today plus the previous 6 days, delivered
        // progressively one day at a time so the list pops in as each day
        // finishes instead of waiting for the whole week at the end.
        pendingLoadDays = 6
        watcher.minMtime = Self.cutoffDate(daysBack: daysLoaded)
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
        watcher.minMtime = Self.cutoffDate(daysBack: daysLoaded)
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
