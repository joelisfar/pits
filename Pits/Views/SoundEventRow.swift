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
        // Custom binding so every Picker selection — including re-selecting
        // the current value, which `.onChange` would dedupe and miss — plays
        // a preview, matching macOS System Settings → Sound.
        let previewingSelection = Binding(
            get: { selection },
            set: { newValue in
                selection = newValue
                soundManager.preview(soundName: newValue)
            }
        )

        HStack {
            Text(event.label)
            Spacer()
            Picker("", selection: previewingSelection) {
                Text("None").tag("")
                ForEach(availableSounds, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .fixedSize()

            Button {
                soundManager.preview(soundName: selection)
            } label: {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .disabled(selection.isEmpty)
            .help("Preview sound")
        }
    }
}
