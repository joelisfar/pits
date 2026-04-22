import SwiftUI

struct SoundEventRow: View {
    let event: SoundEvent
    let availableSounds: [String]
    let soundManager: SoundManager
    @AppStorage private var selection: String

    init(event: SoundEvent, availableSounds: [String], soundManager: SoundManager) {
        self.event = event
        self.availableSounds = availableSounds
        self.soundManager = soundManager
        // SoundManager seeds defaults at init — by the time this view appears
        // the value is already present in UserDefaults; the `wrappedValue: ""`
        // is the AppStorage fallback only if seeding somehow didn't run.
        self._selection = AppStorage(wrappedValue: "", event.storageKey)
    }

    var body: some View {
        HStack {
            Text(event.label)
            Spacer()
            Button {
                soundManager.preview(soundName: selection)
            } label: {
                Image(systemName: "speaker.wave.2")
            }
            .buttonStyle(.borderless)
            .disabled(selection.isEmpty)
            .help("Preview sound")

            Picker("", selection: $selection) {
                Text("None").tag("")
                ForEach(availableSounds, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .frame(width: 140)
            .onChange(of: selection) { _, newValue in
                soundManager.preview(soundName: newValue)
            }
        }
    }
}
