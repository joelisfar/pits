import SwiftUI

@main
struct PitsApp: App {
    @StateObject private var store: ConversationStore
    @AppStorage(SoundManager.soundsEnabledKey) private var soundsEnabled: Bool = true

    init() {
        let ttl = UserDefaults.standard.object(forKey: "net.farriswheel.Pits.ttlSeconds") as? Double ?? 300
        let root = URL(fileURLWithPath: NSString(string: "~/.claude/projects").expandingTildeInPath)
        _store = StateObject(wrappedValue: ConversationStore(rootDirectory: root, ttlSeconds: ttl))
    }

    var body: some Scene {
        WindowGroup("Pits", id: "pits-main") {
            ConversationListView(store: store)
                .onAppear {
                    // Skip starting the live watcher when running under XCTest —
                    // backfilling ~/.claude/projects/ on the main thread during
                    // test-host launch blocks the XCTest runner attach.
                    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
                    store.start()
                }
                .onDisappear { store.stop() }
        }
        .defaultSize(width: 480, height: 360)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView(store: store)
        }
    }
}
