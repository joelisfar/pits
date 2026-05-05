# Release Pipeline Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Pits as a signed, notarized macOS app that auto-updates via Sparkle. All credentialed work runs in GitHub Actions on tag push; local `release.sh` shrinks to a tagging tool. First signed release is `v0.2.0`.

**Architecture:** Sparkle 2.x SwiftPM dep with a thin `UpdaterModel` wrapper. Hardened-runtime release builds signed with Developer ID + notarized via App Store Connect API key. `appcast.xml` (EdDSA-signed by `generate_appcast`) lives at `raw.githubusercontent.com/joelisfar/pits/main/appcast.xml`. GitHub Actions workflow on `v*` tag push does the build/sign/notarize/staple/appcast/publish. Bootstrap (cert + API key + Sparkle keys) is one-time manual setup.

**Tech Stack:** Sparkle 2.6+, SwiftUI/AppKit, xcodegen, xcodebuild, codesign, notarytool, stapler, generate_appcast, GitHub Actions (macos-14).

**Spec:** [docs/superpowers/specs/2026-05-04-release-pipeline-phase2-design.md](../specs/2026-05-04-release-pipeline-phase2-design.md)

---

## Preamble: branch + working tree

This plan executes on the `v0.2.0` branch (already created off `main` at commit `1b6957e` — the spec commit). Per project memory, all in-flight work commits to `v0.2.0`; merge to `main` happens via PR right before tagging. Each task ends with a commit on `v0.2.0`.

```sh
git status                  # should be clean on v0.2.0
git rev-parse --abbrev-ref HEAD   # should print: v0.2.0
```

---

## Spec correction discovered during planning

`project.yml` declares `INFOPLIST_FILE: Pits/Info.plist` and `GENERATE_INFOPLIST_FILE: NO` — meaning Pits uses a hand-edited `Info.plist`, NOT a synthesized one. The spec said to add Sparkle keys "via `project.yml` → `infoPlist`," which doesn't apply here. **Sparkle keys go directly into `Pits/Info.plist` as XML.** Tasks below reflect this.

---

## File Structure

**Create:**
- `Pits/Pits.entitlements` — empty entitlements file (required by hardened runtime)
- `Pits/Updates/UpdaterModel.swift` — `@MainActor ObservableObject` wrapping `SPUStandardUpdaterController`
- `Pits/Updates/CheckForUpdatesView.swift` — SwiftUI button bound to `UpdaterModel.checkForUpdates`
- `RELEASE_NOTES.md` — stanza-per-version, newest first
- `appcast.xml` — stub committed pre-CI; CI overwrites with signed version per release
- `scripts/lib/package_dmg.sh` — DMG packaging extracted from current `release.sh`
- `.github/workflows/release.yml` — full signed-release CI pipeline

**Modify:**
- `project.yml` — add Sparkle SwiftPM dep, signing settings (manual style, hardened runtime, entitlements path)
- `Pits/Info.plist` — add `SUFeedURL`, `SUEnableAutomaticChecks`, `SUScheduledCheckInterval`, `SUPublicEDKey`
- `Pits/PitsApp.swift` — instantiate `UpdaterModel`, pass it to `MenuBarRouter` for icon-dot rendering
- `Pits/Views/ConversationListView.swift` — add update-available indicator in the bottom status row (lines 43–53)
- `Pits/Views/SettingsView.swift` — mount `CheckForUpdatesView`
- `scripts/release.sh` — shrink to preflight + bump + notes-assert + tag + push (drop build/package/publish)

**Delete (functions-only inside `release.sh`):**
- `build_release()`, `package_dmg()`, `publish()` blocks (the latter two move to `scripts/lib/package_dmg.sh` and the workflow respectively)

---

# PART A — Code changes (no Apple credentials needed yet)

### Task 1: Hardened runtime + entitlements file

**Files:**
- Create: `Pits/Pits.entitlements`
- Modify: `project.yml:19-25`

**Why first:** Lets us start signing locally in Task 12 with a coherent runtime config. Entitlements file must exist before xcodebuild can be told to use it. Currently `project.yml` declares `ENABLE_HARDENED_RUNTIME: YES` but no entitlements — that's a config that signs but doesn't lock anything down. We're tightening it.

- [ ] **Step 1: Create empty entitlements file**

Create `Pits/Pits.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
```

Pits doesn't sandbox and doesn't request any specific entitlements; the file exists because hardened runtime requires `CODE_SIGN_ENTITLEMENTS` to be set even when empty.

- [ ] **Step 2: Update `project.yml` signing config**

Replace lines 19–25 (the `Pits` target's `settings.base` block) with:

```yaml
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: net.farriswheel.Pits
        INFOPLIST_FILE: Pits/Info.plist
        ENABLE_HARDENED_RUNTIME: YES
        CODE_SIGN_ENTITLEMENTS: Pits/Pits.entitlements
        # Local Debug builds: ad-hoc sign so the app launches without a Developer ID cert.
        # Release builds: CI passes CODE_SIGN_IDENTITY="Developer ID Application" + DEVELOPMENT_TEAM via xcodebuild flags.
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "-"
```

Key changes from current state: `CODE_SIGN_STYLE` flipped from `Automatic` to `Manual` (so xcodebuild flags actually take effect in CI; with Automatic, Xcode tries to manage profiles and fights the CLI override). `CODE_SIGN_IDENTITY: "-"` (ad-hoc signing) is the local-debug default — CI passes a real identity via xcodebuild command-line flags.

- [ ] **Step 3: Regenerate Xcode project**

```sh
xcodegen generate
```

- [ ] **Step 4: Verify Debug build still works locally**

```sh
bash scripts/run.sh
```

Expected: Pits launches normally (still ad-hoc signed for local dev). If launch fails with a code-signing error, the entitlements file path is wrong.

- [ ] **Step 5: Commit**

```sh
git add Pits/Pits.entitlements project.yml Pits.xcodeproj
git commit -m "feat: hardened runtime entitlements file"
```

---

### Task 2: Add Sparkle SwiftPM dependency

**Files:**
- Modify: `project.yml`

**Why now:** Subsequent Swift tasks (Updater model, views) need to `import Sparkle`. Adding the dep in isolation lets us verify it builds before any wiring exists.

- [ ] **Step 1: Add `packages` block + dep to target**

Add to `project.yml` (before `targets:`):

```yaml
packages:
  Sparkle:
    url: https://github.com/sparkle-project/Sparkle
    from: 2.6.0
```

Then add a `dependencies` list to the `Pits` target (alongside `settings`):

```yaml
  Pits:
    type: application
    platform: macOS
    sources:
      - path: Pits
    dependencies:
      - package: Sparkle
    settings:
      base:
        ...
```

- [ ] **Step 2: Regenerate Xcode project + resolve packages**

```sh
xcodegen generate
xcodebuild -resolvePackageDependencies -project Pits.xcodeproj -scheme Pits
```

Expected: SPM fetches Sparkle. First resolve takes ~10–30s.

- [ ] **Step 3: Verify build succeeds with the import available**

```sh
xcodebuild -project Pits.xcodeproj -scheme Pits -configuration Debug -destination "platform=macOS,arch=$(uname -m)" build 2>&1 | tail -20
```

Expected: `** BUILD SUCCEEDED **`. (Sparkle isn't imported anywhere yet, so build behavior is unchanged — we're just confirming the dep resolves.)

- [ ] **Step 4: Commit**

```sh
git add project.yml Pits.xcodeproj
git commit -m "feat: add Sparkle SwiftPM dependency"
```

---

### Task 3: Create `UpdaterModel`

**Files:**
- Create: `Pits/Updates/UpdaterModel.swift`

- [ ] **Step 1: Create the file**

Create `Pits/Updates/UpdaterModel.swift`:

```swift
import Foundation
import Combine
import Sparkle

/// Bridges Sparkle's `SPUStandardUpdaterController` to SwiftUI by republishing
/// the `canCheckForUpdates` and "update available" state. Owns the updater
/// lifecycle for the app — created once in `PitsApp.init`, held as a
/// `@StateObject`, and consumed by views that need to render an indicator or
/// fire a manual check.
@MainActor
final class UpdaterModel: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates: Bool = false
    @Published private(set) var updateAvailable: Bool = false

    private let controller: SPUStandardUpdaterController
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        // `startingUpdater: true` makes Sparkle begin the scheduled-check timer
        // immediately. Delegate set to self so we can republish state.
        let nilUserDriverDelegate: SPUStandardUserDriverDelegate? = nil
        // Create the controller with self as updater delegate. AppKit retains
        // the controller via the strong reference we hold; Sparkle uses weak
        // refs for delegates so retain cycles aren't a concern.
        let ctl = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nilUserDriverDelegate
        )
        self.controller = ctl
        super.init()

        // Wire delegate after super.init since SPUUpdaterDelegate methods
        // capture self.
        ctl.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &cancellables)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in self.updateAvailable = true }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.updateAvailable = false }
    }
}
```

**Note:** `SPUStandardUpdaterController` accepts a `updaterDelegate:` argument at init — but we set it to `nil` and instead expose the delegate through the controller's `updater` property post-init via assigning `controller.updater.delegate = self` if needed. Sparkle 2.6's API is mid-transition; if the build fails on the delegate-set, fall back to passing `self` to `updaterDelegate:` directly (refactor will require splitting `init` to satisfy the "self before super.init" rule — common pattern is a `start()` method).

- [ ] **Step 2: Wire delegate after init in PitsApp (placeholder, real wiring in Task 5)**

Add to the bottom of `UpdaterModel.swift`:

```swift
extension UpdaterModel {
    /// Called from PitsApp.init after super-style init constraints are
    /// satisfied. Sets the updater's delegate to self so didFindValidUpdate /
    /// updaterDidNotFindUpdate fire.
    func attachDelegate() {
        controller.updater.delegate = self
    }
}
```

- [ ] **Step 3: Verify build**

```sh
xcodebuild -project Pits.xcodeproj -scheme Pits -configuration Debug -destination "platform=macOS,arch=$(uname -m)" build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

If the build fails on `nonisolated func updater(...)`, Sparkle's delegate methods may require `@objc` or a different isolation pattern in this Swift/Sparkle version. The fix is mechanical (add `@objc`, drop `nonisolated`); follow the compiler error.

- [ ] **Step 4: Commit**

```sh
git add Pits/Updates/UpdaterModel.swift Pits.xcodeproj
git commit -m "feat: UpdaterModel wrapping SPUStandardUpdaterController"
```

---

### Task 4: Create `CheckForUpdatesView`

**Files:**
- Create: `Pits/Updates/CheckForUpdatesView.swift`

- [ ] **Step 1: Create the file**

Create `Pits/Updates/CheckForUpdatesView.swift`:

```swift
import SwiftUI

/// "Check for Updates…" button. Disabled while Sparkle is busy (e.g. mid-
/// download). Mounted inside SettingsView so the user has an explicit way to
/// trigger an update check on demand.
struct CheckForUpdatesView: View {
    @ObservedObject var updater: UpdaterModel

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}
```

- [ ] **Step 2: Verify build**

```sh
xcodebuild -project Pits.xcodeproj -scheme Pits -configuration Debug -destination "platform=macOS,arch=$(uname -m)" build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```sh
git add Pits/Updates/CheckForUpdatesView.swift Pits.xcodeproj
git commit -m "feat: CheckForUpdatesView SwiftUI button"
```

---

### Task 5: Wire `UpdaterModel` into `PitsApp` and expose to MenuBarRouter

**Files:**
- Modify: `Pits/PitsApp.swift`

- [ ] **Step 1: Add `updater` to `MenuBarRouter`**

Edit lines 9–14 of `Pits/PitsApp.swift`:

```swift
@MainActor
final class MenuBarRouter {
    static let shared = MenuBarRouter()
    weak var store: ConversationStore?
    var openMainWindow: (() -> Void)?
    weak var updater: UpdaterModel?
}
```

- [ ] **Step 2: Add `@StateObject` updater to `PitsApp`**

In the `PitsApp` struct (around line 76–131), add:

```swift
@main
struct PitsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store: ConversationStore
    @StateObject private var updater = UpdaterModel()    // NEW
    @AppStorage(SoundManager.soundsEnabledKey) private var soundsEnabled: Bool = true
    ...
```

- [ ] **Step 3: Hand the updater to MenuBarRouter in `init`**

In `PitsApp.init()` (around line 102), after `MenuBarRouter.shared.store = s`, add:

```swift
        MenuBarRouter.shared.store = s
        // (the @StateObject wrapped value isn't accessible from init — defer
        //  attaching delegate + router wiring until first body render via
        //  task(.appear) below)
```

Actually, `@StateObject` initial values aren't available in `init()`. The cleanest pattern is to instantiate `UpdaterModel` outside of `init` and pass through. Use:

```swift
    @StateObject private var updater = UpdaterModel()
```

and wire up via a `.task` or `.onAppear` on the main window:

```swift
    var body: some Scene {
        Window("Pits", id: "pits-main") {
            ConversationListView(store: store, updater: updater)
                .onAppear {
                    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
                    store.start()
                    updater.attachDelegate()
                    MenuBarRouter.shared.updater = updater
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
```

`ConversationListView` and `SettingsView` will be modified in Tasks 6 and 7 to accept `updater`. For now this won't compile — that's expected; we're staging the change.

- [ ] **Step 4: Skip build verification (will fail until Tasks 6 + 7 land)**

Note: do NOT try to build between Task 5 and Task 7 — the API change here breaks `ConversationListView` and `SettingsView` initialization. Push through the next two tasks before testing.

- [ ] **Step 5: Commit (broken build, intentional intermediate state)**

```sh
git add Pits/PitsApp.swift Pits.xcodeproj
git commit -m "wip: thread UpdaterModel through PitsApp scene"
```

---

### Task 6: Update indicator in `ConversationListView` status row

**Files:**
- Modify: `Pits/Views/ConversationListView.swift`

**Why this exact spot:** the bottom status row at lines 43–53 already has space for the loading spinner; mutually-exclusive with the update indicator.

- [ ] **Step 1: Add `updater` parameter to `ConversationListView`**

Find the struct declaration (around line 5–10) and add an `@ObservedObject` for the updater:

```swift
struct ConversationListView: View {
    @ObservedObject var store: ConversationStore
    @ObservedObject var updater: UpdaterModel    // NEW
    ...
```

- [ ] **Step 2: Replace the status row's right-side branch (lines 43–53)**

Replace:

```swift
            HStack {
                Text(statusBarText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                }
            }
```

With:

```swift
            HStack {
                Text(statusBarText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if store.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                } else if updater.updateAvailable {
                    Button(action: { updater.checkForUpdates() }) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.blue)
                            .imageScale(.medium)
                    }
                    .buttonStyle(.plain)
                    .help("Update available — click to install")
                }
            }
```

- [ ] **Step 3: Skip build verification (Task 7 still pending)**

The build will fail until Settings is updated.

- [ ] **Step 4: Commit**

```sh
git add Pits/Views/ConversationListView.swift
git commit -m "feat: update-available indicator in status row"
```

---

### Task 7: Mount `CheckForUpdatesView` in Settings

**Files:**
- Modify: `Pits/Views/SettingsView.swift`

- [ ] **Step 1: Read current SettingsView**

```sh
cat Pits/Views/SettingsView.swift
```

Note where it makes sense to slot a "Check for Updates…" button — typically a separate `Section` or at the bottom of the existing form.

- [ ] **Step 2: Add `updater` parameter and the button**

Add `@ObservedObject var updater: UpdaterModel` near the top of `SettingsView`. Then add a section at an appropriate place (likely bottom):

```swift
            Section {
                CheckForUpdatesView(updater: updater)
            } header: {
                Text("Updates")
            }
```

(Adapt to the existing form structure — if it uses `Form { Group { ... } }`, follow that pattern. Don't introduce a new layout idiom.)

- [ ] **Step 3: Verify build**

```sh
xcodebuild -project Pits.xcodeproj -scheme Pits -configuration Debug -destination "platform=macOS,arch=$(uname -m)" build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. (This is the first task in Part A where the full Swift wiring should compile end-to-end.)

- [ ] **Step 4: Manual smoke test**

```sh
bash scripts/run.sh
```

Open Pits → Settings → "Updates" section → "Check for Updates…" button visible. Don't click it yet (no appcast.xml exists; will add stub in Task 11).

Expected: button visible, possibly disabled if Sparkle hasn't initialized yet (that's fine — `canCheckForUpdates` flips true after the first scheduled-check tick, which can take a moment).

- [ ] **Step 5: Commit**

```sh
git add Pits/Views/SettingsView.swift
git commit -m "feat: Check for Updates… button in Settings"
```

---

### Task 8: Menu bar icon dot when update available

**Files:**
- Modify: `Pits/PitsApp.swift` (the `AppDelegate` class, around lines 20–73)

- [ ] **Step 1: Subscribe to updater in `applicationDidFinishLaunching`**

After the existing `store.objectWillChange` subscription block (around line 32–38 in `applicationDidFinishLaunching`), add:

```swift
        // Re-render icon when updater state changes (the updater is set on
        // MenuBarRouter from PitsApp's onAppear; if it's not yet wired this
        // sink simply doesn't fire until it is).
        if let updater = MenuBarRouter.shared.updater {
            updater.objectWillChange
                .sink { [weak self] in
                    Task { @MainActor in self?.refreshIcon() }
                }
                .store(in: &cancellables)
        }
```

But `MenuBarRouter.shared.updater` is set in PitsApp's `.onAppear`, which runs *after* `applicationDidFinishLaunching`. So we need to subscribe lazily. Instead, refactor: in `PitsApp.body`'s `.onAppear`, after setting `MenuBarRouter.shared.updater = updater`, call a new method on `AppDelegate` to wire the subscription. Add to `AppDelegate`:

```swift
    func subscribeToUpdater(_ updater: UpdaterModel) {
        updater.objectWillChange
            .sink { [weak self] in
                Task { @MainActor in self?.refreshIcon() }
            }
            .store(in: &cancellables)
        refreshIcon()
    }
```

And in PitsApp's `.onAppear` (Task 5's edit), after `MenuBarRouter.shared.updater = updater`, add:

```swift
                    if let delegate = NSApp.delegate as? AppDelegate {
                        delegate.subscribeToUpdater(updater)
                    }
```

- [ ] **Step 2: Update `refreshIcon()` to overlay a dot when update available**

Replace the `refreshIcon()` body (around lines 47–62) with:

```swift
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
```

- [ ] **Step 3: Add the `withUpdateDot` helper**

Below `tinted(_:color:)`:

```swift
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
```

- [ ] **Step 4: Verify build**

```sh
xcodebuild -project Pits.xcodeproj -scheme Pits -configuration Debug -destination "platform=macOS,arch=$(uname -m)" build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Manual smoke test**

```sh
bash scripts/run.sh
```

Pits launches; menu bar icon shows the flame, no dot (no update available since no appcast yet). Subsequent visual validation happens in Task 19 once the first auto-update test fires.

- [ ] **Step 6: Commit**

```sh
git add Pits/PitsApp.swift Pits.xcodeproj
git commit -m "feat: blue dot on menu bar icon when update available"
```

---

### Task 9: Add Sparkle keys to `Info.plist` (public key TBD until Task 13)

**Files:**
- Modify: `Pits/Info.plist`

- [ ] **Step 1: Add Sparkle entries**

Edit `Pits/Info.plist`, adding before the closing `</dict>`:

```xml
    <key>SUFeedURL</key>
    <string>https://raw.githubusercontent.com/joelisfar/pits/main/appcast.xml</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>259200</integer>
    <key>SUPublicEDKey</key>
    <string>__SU_PUBLIC_ED_KEY_PLACEHOLDER__</string>
```

The `SUPublicEDKey` will be replaced in Task 13 with the actual base64 public key from `generate_keys`. For now the placeholder lets us commit and continue; the app won't successfully verify updates until the real key is in place, but it'll launch.

- [ ] **Step 2: Verify build**

```sh
xcodebuild -project Pits.xcodeproj -scheme Pits -configuration Debug -destination "platform=macOS,arch=$(uname -m)" build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`. Sparkle warns at runtime if `SUPublicEDKey` is invalid; build is unaffected.

- [ ] **Step 3: Commit**

```sh
git add Pits/Info.plist
git commit -m "feat: Sparkle Info.plist entries (public key placeholder)"
```

---

### Task 10: `RELEASE_NOTES.md`

**Files:**
- Create: `RELEASE_NOTES.md`

- [ ] **Step 1: Create the file**

Create `RELEASE_NOTES.md` at the repo root:

```markdown
## v0.2.0

- Signed and notarized builds — no more right-click → Open on first launch
- Auto-update via Sparkle (checks every 3 days; manual check from Settings)
- Update-available indicator in the main window status row and on the menu bar icon

If you're upgrading from v0.1.x: download and install v0.2.0 manually one
last time. After that, Pits will auto-update on its own.
```

(Stanzas for v0.1.9 and earlier are intentionally omitted; we're not backfilling. Future stanzas append above.)

- [ ] **Step 2: Commit**

```sh
git add RELEASE_NOTES.md
git commit -m "docs: RELEASE_NOTES.md with v0.2.0 stanza"
```

---

### Task 11: Stub `appcast.xml`

**Files:**
- Create: `appcast.xml`

**Why a stub:** Pits' Info.plist points `SUFeedURL` at `raw.githubusercontent.com/joelisfar/pits/main/appcast.xml`. Until a real signed appcast is published by CI, the URL would 404, and Sparkle's manual "Check for Updates…" would error. Stubbing now (empty channel) means the URL returns valid XML with zero items — Sparkle says "you're up to date." First CI run overwrites this file.

- [ ] **Step 1: Create the stub**

Create `appcast.xml` at the repo root:

```xml
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Pits</title>
        <link>https://raw.githubusercontent.com/joelisfar/pits/main/appcast.xml</link>
        <description>Pits release feed.</description>
        <language>en</language>
    </channel>
</rss>
```

- [ ] **Step 2: Commit**

```sh
git add appcast.xml
git commit -m "feat: stub appcast.xml (CI overwrites per release)"
```

---

# PART B — Bootstrap (interactive, user-driven)

These tasks require browser actions and Keychain Access. The agent pauses; the user does the action; the agent verifies via shell where possible, then continues. Each "user does X" sub-step uses 🛑 to mark a pause point.

### Task 12: Create the Developer ID Application certificate

**This is a manual workflow.** Pause and walk the user through it.

- [ ] **Step 1: 🛑 Generate CSR locally**

User instructions:

> 1. Open **Keychain Access** (`/Applications/Utilities/Keychain Access.app`)
> 2. Top menu: **Keychain Access → Certificate Assistant → Request a Certificate From a Certificate Authority…**
> 3. Fill in:
>    - **User Email Address:** your Apple ID email
>    - **Common Name:** "Joel Farris" (or whatever you registered with Apple as)
>    - **CA Email Address:** leave blank
>    - **Request is:** Saved to disk (✓)
> 4. Click Continue → save the `.certSigningRequest` file to `~/Desktop/`

User says "done" when CSR is saved.

- [ ] **Step 2: 🛑 Create the certificate at Apple**

User instructions:

> 1. Open https://developer.apple.com/account/resources/certificates/list
> 2. Click **+** (top-left)
> 3. Under **Software**, choose **Developer ID** → Continue
> 4. Choose **Developer ID Application** (the "Mac app" one, not "Mac Installer Package") → Continue
> 5. **Choose File** → select the `.certSigningRequest` from your Desktop → Continue
> 6. Click **Download** — saves a `.cer` file (typically `developerID_application.cer`) to `~/Downloads/`

User says "done."

- [ ] **Step 3: 🛑 Install the cert into login keychain**

User instructions:

> Double-click the `.cer` file in Downloads. Keychain Access opens; the cert appears in **My Certificates**.

- [ ] **Step 4: Verify the cert is installed and capture Team ID**

```sh
security find-identity -p codesigning -v | grep "Developer ID Application"
```

Expected output: one line like `1) AB1234567890ABCDEF "Developer ID Application: Joel Farris (XYZAB12345)"`. Note the 10-char Team ID in parentheses.

If output is empty: cert install didn't take. User re-double-clicks the `.cer`, or drags it into Keychain Access manually.

- [ ] **Step 5: Save the Team ID for later**

The Team ID will go into the `APPLE_TEAM_ID` GH secret in Task 21. Save it somewhere safe in the meantime (e.g. paste into a scratch note).

- [ ] **Step 6: 🛑 Export the cert as `.p12` for CI**

User instructions:

> 1. In Keychain Access, sidebar → **My Certificates**
> 2. Right-click "Developer ID Application: …" → **Export "Developer ID Application: …"**
> 3. File Format: **Personal Information Exchange (.p12)**
> 4. Save to `~/Desktop/developer-id-app.p12`
> 5. Set a strong passphrase (record it — also goes to GH secrets)

User says "done"; passphrase saved.

- [ ] **Step 7: No commit (no repo state changed)**

This task produces external artifacts (`.p12` on Desktop, Team ID in user's notes). Nothing enters git.

---

### Task 13: Generate Sparkle EdDSA keypair + paste public key

**Files:**
- Modify: `Pits/Info.plist`

- [ ] **Step 1: Build Release once so `generate_keys` exists in derived data**

```sh
xcodebuild -project Pits.xcodeproj -scheme Pits -configuration Release -destination "platform=macOS,arch=$(uname -m)" -derivedDataPath build/release build 2>&1 | tail -3
```

Expected: `** BUILD SUCCEEDED **`. (This is the first hardened-runtime build; if it fails on signing, it's because Task 12 didn't actually install the cert — circle back.)

- [ ] **Step 2: Locate `generate_keys`**

```sh
GEN_KEYS=$(find build/release -name generate_keys -type f | head -1)
echo "$GEN_KEYS"
```

Expected: a path like `build/release/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys`. If empty, Sparkle's binary tools weren't extracted — try `find ~/Library/Developer/Xcode/DerivedData -name generate_keys -type f 2>/dev/null` instead.

- [ ] **Step 3: Generate the keypair**

```sh
"$GEN_KEYS"
```

Expected output: 
```
A pre-existing signing key was found. This is fine if you wish to use it for multiple apps.

Public key (Pass this to your developers so they can verify the EdDSA signature for their app):
[base64-encoded public key here, ~44 chars]
```

…or if it's the first run:
```
A new key has been generated and saved in your Keychain. Public key:
[base64-encoded public key here]
```

Capture the public key (starts with letters, ends with `=` or two `=`).

- [ ] **Step 4: Replace the placeholder in `Info.plist`**

Edit `Pits/Info.plist`: replace `__SU_PUBLIC_ED_KEY_PLACEHOLDER__` with the actual public key from Step 3.

- [ ] **Step 5: Verify build**

```sh
xcodebuild -project Pits.xcodeproj -scheme Pits -configuration Debug -destination "platform=macOS,arch=$(uname -m)" build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Export the private key for CI**

```sh
"$GEN_KEYS" -x ~/Desktop/sparkle_priv.txt
ls -la ~/Desktop/sparkle_priv.txt
```

Expected: `~/Desktop/sparkle_priv.txt` exists, contains a base64 string. This file goes into the `SPARKLE_ED_PRIVATE_KEY` GH secret in Task 21.

**Do NOT commit this file or paste it anywhere outside GH secrets.** Local keychain copy is your operator backup; 1Password copy is disaster-recovery (record this in 1Password too).

- [ ] **Step 7: Commit the public key change**

```sh
git add Pits/Info.plist
git commit -m "feat: real Sparkle public EdDSA key"
```

---

### Task 14: Local sign smoke test (manual validation)

- [ ] **Step 1: Run a fully-signed Release build**

```sh
TEAM_ID=$(security find-identity -p codesigning -v | grep "Developer ID Application" | sed -E 's/.*\(([A-Z0-9]+)\).*/\1/' | head -1)
echo "TEAM_ID=$TEAM_ID"

xcodebuild \
  -project Pits.xcodeproj \
  -scheme Pits \
  -configuration Release \
  -destination "platform=macOS,arch=$(uname -m)" \
  -derivedDataPath build/release \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  clean build 2>&1 | tail -10
```

Expected: `** BUILD SUCCEEDED **`. If signing fails ("No signing certificate '...' found"), `find-identity` couldn't pick out the right one — fall back to passing the full hash from `find-identity` output instead of the friendly name.

- [ ] **Step 2: Verify the signature**

```sh
codesign -dv --verbose=4 build/release/Build/Products/Release/Pits.app 2>&1 | head -15
codesign --verify --deep --strict --verbose=2 build/release/Build/Products/Release/Pits.app
```

Expected: `Signature=adhoc` is gone; you should see `Authority=Developer ID Application: Joel Farris (...)`, `Authority=Developer ID Certification Authority`, `Authority=Apple Root CA`. Verify command should print `valid on disk` and `satisfies its Designated Requirement`.

- [ ] **Step 3: Verify Gatekeeper acceptance (pre-notarization)**

```sh
spctl --assess --type execute --verbose build/release/Build/Products/Release/Pits.app
```

Expected: `accepted source=Developer ID` (full "Notarized Developer ID" comes after notarization in Task 18). Anything else means the cert chain is busted — re-export or re-import.

- [ ] **Step 4: Commit (none — no repo changes)**

---

### Task 15: Sparkle dry-run (manual validation)

- [ ] **Step 1: Launch the signed Release build**

```sh
open build/release/Build/Products/Release/Pits.app
```

Pits launches. (Status bar icon may not be visible if you're already running another instance via `scripts/run.sh` — quit any prior instance first.)

- [ ] **Step 2: Open Settings → Updates → Check for Updates…**

Click the button. Expected: Sparkle's "Up to date" sheet appears (since `appcast.xml` stub has zero items).

If you see an error like "An error occurred in retrieving update information": the appcast.xml stub isn't yet pushed to `main` (the URL in `SUFeedURL` reads from main, not from your local working tree). Verify the stub got pushed in Task 11's commit and that `git log origin/main..HEAD` doesn't show that commit pending.

Wait — at this point we're on `v0.2.0` branch, not `main`. The `appcast.xml` stub committed in Task 11 hasn't been merged to main yet. The dry-run will hit a 404 on the live URL.

**For this dry-run, it's fine for "Check for Updates" to show an error.** What we're verifying is:
- App launches with hardened runtime + signed (didn't crash)
- "Check for Updates…" button is present and clickable
- Sparkle runs (whether it succeeds or fails based on URL is secondary)

After the v0.2.0 branch merges to main in Task 22, the stub will be live and this test will succeed.

- [ ] **Step 3: Quit the Release build**

```sh
killall Pits
```

---

# PART C — Release infrastructure

### Task 16: Extract `scripts/lib/package_dmg.sh`

**Files:**
- Create: `scripts/lib/package_dmg.sh`

- [ ] **Step 1: Create the directory**

```sh
mkdir -p scripts/lib
```

- [ ] **Step 2: Create the script**

Create `scripts/lib/package_dmg.sh`:

```sh
#!/usr/bin/env bash
# Package a built Pits.app into a UDZO-compressed DMG with /Applications symlink.
# Inputs:
#   $1 (VERSION) — semver string, e.g. 0.2.0
#   $APP_PATH (env, optional) — path to Pits.app; defaults to build/release/Build/Products/Release/Pits.app
# Outputs:
#   dist/Pits-$VERSION.dmg
# Used by scripts/release.sh (locally, in pre-CI smoke tests) and .github/workflows/release.yml (CI).

set -euo pipefail
IFS=$'\n\t'

VERSION="${1:?usage: package_dmg.sh VERSION}"
APP_PATH="${APP_PATH:-build/release/Build/Products/Release/Pits.app}"

[[ -d "$APP_PATH" ]] || { echo "✗ App not found at $APP_PATH" >&2; exit 1; }

STAGING="build/dmg-staging"
rm -rf "$STAGING" dist
mkdir -p "$STAGING" dist

cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

DMG_PATH="dist/Pits-$VERSION.dmg"
hdiutil create \
  -volname "Pits $VERSION" \
  -srcfolder "$STAGING" \
  -ov -format UDZO \
  "$DMG_PATH" \
  >/dev/null

echo "→ $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
```

- [ ] **Step 3: Make it executable**

```sh
chmod +x scripts/lib/package_dmg.sh
```

- [ ] **Step 4: Smoke test with the locally-signed build from Task 14**

```sh
bash scripts/lib/package_dmg.sh 0.2.0
ls -la dist/
```

Expected: `dist/Pits-0.2.0.dmg` exists (a few MB). Open the DMG to verify it mounts and shows Pits.app + Applications shortcut.

- [ ] **Step 5: Commit**

```sh
git add scripts/lib/package_dmg.sh
git commit -m "feat: extract package_dmg into scripts/lib for CI reuse"
```

---

### Task 17: Shrink `scripts/release.sh`

**Files:**
- Modify: `scripts/release.sh`

- [ ] **Step 1: Replace the file**

Overwrite `scripts/release.sh` with:

```sh
#!/usr/bin/env bash
# Local-only tagging tool. Bumps version, asserts release notes, commits, tags, pushes.
# CI (.github/workflows/release.yml) takes it from there: build, sign, notarize, publish.
# Phase 2 — see docs/superpowers/specs/2026-05-04-release-pipeline-phase2-design.md
# Usage: bash scripts/release.sh X.Y.Z

set -euo pipefail
IFS=$'\n\t'

cd "$(dirname "$0")/.."

VERSION="${1:-}"

die() {
  echo "✗ $1" >&2
  exit 1
}

version_gt() {
  [[ "$1" == "$2" ]] && return 1
  local higher
  higher=$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)
  [[ "$higher" == "$1" ]]
}

preflight() {
  echo "→ preflight"

  [[ -n "$VERSION" ]] || die "Usage: bash scripts/release.sh X.Y.Z"
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "Version must match X.Y.Z; got: $VERSION"

  for tool in xcodegen gh git; do
    command -v "$tool" >/dev/null \
      || die "$tool not on PATH"
  done

  gh auth status >/dev/null 2>&1 \
    || die "Run \`gh auth login\` first"

  local branch
  branch=$(git rev-parse --abbrev-ref HEAD)
  [[ "$branch" == "main" ]] \
    || die "Release must run from main (currently on $branch)"

  [[ -z $(git status --porcelain) ]] \
    || die "Working tree not clean:
$(git status --porcelain)"

  git fetch origin --quiet
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
    || die "Local main is not in sync with origin/main — pull first"

  if git rev-parse --verify --quiet "v$VERSION" >/dev/null \
     || git ls-remote --tags origin "v$VERSION" 2>/dev/null | grep -q .; then
    die "Tag v$VERSION already exists (local or remote)"
  fi

  local current
  current=$(grep -E '^    MARKETING_VERSION:' project.yml \
            | sed -E 's/.*"([0-9.]+)".*/\1/')
  [[ -n "$current" ]] || die "Could not read MARKETING_VERSION from project.yml"

  if ! version_gt "$VERSION" "$current"; then
    die "$VERSION is not greater than current MARKETING_VERSION ($current)"
  fi

  grep -q "^## v$VERSION$" RELEASE_NOTES.md \
    || die "RELEASE_NOTES.md is missing a '## v$VERSION' stanza — add one before tagging"

  echo "  version $VERSION valid; current is $current; release notes stanza found"
}

bump_version() {
  echo "→ bump_version"

  local current_project_version new_project_version
  current_project_version=$(grep -E '^    CURRENT_PROJECT_VERSION:' project.yml \
                            | sed -E 's/.*"([0-9]+)".*/\1/')
  [[ -n "$current_project_version" ]] \
    || die "Could not read CURRENT_PROJECT_VERSION from project.yml"
  new_project_version=$((current_project_version + 1))

  sed -i '' -E "s/^(    MARKETING_VERSION: )\"[^\"]+\"/\1\"$VERSION\"/" project.yml
  sed -i '' -E "s/^(    CURRENT_PROJECT_VERSION: )\"[^\"]+\"/\1\"$new_project_version\"/" project.yml

  xcodegen generate >/dev/null

  echo "  MARKETING_VERSION=$VERSION CURRENT_PROJECT_VERSION=$new_project_version"
}

tag_and_push() {
  echo "→ tag_and_push"

  git add project.yml
  git commit -m "release: v$VERSION"
  git tag "v$VERSION"

  if ! git push origin main "v$VERSION"; then
    die "Push failed. Recover with: git push origin main v$VERSION"
  fi

  echo "  pushed main + tag v$VERSION to origin"
}

print_ci_url() {
  echo ""
  echo "✓ Tag pushed. CI is now building, signing, notarizing, and publishing."
  echo "  Watch: https://github.com/joelisfar/pits/actions"
  echo "  Release will appear at: https://github.com/joelisfar/pits/releases/tag/v$VERSION"
  echo ""
  echo "  ETA: ~5–8 minutes."
}

main() {
  preflight
  bump_version
  tag_and_push
  print_ci_url
}

main
```

- [ ] **Step 2: Verify script syntax**

```sh
bash -n scripts/release.sh
```

Expected: no output (clean parse).

- [ ] **Step 3: Commit**

```sh
git add scripts/release.sh
git commit -m "refactor: shrink release.sh to tagging-only (CI does build/sign/publish)"
```

---

### Task 18: Create the GitHub Actions workflow

**Files:**
- Create: `.github/workflows/release.yml`

- [ ] **Step 1: Create the directory**

```sh
mkdir -p .github/workflows
```

- [ ] **Step 2: Create the workflow file**

Create `.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    tags: ['v*']

jobs:
  release:
    runs-on: macos-14
    permissions:
      contents: write    # for committing appcast.xml back to main and creating the GH release

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Install xcodegen
        run: brew install xcodegen

      - name: Import signing certificate
        env:
          CERT_P12_BASE64: ${{ secrets.APPLE_CERT_P12_BASE64 }}
          CERT_P12_PASSPHRASE: ${{ secrets.APPLE_CERT_P12_PASSPHRASE }}
          KEYCHAIN_PASSWORD: ${{ secrets.KEYCHAIN_PASSWORD }}
        run: |
          echo "$CERT_P12_BASE64" | base64 -d > "$RUNNER_TEMP/cert.p12"
          security create-keychain -p "$KEYCHAIN_PASSWORD" build.keychain
          security default-keychain -s build.keychain
          security unlock-keychain -p "$KEYCHAIN_PASSWORD" build.keychain
          security set-keychain-settings -t 7200 -u build.keychain
          security import "$RUNNER_TEMP/cert.p12" -k build.keychain \
            -P "$CERT_P12_PASSPHRASE" -T /usr/bin/codesign -T /usr/bin/security
          security set-key-partition-list -S apple-tool:,apple: \
            -s -k "$KEYCHAIN_PASSWORD" build.keychain
          rm "$RUNNER_TEMP/cert.p12"

      - name: Generate Xcode project
        run: xcodegen generate

      - name: Build (Release, hardened, signed)
        env:
          TEAM_ID: ${{ secrets.APPLE_TEAM_ID }}
        run: |
          xcodebuild \
            -project Pits.xcodeproj \
            -scheme Pits \
            -configuration Release \
            -destination "platform=macOS,arch=arm64" \
            -derivedDataPath build/release \
            CODE_SIGN_IDENTITY="Developer ID Application" \
            DEVELOPMENT_TEAM="$TEAM_ID" \
            clean build

      - name: Verify codesign
        run: |
          APP=build/release/Build/Products/Release/Pits.app
          codesign -dv --verbose=4 "$APP"
          codesign --verify --deep --strict --verbose=2 "$APP"

      - name: Package DMG
        run: |
          VERSION="${GITHUB_REF_NAME#v}"
          bash scripts/lib/package_dmg.sh "$VERSION"

      - name: Notarize + staple
        env:
          API_KEY_P8_BASE64: ${{ secrets.APPSTORE_API_KEY_P8_BASE64 }}
          API_KEY_ID: ${{ secrets.APPSTORE_API_KEY_ID }}
          API_ISSUER_ID: ${{ secrets.APPSTORE_API_ISSUER_ID }}
        run: |
          VERSION="${GITHUB_REF_NAME#v}"
          echo "$API_KEY_P8_BASE64" | base64 -d > "$RUNNER_TEMP/key.p8"
          xcrun notarytool submit "dist/Pits-$VERSION.dmg" \
            --key "$RUNNER_TEMP/key.p8" \
            --key-id "$API_KEY_ID" \
            --issuer "$API_ISSUER_ID" \
            --wait
          xcrun stapler staple "dist/Pits-$VERSION.dmg"
          rm "$RUNNER_TEMP/key.p8"

      - name: Render release notes to HTML for Sparkle
        run: |
          VERSION="${GITHUB_REF_NAME#v}"
          # Extract the matching stanza from RELEASE_NOTES.md (lines from "## vX.Y.Z" up to the next "## " or EOF)
          awk -v v="## v$VERSION" '
            $0 == v {capture=1; next}
            capture && /^## / {exit}
            capture {print}
          ' RELEASE_NOTES.md > "$RUNNER_TEMP/notes.md"

          if [ ! -s "$RUNNER_TEMP/notes.md" ]; then
            echo "✗ No release notes stanza found for v$VERSION in RELEASE_NOTES.md" >&2
            exit 1
          fi

          # Render to HTML. macos-14 runners have pandoc preinstalled via brew? Check + install if needed.
          if ! command -v pandoc >/dev/null; then
            brew install pandoc
          fi
          pandoc "$RUNNER_TEMP/notes.md" -f markdown -t html -o "dist/Pits-$VERSION.html"

          echo "Rendered notes:"
          cat "dist/Pits-$VERSION.html"

      - name: Generate signed appcast
        env:
          SPARKLE_ED_PRIVATE_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}
        run: |
          echo "$SPARKLE_ED_PRIVATE_KEY" > "$RUNNER_TEMP/sparkle_priv.txt"
          GEN_APPCAST=$(find build/release -name generate_appcast -type f | head -1)
          if [ -z "$GEN_APPCAST" ]; then
            echo "✗ generate_appcast not found in build artifacts" >&2
            exit 1
          fi
          # generate_appcast also needs the public key; it reads it from the .app bundle's Info.plist (SUPublicEDKey).
          # It picks up *.dmg and *.html files in the dist/ directory.
          "$GEN_APPCAST" --ed-key-file "$RUNNER_TEMP/sparkle_priv.txt" dist/
          rm "$RUNNER_TEMP/sparkle_priv.txt"

          # Verify the appcast got an item for this version
          grep -q "Pits-${GITHUB_REF_NAME#v}.dmg" dist/appcast.xml \
            || { echo "✗ appcast.xml is missing the new release"; cat dist/appcast.xml; exit 1; }

      - name: Commit appcast.xml back to main
        run: |
          cp dist/appcast.xml ./appcast.xml
          git config user.name "github-actions[bot]"
          git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git fetch origin main
          git checkout main
          git pull origin main
          cp dist/appcast.xml ./appcast.xml
          git add appcast.xml
          if git diff --cached --quiet; then
            echo "no appcast changes to commit"
          else
            git commit -m "release: appcast for ${GITHUB_REF_NAME}"
            git push origin main
          fi

      - name: Publish GitHub release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          VERSION="${GITHUB_REF_NAME#v}"
          gh release create "$GITHUB_REF_NAME" \
            --title "$GITHUB_REF_NAME" \
            --notes-file "$RUNNER_TEMP/notes.md" \
            "dist/Pits-$VERSION.dmg"

      - name: Cleanup keychain
        if: always()
        run: |
          security delete-keychain build.keychain || true
```

- [ ] **Step 3: Lint the YAML**

```sh
# If actionlint is installed:
command -v actionlint >/dev/null && actionlint .github/workflows/release.yml
# Otherwise just a basic syntax check:
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/release.yml'))"
```

Expected: no errors.

- [ ] **Step 4: Commit**

```sh
git add .github/workflows/release.yml
git commit -m "feat: GitHub Actions release workflow"
```

---

# PART D — Bootstrap part 2 + GH secrets

### Task 19: Generate App Store Connect API key

**This is a manual workflow.** Pause and walk the user through it.

- [ ] **Step 1: 🛑 Create the API key**

User instructions:

> 1. Open https://appstoreconnect.apple.com/access/integrations/api
> 2. **Team Keys** tab (default)
> 3. Click **Generate API Key** (or **+**)
> 4. Fill in:
>    - **Name:** "Pits Notarization"
>    - **Access:** Developer
> 5. Click **Generate**

User says "done."

- [ ] **Step 2: 🛑 Download the `.p8` and capture IDs**

User instructions:

> 1. After generation, the page shows a **Download API Key** button — click it. **This is the only chance to download.** File is named `AuthKey_XXXXX.p8`.
> 2. From the same page, note:
>    - **Key ID:** the 10-character alphanumeric string in the row
>    - **Issuer ID:** the UUID at the top of the page

User pastes both IDs into a scratch note and says "done."

- [ ] **Step 3: Verify the API key works (optional)**

```sh
xcrun notarytool history \
  --key ~/Downloads/AuthKey_XXXXX.p8 \
  --key-id XXXXX \
  --issuer YYYY-...
```

Replace `XXXXX` and `YYYY-...` with the actual values. Expected: either an empty list or past notarization submissions. Auth error means one of the values is wrong.

- [ ] **Step 4: No commit (no repo state changed)**

---

### Task 20: Local notarize smoke test (manual validation)

- [ ] **Step 1: Submit the locally-signed DMG from Task 16**

```sh
xcrun notarytool submit dist/Pits-0.2.0.dmg \
  --key ~/Downloads/AuthKey_XXXXX.p8 \
  --key-id XXXXX \
  --issuer YYYY-... \
  --wait
```

Expected (within 1–5 minutes): `status: Accepted`. If `status: Invalid`:

```sh
xcrun notarytool log <submission-id> \
  --key ~/Downloads/AuthKey_XXXXX.p8 \
  --key-id XXXXX \
  --issuer YYYY-...
```

Read the JSON for the specific issue. Common: nested binary missing hardened runtime — Sparkle's XPC service usually inherits it correctly via `--deep`, but verify with `codesign -dv` on each `.app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/*.xpc`.

- [ ] **Step 2: Staple**

```sh
xcrun stapler staple dist/Pits-0.2.0.dmg
```

Expected: `The staple and validate action worked!`

- [ ] **Step 3: Confirm Gatekeeper acceptance for notarized state**

```sh
spctl --assess --type execute --verbose build/release/Build/Products/Release/Pits.app
```

Expected: `accepted source=Notarized Developer ID` (the Notarized prefix is the proof). If it still says `accepted source=Developer ID` only, stapler ran on the DMG but the app inside isn't stapled — that's fine; the DMG ships notarized, and double-clicking the DMG-mounted app inherits the staple.

- [ ] **Step 4: No commit**

---

### Task 21: Configure GitHub Actions secrets

**This is a manual workflow.**

- [ ] **Step 1: 🛑 Open the secrets page**

User instructions:

> Open https://github.com/joelisfar/pits/settings/secrets/actions

- [ ] **Step 2: 🛑 Create each secret**

Click **New repository secret** for each row. Values come from the bootstrap tasks above.

| Secret name | Value | Source |
|---|---|---|
| `APPLE_CERT_P12_BASE64` | `base64 -i ~/Desktop/developer-id-app.p12 \| pbcopy` then paste | Task 12 step 6 |
| `APPLE_CERT_P12_PASSPHRASE` | the passphrase you set | Task 12 step 6 |
| `APPLE_TEAM_ID` | the 10-char string from `find-identity` | Task 12 step 4 |
| `APPSTORE_API_KEY_P8_BASE64` | `base64 -i ~/Downloads/AuthKey_XXXXX.p8 \| pbcopy` then paste | Task 19 step 2 |
| `APPSTORE_API_KEY_ID` | the 10-char Key ID | Task 19 step 2 |
| `APPSTORE_API_ISSUER_ID` | the UUID Issuer ID | Task 19 step 2 |
| `SPARKLE_ED_PRIVATE_KEY` | `cat ~/Desktop/sparkle_priv.txt \| pbcopy` then paste | Task 13 step 6 |
| `KEYCHAIN_PASSWORD` | `openssl rand -hex 32 \| pbcopy` then paste | (just a random string) |

User says "all 8 secrets set."

- [ ] **Step 3: Verify the count**

```sh
gh secret list
```

Expected: 8 lines, one per secret name above. (The CLI doesn't show values, just names + last-updated timestamps.)

- [ ] **Step 4: No commit**

---

# PART E — First release + validation

### Task 22: Merge `v0.2.0` branch to `main`

- [ ] **Step 1: Push the branch**

```sh
git push -u origin v0.2.0
```

- [ ] **Step 2: 🛑 Create the PR**

```sh
gh pr create \
  --base main \
  --head v0.2.0 \
  --title "v0.2.0: signed builds + Sparkle auto-update + CI" \
  --body "$(cat <<'EOF'
## Summary
- Signed and notarized builds via GH Actions on tag push
- Sparkle 2.x auto-update with EdDSA-signed appcast
- UpdaterModel + UI affordances (status row indicator, menu bar icon dot, Settings button)
- Hardened runtime + entitlements file
- release.sh shrunk to tagging-only

## Spec
docs/superpowers/specs/2026-05-04-release-pipeline-phase2-design.md

## Plan
docs/superpowers/plans/2026-05-04-release-pipeline-phase2.md

## Test plan
- [ ] CI workflow succeeds end-to-end on v0.2.0 tag (executed post-merge — see plan Task 23)
- [ ] Personal Mac install: download Pits-0.2.0.dmg, double-click (no right-click), confirm app launches without Gatekeeper prompt
- [ ] Work Mac install: same, plus MDM acceptance check
- [ ] Auto-update test: install v0.2.0, push v0.2.1, confirm in-app prompt fires within ~3 days (or use Check for Updates… to skip the timer)

EOF
)"
```

- [ ] **Step 3: 🛑 Merge the PR**

User instructions: review the PR diff in the browser, merge via "Squash and merge" (or whatever the repo's standard is — Phase 1 used squash merges).

- [ ] **Step 4: Pull main locally**

```sh
git checkout main
git pull origin main
git status
```

Expected: clean tree on main, latest commit is the squash-merge from v0.2.0.

---

### Task 23: First CI release (`v0.2.0`)

- [ ] **Step 1: Run release.sh**

```sh
bash scripts/release.sh 0.2.0
```

Expected: 
- preflight passes (notes stanza found)
- bump_version sets MARKETING_VERSION to 0.2.0, CURRENT_PROJECT_VERSION to 11
- commits + tags + pushes
- prints CI URL

- [ ] **Step 2: 🛑 Watch the workflow**

```sh
gh run watch
```

…or open https://github.com/joelisfar/pits/actions in a browser.

Expected: workflow takes ~5–8 minutes. **First run will likely fail somewhere.** Common failures:

- **"No signing certificate found"** — `APPLE_CERT_P12_BASE64` is corrupt; re-encode and re-paste.
- **`set-key-partition-list` fails** — usually a sign that the temp keychain wasn't unlocked first; check the workflow log.
- **`notarytool: status: Invalid`** — pull the log via `xcrun notarytool log <id>` (using local API key) and inspect. Most common: an entitlement we didn't expect, or hardened runtime missing on a nested binary.
- **`generate_appcast` produces empty appcast** — DMG filename doesn't match `Pits-X.Y.Z.dmg` pattern, or the app's Info.plist doesn't have `SUPublicEDKey`.
- **Push to main fails** — branch protection rule. Either disable the rule for `github-actions[bot]` user or change the workflow to push appcast.xml to a separate `appcast` branch and update SUFeedURL accordingly.

Iterate: fix the issue locally on `main` (or in the workflow YAML on `main`), commit, then re-trigger the failed release. To re-trigger without bumping version, use:

```sh
git tag -d v0.2.0
git push origin :refs/tags/v0.2.0
# fix whatever
git tag v0.2.0
git push origin v0.2.0
```

**Important:** if notarization succeeded on a previous attempt, don't redo the version (notarization tickets are tied to the exact binary). Bump to 0.2.1 and accept that 0.2.0 was a learning-experience tag.

- [ ] **Step 3: Verify the release artifact**

```sh
gh release view v0.2.0
```

Expected: shows the release with `Pits-0.2.0.dmg` attached and the release notes from `RELEASE_NOTES.md` rendered.

- [ ] **Step 4: Verify appcast was committed back**

```sh
git pull origin main
cat appcast.xml | head -30
```

Expected: appcast.xml has a real `<item>` for v0.2.0 with `<enclosure url="...Pits-0.2.0.dmg"`, `<sparkle:edSignature>`, and a `<description>` containing the rendered HTML from RELEASE_NOTES.md.

---

### Task 24: Personal Mac install validation

- [ ] **Step 1: 🛑 Download in browser**

User instructions:

> 1. Open https://github.com/joelisfar/pits/releases/tag/v0.2.0 in Safari/Chrome
> 2. Download `Pits-0.2.0.dmg`
> 3. **Important:** Quarantine attribute only gets set when downloaded via browser, not curl — so this must be a browser download to actually test Gatekeeper.

- [ ] **Step 2: Verify quarantine attribute is set**

```sh
xattr ~/Downloads/Pits-0.2.0.dmg
```

Expected: shows `com.apple.quarantine`. If absent, browser didn't tag it; redownload.

- [ ] **Step 3: 🛑 Install**

User instructions:

> 1. Double-click the DMG to mount
> 2. Drag Pits.app to Applications
> 3. Eject the DMG
> 4. Open `/Applications` in Finder
> 5. **Double-click Pits.app** (NOT right-click → Open) — this is the test
> 6. App should launch directly with no Gatekeeper prompt

If "Pits cannot be opened" or right-click required: signing/notarization/stapling didn't fully take. Drop into investigation:

```sh
spctl --assess -vv /Applications/Pits.app
codesign -dv --verbose=4 /Applications/Pits.app | grep -E "(Authority|Identifier|Sealed)"
```

Look for `source=Notarized Developer ID` and the full `Authority=Developer ID Application: Joel Farris (TEAMID)` chain.

- [ ] **Step 4: 🛑 Verify Settings → Updates works**

User instructions:

> 1. Pits → Settings (`⌘,`)
> 2. Updates section → "Check for Updates…" button
> 3. Click it
> 4. Should say "You're up to date" (since v0.2.0 is the only release)

---

### Task 25: Work Mac install validation

- [ ] **Step 1: 🛑 User repeats Task 24 on the work Mac**

Same flow. Add: watch for any MDM dialogs around running a "new" Developer ID app. Most MDM profiles allow Developer ID-signed apps without intervention; some require an admin to allow it once. Note any friction in a separate doc — that's the stopgap-removed UX win.

---

### Task 26: Auto-update validation (`v0.2.1`)

- [ ] **Step 1: Make a trivial change on a feature branch**

```sh
git checkout -b v0.2.1
echo "" >> RELEASE_NOTES.md
sed -i '' '1i\
## v0.2.1\
\
- Trivial bump to test auto-update.\
\
' RELEASE_NOTES.md
git add RELEASE_NOTES.md
git commit -m "test: dummy v0.2.1 to exercise auto-update"
git push -u origin v0.2.1
```

- [ ] **Step 2: 🛑 PR + merge**

```sh
gh pr create --base main --head v0.2.1 --title "v0.2.1: auto-update test" --body "Tests the Sparkle update flow end-to-end."
```

User merges in browser.

- [ ] **Step 3: Tag and release v0.2.1**

```sh
git checkout main
git pull
bash scripts/release.sh 0.2.1
gh run watch
```

- [ ] **Step 4: 🛑 Trigger update check from running v0.2.0**

User instructions:

> 1. The v0.2.0 Pits should still be running on your personal Mac (otherwise relaunch it from Applications).
> 2. Pits → Settings → "Check for Updates…"
> 3. Sparkle should show: "A new version of Pits is available! Pits 0.2.1 is now available — you have 0.2.0."
> 4. Click **Install Update**.
> 5. Sparkle downloads the DMG, verifies the EdDSA signature, prompts to relaunch.
> 6. Click **Install and Relaunch**.
> 7. App quits, replaces itself, relaunches as v0.2.1.
> 8. Verify new version: Pits → Settings → bottom should show "Version 0.2.1" (or use About menu / `defaults read /Applications/Pits.app/Contents/Info.plist CFBundleShortVersionString`).

If signature verification fails: the public key in 0.2.0's Info.plist doesn't match the private key CI signed with. This means Task 13's public key got mis-pasted, or `SPARKLE_ED_PRIVATE_KEY` secret was set from a different `generate_keys` run. Recovery is messy — basically nobody can auto-update from 0.2.0; you'd need to ship 0.2.1 with the corrected key and tell users to manually download.

- [ ] **Step 5: Verify the bottom-right indicator state**

After updating to v0.2.1:
- Re-launch Pits
- Open main window
- Bottom status row: should show no update icon (you're up to date)
- Menu bar flame icon: no blue dot

---

### Task 27: Cleanup local credentials

After Task 26 confirms end-to-end works, the local copies of credentials are no longer needed. CI is the only place they live now.

- [ ] **Step 1: Move local artifacts to disposal queue**

```sh
mv ~/Desktop/developer-id-app.p12 ~/.Trash/
mv ~/Desktop/sparkle_priv.txt ~/.Trash/
mv ~/Downloads/AuthKey_*.p8 ~/.Trash/
```

(Don't `srm` or `rm -P` — Trash is fine; macOS auto-secures Trash with FileVault.)

- [ ] **Step 2: Confirm 1Password backups exist**

User checks 1Password for entries:
- `Pits — Developer ID Application .p12 + passphrase`
- `Pits — App Store Connect API key (.p8 + Key ID + Issuer ID)`
- `Pits — Sparkle EdDSA private key`

(If these don't exist, **don't trash the originals yet** — back up first.)

- [ ] **Step 3: Empty trash**

User empties the trash when comfortable.

- [ ] **Step 4: No commit**

---

### Task 28: Update memory

- [ ] **Step 1: Mark Phase 2 complete in memory**

The auto-memory note "Release pipeline Phase 2 pending" can be deleted or updated to a "Phase 3 candidates" note (Phase 2 is now Phase 1's successor — both shipped).

The agent updates `/Users/jifarris/.claude/projects/-Users-jifarris-Projects-pits/memory/release_pipeline_phase2_pending.md` and the index in `MEMORY.md`.

---

## Self-review

**Spec coverage:**
- Goal 1 (tag-push triggers signed CI release): ✅ Tasks 18, 23
- Goal 2 (in-app update prompt within ~3 days): ✅ Tasks 9 (`SUScheduledCheckInterval: 259200`), 5 (UpdaterModel)
- Goal 3 (credentials only in GH secrets steady-state): ✅ Tasks 21, 27
- Goal 4 (release.sh becomes tagging tool, no Apple deps): ✅ Task 17
- Goal 5 (RELEASE_NOTES single source for both surfaces): ✅ Tasks 10, 18 (rendering step)

**Component coverage:**
- A. Sparkle integration: Tasks 2–9
- B. Hardened runtime + entitlements: Task 1
- C. RELEASE_NOTES.md: Task 10
- D. release.sh shrinking: Task 17
- E. package_dmg.sh extraction: Task 16
- F. .github/workflows/release.yml: Task 18

**Bootstrap coverage:**
- Apple Developer ID cert: Task 12
- App Store Connect API key: Task 19
- Sparkle EdDSA keypair: Task 13
- KEYCHAIN_PASSWORD: Task 21 step 2

**Validation steps from spec match plan tasks:**
- Spec validation 1 (local sign): Task 14
- Spec validation 2 (local notarize): Task 20
- Spec validation 3 (Sparkle dry-run): Task 15
- Spec validation 4 (first CI release): Task 23
- Spec validation 5 (personal Mac install): Task 24
- Spec validation 6 (work Mac install): Task 25
- Spec validation 7 (auto-update test): Task 26
- Spec validation 8 (cleanup): Task 27

**Placeholder scan:** No "TBD"/"TODO"/"fill in" in the plan. The two intentional placeholders are:
- Task 9 step 1: `__SU_PUBLIC_ED_KEY_PLACEHOLDER__` in Info.plist — explicitly replaced in Task 13
- Tasks 19/20/21: `XXXXX` and `YYYY-...` representing values the user pastes from Apple's portal

**Type/name consistency:**
- `UpdaterModel` used consistently across tasks 3, 4, 5, 6, 7, 8
- `updater` (lowercase) consistent as parameter/property name
- `SPUStandardUpdaterController` referenced correctly
- `MenuBarRouter.shared.updater` consistent in tasks 5, 8

**Known risks:**
- Task 3 has a Sparkle delegate-init pattern that may need adjustment based on Sparkle 2.6's actual API. Plan calls this out in step 3 with a fallback.
- Task 23 first CI run is the highest-risk step; plan acknowledges and gives debug strategy.
- Task 26 step 4 EdDSA key mismatch is recoverable but painful; plan documents the recovery path.
