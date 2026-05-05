import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var updater: UpdaterModel
    @AppStorage(SoundManager.soundsEnabledKey) private var soundsEnabled: Bool = true
    @AppStorage("net.farriswheel.Pits.alwaysOnTop") private var alwaysOnTop: Bool = false
    @State private var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)
    @State private var launchError: String?

    private let availableSounds = SystemSounds.available
    private let soundManager = SoundManager()

    var body: some View {
        Form {
            Section("Sounds") {
                Toggle("Play sound effects", isOn: $soundsEnabled)
                ForEach(SoundEvent.allCases, id: \.self) { event in
                    SoundEventRow(
                        event: event,
                        availableSounds: availableSounds,
                        soundManager: soundManager
                    )
                    .disabled(!soundsEnabled)
                }
            }
            Section("Window") {
                Toggle("Keep window on top", isOn: $alwaysOnTop)
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { on in
                        do {
                            if on { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                            launchAtLogin = on
                            launchError = nil
                        } catch {
                            launchError = error.localizedDescription
                        }
                    }
                ))
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section("Updates") {
                CheckForUpdatesView(updater: updater)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 440)
    }
}
