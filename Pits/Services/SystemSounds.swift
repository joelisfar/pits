import Foundation

/// Enumerates installed macOS system sounds. Default location is
/// `/System/Library/Sounds`. Callers pass a custom directory only in tests.
enum SystemSounds {
    static let systemDirectory = URL(fileURLWithPath: "/System/Library/Sounds")

    /// Names of installed sounds (extension stripped, sorted alphabetically).
    static var available: [String] { enumerate(at: systemDirectory) }

    static func enumerate(at directory: URL) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names
            .filter { ($0 as NSString).pathExtension.lowercased() == "aiff" }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
    }
}
