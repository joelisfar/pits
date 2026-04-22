import XCTest
@testable import Pits

final class SoundManagerTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "net.farriswheel.Pits.tests"
    // Stable test universe: covers some preferred-default targets and some misses.
    private let testSounds = ["Boop", "Breeze", "Pluck", "Sonumi", "Submerge", "Tink"]

    override func setUp() {
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeManager(
        played: @escaping (String) -> Void = { _ in }
    ) -> SoundManager {
        SoundManager(defaults: defaults, availableSounds: testSounds, player: played)
    }

    // MARK: master toggle

    func test_soundsEnabled_defaultsToTrue() {
        XCTAssertTrue(makeManager().soundsEnabled)
    }

    // MARK: default seeding

    func test_init_seedsEachEventWithFirstAvailablePreferredDefault() {
        _ = makeManager()
        // agentTurnCompleted preferred = ["Ping", "Boop", "Pluck"]; "Ping" missing,
        // "Boop" present → "Boop".
        XCTAssertEqual(defaults.string(forKey: SoundEvent.agentTurnCompleted.storageKey), "Boop")
        // fifteenSecondsUntilCold preferred = ["Sosumi", "Sonumi", "Funk", "Funky"]; "Sonumi" wins.
        XCTAssertEqual(defaults.string(forKey: SoundEvent.fifteenSecondsUntilCold.storageKey), "Sonumi")
        // oneMinuteUntilCold preferred = ["Blow", "Breeze"]; "Breeze" wins.
        XCTAssertEqual(defaults.string(forKey: SoundEvent.oneMinuteUntilCold.storageKey), "Breeze")
        // newCold preferred = ["Submarine", "Submerge", "Sonar"]; "Submerge" wins.
        XCTAssertEqual(defaults.string(forKey: SoundEvent.newCold.storageKey), "Submerge")
        // coldHumanTurn preferred = ["Tink", "Pluck", "Pebble"]; "Tink" wins.
        XCTAssertEqual(defaults.string(forKey: SoundEvent.coldHumanTurn.storageKey), "Tink")
    }

    func test_init_fallsBackToFirstAvailableWhenNoPreferredMatches() {
        // Construct a SoundManager whose available list contains zero preferred names.
        let weirdSounds = ["Aardvark", "Zebra"]
        let m = SoundManager(defaults: defaults, availableSounds: weirdSounds, player: { _ in })
        _ = m
        // Each event falls back to the alphabetically-first available sound.
        for event in SoundEvent.allCases {
            XCTAssertEqual(defaults.string(forKey: event.storageKey), "Aardvark",
                           "fallback failed for \(event)")
        }
    }

    func test_init_doesNotOverwriteUserChoice() {
        defaults.set("Pluck", forKey: SoundEvent.agentTurnCompleted.storageKey)
        _ = makeManager()
        XCTAssertEqual(defaults.string(forKey: SoundEvent.agentTurnCompleted.storageKey), "Pluck")
    }

    // MARK: play(event)

    func test_play_invokesPlayerWithConfiguredSound() {
        var played: [String] = []
        let m = makeManager(played: { played.append($0) })
        m.play(.oneMinuteUntilCold)
        XCTAssertEqual(played, ["Breeze"])
    }

    func test_play_skipsPlayerWhenMasterDisabled() {
        var played: [String] = []
        let m = makeManager(played: { played.append($0) })
        m.soundsEnabled = false
        m.play(.agentTurnCompleted)
        XCTAssertEqual(played, [])
    }

    func test_play_skipsPlayerWhenPerEventSoundIsNone() {
        var played: [String] = []
        let m = makeManager(played: { played.append($0) })
        defaults.set("", forKey: SoundEvent.coldHumanTurn.storageKey)
        m.play(.coldHumanTurn)
        XCTAssertEqual(played, [])
    }

    // MARK: preview(soundName:)

    func test_preview_invokesPlayerEvenWhenMasterDisabled() {
        var played: [String] = []
        let m = makeManager(played: { played.append($0) })
        m.soundsEnabled = false
        m.preview(soundName: "Tink")
        XCTAssertEqual(played, ["Tink"])
    }

    func test_preview_isNoopForEmptyName() {
        var played: [String] = []
        let m = makeManager(played: { played.append($0) })
        m.preview(soundName: "")
        XCTAssertEqual(played, [])
    }
}
