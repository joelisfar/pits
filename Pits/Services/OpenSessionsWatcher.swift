import Foundation

/// Reads `~/.claude/sessions/*.json` to determine which Claude Code sessions
/// are currently alive. Claude Code writes one JSON file per live process
/// (PID-named) and removes it when the tab/terminal closes, so the set of
/// files is a reliable open-tab signal — more reliable than PID-liveness,
/// because the VS Code extension spawns the `claude` binary per-turn and
/// between turns no process for the session exists.
struct OpenSessionsWatcher {
    let sessionsDirectory: URL

    static let defaultSessionsDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/sessions")

    init(sessionsDirectory: URL = OpenSessionsWatcher.defaultSessionsDirectory) {
        self.sessionsDirectory = sessionsDirectory
    }

    /// Scan the sessions directory and return the set of sessionIds declared
    /// by live Claude Code processes. Missing directory → empty set. Corrupt
    /// files or files missing `sessionId` are silently skipped.
    ///
    /// Claude Code can be mid-rewrite of a session JSON when we read it
    /// (writes are not atomic, so a partial-truncated file is observable).
    /// If a file exists but the first parse fails, retry once after a tiny
    /// sleep — the most common race window is a few ms wide. Without this,
    /// a single tick mis-classifies a live session as closed, potentially
    /// suppressing a chime that should have fired right at a TTL threshold.
    func openSessionIds() -> Set<String> {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: sessionsDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var ids: Set<String> = []
        for url in contents where url.pathExtension == "json" {
            if let sid = readSessionId(at: url) {
                ids.insert(sid)
                continue
            }
            // First parse failed but the file still exists. Retry once after
            // a brief pause — the typical race is the writer truncating the
            // file before refilling. 5 ms is enough for most rewrites.
            if fm.fileExists(atPath: url.path) {
                Thread.sleep(forTimeInterval: 0.005)
                if let sid = readSessionId(at: url) {
                    ids.insert(sid)
                }
            }
        }
        return ids
    }

    private func readSessionId(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sid = obj["sessionId"] as? String else {
            return nil
        }
        return sid
    }
}
