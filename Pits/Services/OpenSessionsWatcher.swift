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
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = obj["sessionId"] as? String else {
                continue
            }
            ids.insert(sid)
        }
        return ids
    }
}
