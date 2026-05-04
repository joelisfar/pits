import SwiftUI
import AppKit
import Combine

/// Bridges the AppKit-owned `NSStatusItem` to the SwiftUI world: holds a weak
/// reference to the store the AppDelegate observes, and the `openWindow`
/// closure a hidden SwiftUI view installs so a status-item click can open the
/// main window without a MenuBarExtra menu.
@MainActor
final class MenuBarRouter {
    static let shared = MenuBarRouter()
    weak var store: ConversationStore?
    var openMainWindow: (() -> Void)?
    weak var updater: UpdaterModel?
}

/// Owns the menu bar `NSStatusItem`. We can't use `MenuBarExtra` here because
/// its label ignores `.foregroundStyle` (renders as template) and it forces a
/// menu/popover on click — we want a raw click action with a tintable symbol.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(statusItemClicked)
        }
        statusItem = item

        if let store = MenuBarRouter.shared.store {
            store.objectWillChange
                .sink { [weak self] in
                    Task { @MainActor in self?.refreshIcon() }
                }
                .store(in: &cancellables)
        }
        refreshIcon()
    }

    @objc private func statusItemClicked() {
        NSApp.activate(ignoringOtherApps: true)
        MenuBarRouter.shared.openMainWindow?()
    }

    /// Called from PitsApp's onAppear after MenuBarRouter.shared.updater has
    /// been set. Re-renders the status icon when updater state changes (e.g.
    /// `updateAvailable` flipping true on `didFindValidUpdate`).
    func subscribeToUpdater(_ updater: UpdaterModel) {
        updater.objectWillChange
            .sink { [weak self] in
                Task { @MainActor in self?.refreshIcon() }
            }
            .store(in: &cancellables)
        refreshIcon()
    }

    private func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let state = MenuBarRouter.shared.store?.menuBarIconState(at: Date()) ?? .idle
        let updateAvailable = MenuBarRouter.shared.updater?.updateAvailable ?? false

        guard let base = NSImage(systemSymbolName: "flame.fill",
                                 accessibilityDescription: "Pits") else { return }
        let baseImage: NSImage
        switch state {
        case .idle:
            base.isTemplate = true
            baseImage = base
        case .active:
            baseImage = Self.tinted(base, color: .systemOrange)
        case .warning:
            baseImage = Self.tinted(base, color: .systemRed)
        }

        button.image = updateAvailable ? Self.withUpdateDot(baseImage) : baseImage
    }

    /// Returns a non-template copy of `image` tinted with `color` via a
    /// palette symbol configuration — the reliable way to get a colored SF
    /// Symbol in the menu bar.
    private static func tinted(_ image: NSImage, color: NSColor) -> NSImage {
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        let out = image.withSymbolConfiguration(config) ?? image
        out.isTemplate = false
        return out
    }

    /// Composes a small blue dot on the bottom-right of `image` to indicate an
    /// available update. Drawn at runtime so it scales with the menu bar's
    /// thickness preference.
    private static func withUpdateDot(_ image: NSImage) -> NSImage {
        let size = image.size
        let dotDiameter = max(4, size.width * 0.32)
        let composite = NSImage(size: size)
        composite.lockFocus()
        defer { composite.unlockFocus() }
        image.draw(in: NSRect(origin: .zero, size: size))
        NSColor.systemBlue.setFill()
        let dotRect = NSRect(
            x: size.width - dotDiameter,
            y: 0,
            width: dotDiameter,
            height: dotDiameter
        )
        NSBezierPath(ovalIn: dotRect).fill()
        composite.isTemplate = false
        return composite
    }
}

@main
struct PitsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: ConversationStore
    @StateObject private var updater = UpdaterModel()
    @AppStorage(SoundManager.soundsEnabledKey) private var soundsEnabled: Bool = true

    init() {
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

        let s = ConversationStore(rootDirectory: root, cache: cache)
        _store = StateObject(wrappedValue: s)

        // Hand the store to the menu bar router before the AppDelegate's
        // applicationDidFinishLaunching runs so the icon gets wired up and
        // can subscribe to store changes from the first tick.
        MenuBarRouter.shared.store = s

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
        // `Window` (singleton) rather than `WindowGroup`: the status-item
        // click calls `openWindow(id:)`, which on a `WindowGroup` creates a
        // new window each time. `Window` brings the existing instance
        // forward, which is the behavior we want.
        Window("Pits", id: "pits-main") {
            ConversationListView(store: store, updater: updater)
                .onAppear {
                    // Skip starting the live watcher when running under XCTest —
                    // backfilling ~/.claude/projects/ on the main thread during
                    // test-host launch blocks the XCTest runner attach.
                    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
                    store.start()
                    updater.attachDelegate()
                    MenuBarRouter.shared.updater = updater
                    if let delegate = NSApp.delegate as? AppDelegate {
                        delegate.subscribeToUpdater(updater)
                    }
                }
                .onDisappear { store.stop() }
                .background(OpenWindowInstaller())
        }
        .defaultSize(width: 580, height: 420)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView(updater: updater)
        }
    }
}

/// Zero-size helper that captures SwiftUI's `openWindow` action and publishes
/// it to `MenuBarRouter` so the AppKit status-item click can re-open the
/// window after it's been closed.
private struct OpenWindowInstaller: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                MenuBarRouter.shared.openMainWindow = {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "pits-main")
                }
            }
    }
}
