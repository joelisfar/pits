import Foundation
import Combine
import Sparkle

/// Bridges Sparkle's `SPUStandardUpdaterController` to SwiftUI by republishing
/// the `canCheckForUpdates` and "update available" state. Owns the updater
/// lifecycle for the app — created once in `PitsApp.init`, held as a
/// `@StateObject`, and consumed by views that need to render an indicator or
/// fire a manual check.
///
/// Uses the fallback init pattern: `super.init()` is called first, then the
/// controller is allocated and assigned to an implicitly-unwrapped optional.
/// This is required because `SPUUpdaterDelegate` is `NS_SWIFT_UI_ACTOR`
/// (i.e., `@MainActor` in Swift), so `self` can be passed as the delegate
/// after `super.init()` completes without isolation issues.
@MainActor
final class UpdaterModel: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates: Bool = false
    @Published private(set) var updateAvailable: Bool = false

    // Implicitly-unwrapped optional so it can be assigned after super.init().
    private var controller: SPUStandardUpdaterController!
    private var cancellables: Set<AnyCancellable> = []

    override init() {
        super.init()

        // `startingUpdater: true` makes Sparkle begin the scheduled-check
        // timer immediately. `self` is passed as the updater delegate so
        // `didFindValidUpdate` / `updaterDidNotFindUpdate` fire. Sparkle holds
        // delegates weakly, so no retain cycle is introduced.
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )

        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &cancellables)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        updateAvailable = true
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        updateAvailable = false
    }
}

extension UpdaterModel {
    /// Called from PitsApp.init after super-style init constraints are
    /// satisfied. Sets the updater's delegate to self so didFindValidUpdate /
    /// updaterDidNotFindUpdate fire.
    ///
    /// No-op here because `self` was already passed as the delegate at
    /// controller init. Kept so Task 5's planned call compiles without changes.
    func attachDelegate() {
        // Delegate set at init — nothing to do.
    }
}
