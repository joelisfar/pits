import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var store: ConversationStore
    @AppStorage(SoundManager.soundsEnabledKey) private var soundsEnabled: Bool = true
    @AppStorage("net.farriswheel.Pits.ttlSeconds") private var ttlSeconds: Double = 300
    @State private var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("Cache") {
                HStack {
                    Text("TTL duration")
                    Slider(
                        value: Binding(
                            get: { ttlSeconds },
                            set: { new in
                                ttlSeconds = new
                                store.ttlSeconds = new
                            }
                        ),
                        in: 60...1800, step: 30
                    )
                    Text("\(Int(ttlSeconds))s")
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 60, alignment: .trailing)
                }
            }

            Section("Sounds") {
                Toggle("Play notification sounds", isOn: $soundsEnabled)
            }

            Section("Startup") {
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
        .padding(20)
        .frame(width: 420)
    }
}
