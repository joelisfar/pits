import Foundation
import AppKit

final class SoundManager {
    private let defaults: UserDefaults
    private let player: (String) -> Void

    static let soundsEnabledKey = "net.farriswheel.Pits.soundsEnabled"

    /// - Parameter player: injection seam for tests; default plays via NSSound.
    init(
        defaults: UserDefaults = .standard,
        player: @escaping (String) -> Void = { name in
            NSSound(named: NSSound.Name(name))?.play()
        }
    ) {
        self.defaults = defaults
        self.player = player
        if defaults.object(forKey: SoundManager.soundsEnabledKey) == nil {
            defaults.set(true, forKey: SoundManager.soundsEnabledKey)
        }
    }

    var soundsEnabled: Bool {
        get { defaults.bool(forKey: SoundManager.soundsEnabledKey) }
        set { defaults.set(newValue, forKey: SoundManager.soundsEnabledKey) }
    }

    func playMessageReceived() {
        guard soundsEnabled else { return }
        player("Ping")
    }

    func playOneMinuteWarning() {
        guard soundsEnabled else { return }
        player("Blow")
    }
}
