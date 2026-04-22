import Foundation

/// User-configurable chime events. Each case has a stable raw value used in
/// UserDefaults keys, a human-readable label for the Settings UI, and a
/// priority list of preferred system sound names (the first one that exists
/// on the user's macOS install becomes the default).
enum SoundEvent: String, CaseIterable {
    case agentTurnCompleted
    case oneMinuteUntilCold
    case fifteenSecondsUntilCold
    case newCold
    case coldHumanTurn

    var label: String {
        switch self {
        case .agentTurnCompleted:        return "Agent turn completed"
        case .fifteenSecondsUntilCold:   return "15 seconds until cold"
        case .oneMinuteUntilCold:        return "1 minute until cold"
        case .newCold:                   return "New cold status"
        case .coldHumanTurn:             return "Cold human turn"
        }
    }

    var storageKey: String { "net.farriswheel.Pits.sound.\(rawValue)" }

    /// Preferred default sound names, in priority order. macOS 14 (Sonoma)
    /// renamed many system sounds (Sosumi → Sonumi, Submarine → Submerge,
    /// etc.); list both classic and new names so seeding works on either.
    var preferredDefaults: [String] {
        switch self {
        case .agentTurnCompleted:        return ["Ping", "Boop", "Pluck"]
        case .fifteenSecondsUntilCold:   return ["Sosumi", "Sonumi", "Funk", "Funky"]
        case .oneMinuteUntilCold:        return ["Blow", "Breeze"]
        case .newCold:                   return ["Submarine", "Submerge", "Sonar"]
        case .coldHumanTurn:             return ["Hero", "Tink", "Pluck", "Pebble"]
        }
    }
}
