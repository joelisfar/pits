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
