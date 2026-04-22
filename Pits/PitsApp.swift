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

        // Hydrate Pricing.table from the on-disk LiteLLM snapshot before
        // the store builds its first snapshot, so totals render with
        // fetched rates on warm launches.
        if let snap = PricingCache.load(from: PricingCache.defaultURL) {
            Pricing.overlay(snap.rates)
        }

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

        // Refresh from LiteLLM in the background. If the on-disk snapshot
        // is older than 24h (or missing), refetch and persist; the new
        // rates get overlaid and the store rebuilds so visible totals
        // update without restarting the app.
        Task.detached(priority: .background) { [weak s] in
            let cacheURL = PricingCache.defaultURL
            let cached = PricingCache.load(from: cacheURL)
            let isStale = cached.map { Date().timeIntervalSince($0.fetchedAt) > 86_400 } ?? true
            guard isStale else { return }
            let fetched = await RemotePricing.fetch()
            guard !fetched.isEmpty else { return }
            try? PricingCache.save(rates: fetched, fetchedAt: Date(), to: cacheURL)
            await MainActor.run {
                Pricing.overlay(fetched)
                s?.rebuildSnapshot()
            }
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
