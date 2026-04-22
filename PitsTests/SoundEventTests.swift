import XCTest
@testable import Pits

final class SoundEventTests: XCTestCase {
    func test_allCases_haveDistinctStorageKeys() {
        let keys = SoundEvent.allCases.map(\.storageKey)
        XCTAssertEqual(Set(keys).count, keys.count, "storage keys must be unique")
    }

    func test_allCases_haveNonEmptyLabels() {
        for event in SoundEvent.allCases {
            XCTAssertFalse(event.label.isEmpty, "missing label for \(event)")
        }
    }

    func test_allCases_haveNonEmptyPreferredDefaults() {
        for event in SoundEvent.allCases {
            XCTAssertFalse(event.preferredDefaults.isEmpty, "no defaults for \(event)")
        }
    }

    func test_storageKey_isStableNamespacedString() {
        XCTAssertEqual(SoundEvent.agentTurnCompleted.storageKey,
                       "net.farriswheel.Pits.sound.agentTurnCompleted")
        XCTAssertEqual(SoundEvent.fifteenSecondsUntilCold.storageKey,
                       "net.farriswheel.Pits.sound.fifteenSecondsUntilCold")
    }

    func test_eventCount_matchesSpec() {
        // Lock the count so accidental additions/removals are caught.
        XCTAssertEqual(SoundEvent.allCases.count, 5)
    }
}
