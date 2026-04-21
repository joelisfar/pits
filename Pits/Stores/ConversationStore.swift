import Foundation
import SwiftUI
import Combine

@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []
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
        // parser.onSessionUpdated is intentionally left unassigned — we rebuild
        // exactly once per batch in handleLines, making per-turn callbacks redundant.
    }

    func start() {
        // Anything with a timestamp after this moment is "new" — anything
        // loaded during backfill is historical and does not chime.
        chimeCutoff = Date()
        // Start live watching + the 1 Hz timer on main — both are non-blocking.
        watcher.start()
        startTimer()
        // Backfill reads every JSONL under ~/.claude/projects/ and can take
        // many seconds on heavy users. Run it off the main thread so the UI
        // is responsive immediately; lines will stream in via watcher.onLine
        // (which already hops back to main).
        let w = watcher
        DispatchQueue.global(qos: .userInitiated).async {
            w.backfill()
        }
    }

    func stop() {
        watcher.stop()
        tickTimer?.invalidate()
        tickTimer = nil
    }

    func rebuildSnapshot() {
        var result: [Conversation] = []
        for sid in parser.sessionIds() {
            let turns = parser.turns(sessionId: sid)
            let url = fileBySession[sid] ?? URL(fileURLWithPath: "/dev/null")
            let projectName = Conversation.projectName(from: url)
            result.append(Conversation(
                id: sid, projectName: projectName, title: parser.title(sessionId: sid),
                filePath: url, turns: turns, ttlSeconds: ttlSeconds
            ))
        }
        result.sort { $0.lastActivityTimestamp > $1.lastActivityTimestamp }
        conversations = result
    }

    // MARK: - Testing hooks

    func ingestForTesting(url: URL, line: String) {
        handleLines(url: url, lines: [line])
    }

    func ingestBatchForTesting(url: URL, lines: [String]) {
        handleLines(url: url, lines: lines)
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
        rebuildSnapshot()
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
