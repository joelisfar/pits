import Foundation
import AppKit

final class SoundManager {
    private let defaults: UserDefaults
    private let player: (String) -> Void
    private let availableSounds: [String]

    static let soundsEnabledKey = "net.farriswheel.Pits.soundsEnabled"

    /// - Parameters:
    ///   - defaults: UserDefaults backing store. Tests inject an isolated suite.
    ///   - availableSounds: Names of installed system sounds (no extension).
    ///     Defaults to `SystemSounds.available`. Tests inject a stable list.
    ///   - player: injection seam for tests; default plays via `NSSound`.
    init(
        defaults: UserDefaults = .standard,
        availableSounds: [String] = SystemSounds.available,
        player: @escaping (String) -> Void = { name in
            NSSound(named: NSSound.Name(name))?.play()
        }
    ) {
        self.defaults = defaults
        self.availableSounds = availableSounds
        self.player = player

        if defaults.object(forKey: SoundManager.soundsEnabledKey) == nil {
            defaults.set(true, forKey: SoundManager.soundsEnabledKey)
        }
        // Seed per-event defaults idempotently. We only write when a key is
        // absent, so a user's prior selection is preserved across upgrades.
        for event in SoundEvent.allCases where defaults.object(forKey: event.storageKey) == nil {
            defaults.set(resolveDefault(for: event), forKey: event.storageKey)
        }
    }

    var soundsEnabled: Bool {
        get { defaults.bool(forKey: SoundManager.soundsEnabledKey) }
        set { defaults.set(newValue, forKey: SoundManager.soundsEnabledKey) }
    }

    func soundName(for event: SoundEvent) -> String {
        defaults.string(forKey: event.storageKey) ?? ""
    }

    /// Plays the configured sound for `event` if the master toggle is on AND
    /// the per-event sound is non-empty. Used by chime triggers.
    func play(_ event: SoundEvent) {
        guard soundsEnabled else { return }
        let name = soundName(for: event)
        guard !name.isEmpty else { return }
        player(name)
    }

    /// Plays a sound by name, ignoring both the master toggle and any stored
    /// per-event selection. Used by the Settings preview button and the
    /// picker's on-change handler. No-op for the empty string.
    func preview(soundName name: String) {
        guard !name.isEmpty else { return }
        player(name)
    }

    private func resolveDefault(for event: SoundEvent) -> String {
        for preferred in event.preferredDefaults where availableSounds.contains(preferred) {
            return preferred
        }
        return availableSounds.first ?? ""
    }
}
