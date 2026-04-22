import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @AppStorage(SoundManager.soundsEnabledKey) private var soundsEnabled: Bool = true
    @AppStorage("net.farriswheel.Pits.alwaysOnTop") private var alwaysOnTop: Bool = false
    @State private var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)
    @State private var launchError: String?

    private let availableSounds = SystemSounds.available
    private let soundManager = SoundManager()

    var body: some View {
        Form {
            Section("Sounds") {
                Toggle("Play notification sounds", isOn: $soundsEnabled)
                if soundsEnabled {
                    ForEach(SoundEvent.allCases, id: \.self) { event in
                        SoundEventRow(
                            event: event,
                            availableSounds: availableSounds,
                            soundManager: soundManager
                        )
                    }
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
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }
}
