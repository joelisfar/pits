import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var store: ConversationStore
    @AppStorage(SoundManager.soundsEnabledKey) private var soundsEnabled: Bool = true
    @AppStorage("net.farriswheel.Pits.ttlSeconds") private var ttlSeconds: Double = 300
    @AppStorage("net.farriswheel.Pits.alwaysOnTop") private var alwaysOnTop: Bool = false
    @State private var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)
    @State private var launchError: String?

    var body: some View {
        Form {
            Section {
                Picker("Cache TTL:", selection: Binding(
                    get: { [300.0, 3600.0].contains(ttlSeconds) ? ttlSeconds : 300.0 },
                    set: { new in
                        ttlSeconds = new
                        store.ttlSeconds = new
                    }
                )) {
                    Text("5 minutes").tag(300.0)
                    Text("1 hour").tag(3600.0)
                }
            }

            Section {
                Toggle("Play notification sounds", isOn: $soundsEnabled)
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
        .scrollDisabled(true)
        .frame(width: 440, height: 220)
    }
}
