import XCTest
@testable import Pits

final class SoundManagerTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "net.farriswheel.Pits.tests"

    override func setUp() {
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    func test_soundsEnabled_defaultsToTrue() {
        let m = SoundManager(defaults: defaults)
        XCTAssertTrue(m.soundsEnabled)
    }

    func test_playMessage_invokesPlayerWhenEnabled() {
        var played: [String] = []
        let m = SoundManager(defaults: defaults, player: { name in played.append(name) })
        m.playMessageReceived()
        XCTAssertEqual(played, ["Ping"])
    }

    func test_playMessage_skipsPlayerWhenDisabled() {
        var played: [String] = []
        let m = SoundManager(defaults: defaults, player: { name in played.append(name) })
        m.soundsEnabled = false
        m.playMessageReceived()
        XCTAssertEqual(played, [])
    }

    func test_playOneMinuteWarning_distinctSound() {
        var played: [String] = []
        let m = SoundManager(defaults: defaults, player: { name in played.append(name) })
        m.playOneMinuteWarning()
        XCTAssertEqual(played, ["Blow"])
    }
}
