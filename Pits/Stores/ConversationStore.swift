import Foundation
import SwiftUI
import Combine

/// Single source of truth for the UI. Owns the LogParser, the LogWatcher,
/// and the derived `[Conversation]` snapshot.
@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []
    @Published var ttlSeconds: TimeInterval {
        didSet { rebuildSnapshot() }
    }

    /// Called once per newly appended assistant turn (used by SoundManager for chimes).
    var onNewTurn: ((Turn) -> Void)?

    private let rootDirectory: URL
    private let parser = LogParser()
    private let watcher: LogWatcher
    /// Maps sessionId → the JSONL URL that backs it (first seen wins).
    private var fileBySession: [String: URL] = [:]

    init(rootDirectory: URL, ttlSeconds: TimeInterval) {
        self.rootDirectory = rootDirectory
        self.ttlSeconds = ttlSeconds
        self.watcher = LogWatcher(rootDirectory: rootDirectory)
        self.watcher.onLine = { [weak self] url, line in
            DispatchQueue.main.async {
                self?.handleLine(url: url, line: line)
            }
        }
        self.parser.onSessionUpdated = { [weak self] _ in
            // Coalesce via runloop — rebuildSnapshot() already does full resort.
            DispatchQueue.main.async { self?.rebuildSnapshot() }
        }
    }

    func start() {
        watcher.backfill()
        watcher.start()
    }

    func stop() {
        watcher.stop()
    }

    /// Force a snapshot rebuild (used by the 1 Hz timer and when TTL changes).
    func rebuildSnapshot() {
        var result: [Conversation] = []
        for sid in parser.sessionIds() {
            let turns = parser.turns(sessionId: sid)
            let url = fileBySession[sid] ?? URL(fileURLWithPath: "/dev/null")
            let projectName = Conversation.projectName(from: url)
            result.append(Conversation(
                id: sid,
                projectName: projectName,
                filePath: url,
                turns: turns,
                ttlSeconds: ttlSeconds
            ))
        }
        result.sort { $0.lastActivityTimestamp > $1.lastActivityTimestamp }
        conversations = result
    }

    // MARK: - Testing hook

    /// Lets tests feed a line directly without touching the watcher.
    func ingestForTesting(url: URL, line: String) {
        handleLine(url: url, line: line)
    }

    // MARK: - Private

    private func handleLine(url: URL, line: String) {
        // Capture which file a session lives in (first line wins).
        if let entry = JSONLDecoder.decode(line: line) {
            let sid: String
            switch entry {
            case .turn(let t): sid = t.sessionId
            case .human(let h): sid = h.sessionId
            }
            if fileBySession[sid] == nil {
                fileBySession[sid] = url
            }
            if case .turn(let t) = entry {
                onNewTurn?(t)
            }
        }
        parser.ingest(line: line)
        rebuildSnapshot()
    }
}
