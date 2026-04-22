import SwiftUI
import AppKit

@main
struct PitsApp: App {
    @StateObject private var store: ConversationStore
    @AppStorage(SoundManager.soundsEnabledKey) private var soundsEnabled: Bool = true

    init() {
        let ttl = UserDefaults.standard.object(forKey: "net.farriswheel.Pits.ttlSeconds") as? Double ?? 300
        let root = URL(fileURLWithPath: NSString(string: "~/.claude/projects").expandingTildeInPath)
        let cacheURL = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("state.json")
        let cache = SnapshotCache(fileURL: cacheURL)
        let s = ConversationStore(rootDirectory: root, ttlSeconds: ttl, cache: cache)
        _store = StateObject(wrappedValue: s)

        // Save before quit. With LSUIElement = true and a MenuBarExtra scene
        // there's no window lifecycle, so willTerminate is the only reliable
        // signal that the app is going away.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak s] _ in
            s?.stop()
        }
    }

    var body: some Scene {
        MenuBarExtra("Pits", systemImage: "flame.fill") {
            ConversationListView(store: store)
                .frame(width: 460, height: 520)
                .onAppear {
                    // Skip starting the live watcher when running under XCTest —
                    // backfilling ~/.claude/projects/ on the main thread during
                    // test-host launch blocks the XCTest runner attach.
                    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
                    store.start()
                }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }
}
