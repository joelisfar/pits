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

        // Save before quit — WindowGroup.onDisappear is unreliable for app
        // termination, so we observe the canonical AppKit notification.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak s] _ in
            s?.stop()
        }
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
        .defaultSize(width: 580, height: 420)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra("Pits", systemImage: "flame.fill") {
            MenuBarContent()
        }

        Settings {
            SettingsView(store: store)
        }
    }
}

/// Menu shown by the menu bar flame icon. Lives in its own view so it has
/// access to `@Environment(\.openWindow)` for the "Open Pits" action.
private struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Pits") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "pits-main")
        }
        .keyboardShortcut("o")

        Divider()

        Button("Quit Pits") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
