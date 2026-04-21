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
        self.watcher.onLine = { [weak self] url, line in
            DispatchQueue.main.async { self?.handleLine(url: url, line: line) }
        }
        self.parser.onSessionUpdated = { [weak self] _ in
            DispatchQueue.main.async { self?.rebuildSnapshot() }
        }
    }

    func start() {
        // Anything with a timestamp after this moment is "new" — anything
        // loaded during backfill is historical and does not chime.
        chimeCutoff = Date()
        watcher.backfill()
        watcher.start()
        startTimer()
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
                id: sid, projectName: projectName, filePath: url,
                turns: turns, ttlSeconds: ttlSeconds
            ))
        }
        result.sort { $0.lastActivityTimestamp > $1.lastActivityTimestamp }
        conversations = result
    }

    // MARK: - Testing hook

    func ingestForTesting(url: URL, line: String) {
        handleLine(url: url, line: line)
    }

    // MARK: - Private

    private func handleLine(url: URL, line: String) {
        if let entry = JSONLDecoder.decode(line: line) {
            let sid: String
            switch entry {
            case .turn(let t): sid = t.sessionId
            case .human(let h): sid = h.sessionId
            }
            if fileBySession[sid] == nil { fileBySession[sid] = url }
            if case .turn(let t) = entry, t.timestamp > chimeCutoff {
                sound.playMessageReceived()
                onNewTurn?(t)
            }
        }
        parser.ingest(line: line)
        rebuildSnapshot()
    }

    private func startTimer() {
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
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
