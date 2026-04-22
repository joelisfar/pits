# Per-Sound Settings + Subagent Chime Filter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single "Play notification sounds" toggle with a macOS-style sound settings section: master toggle plus per-event sound pickers (with system sounds list and "None" to disable). Wire up two new chime events. Fix a latent bug where subagent turn completions trigger the "agent turn completed" chime.

**Architecture:** A new `SoundEvent` enum centralizes all chime events (id, label, storage key, preferred default sound list). A new `SystemSounds` helper enumerates `/System/Library/Sounds/` at runtime so the picker reflects what's actually installed (handles macOS 13 → 14 sound rename). `SoundManager` is rewritten with an event-keyed `play(_:)` API and a `preview(_:)` API that bypasses the master toggle. The `ConversationStore` chime predicate gains a `!isSubagent` check, the `transitionedToCold` event gets wired to a new chime, a new `coldHumanTurn` chime fires on `handleLines`, and `CacheTimer` adds a `.fifteenSecondWarning` event mirroring the existing 1-minute logic. `SettingsView` is split into "Sounds" and "Window" sections; the Sounds section discloses per-event picker rows when the master toggle is on.

**Tech Stack:** Swift 5.9+, SwiftUI, XCTest, AppKit (NSSound), macOS 14 deployment target. XcodeGen generates `Pits.xcodeproj` from `project.yml`; `xcodebuild` drives build & test.

**Spec:** [docs/superpowers/specs/2026-04-22-sound-settings-design.md](../specs/2026-04-22-sound-settings-design.md)

---

## File Map

| File | Role in this plan |
|------|-------------------|
| `Pits/Services/SoundEvent.swift` | **Create.** Enum of chime events with `label`, `storageKey`, `preferredDefaults`. |
| `Pits/Services/SystemSounds.swift` | **Create.** Helper that enumerates `*.aiff` files in a directory and strips extensions. |
| `Pits/Services/SoundManager.swift` | **Rewrite.** Event-keyed API: `play(_ event)` (master-gated) + `preview(soundName:)` (ungated). Seeds per-event defaults on init. |
| `Pits/Services/CacheTimer.swift` | **Modify.** Add `.fifteenSecondWarning(String)` event + per-conversation `warnedFifteenSeconds` tracking; mirror the 1-minute logic. |
| `Pits/Stores/ConversationStore.swift` | **Modify.** `handleLines` gets `!isSubagent` filter on the agent chime + new `coldHumanTurn` chime. `tick` wires `newCold` and `fifteenSecondWarning` events. |
| `Pits/Views/SoundEventRow.swift` | **Create.** One row: label, preview button, sound picker. Plays preview on selection change. |
| `Pits/Views/SettingsView.swift` | **Rewrite.** Split into "Sounds" / "Window" sections; Sounds section discloses per-event rows when master is on. Drop fixed height + `scrollDisabled`. |
| `PitsTests/SoundEventTests.swift` | **Create.** Unit tests for label / storageKey / preferredDefaults coverage. |
| `PitsTests/SystemSoundsTests.swift` | **Create.** Unit test for directory enumeration with a tmp directory. |
| `PitsTests/SoundManagerTests.swift` | **Rewrite.** Tests for `play(event)`, `preview(soundName:)`, default seeding, master/per-event gating. |
| `PitsTests/CacheTimerTests.swift` | **Modify.** Add tests for the 15-second warning event. |
| `PitsTests/ConversationStoreTests.swift` | **Modify.** Add subagent-filter test, cold-human-turn tests. Existing `test_chime_onlyFiresOnFinalTurns` updated to track `play(.agentTurnCompleted)` calls. |

---

## Test Commands

- **Full test suite:** `cd /Users/jifarris/Projects/pits && xcodegen generate && xcodebuild -project Pits.xcodeproj -scheme Pits -destination "platform=macOS,arch=$(uname -m)" test 2>&1 | tail -30`
- **Single test class:** Append `-only-testing:PitsTests/<ClassName>` after `test`. Faster inner loop (~5-10s vs ~20s for full).
- **Build + relaunch app:** `bash scripts/run.sh`

---

## Task 1: Subagent chime filter

**Files:**
- Modify: `Pits/Stores/ConversationStore.swift:265-290`
- Modify: `PitsTests/ConversationStoreTests.swift`

Smallest possible standalone fix — add `!t.isSubagent` to the existing chime predicate. This task does NOT touch `SoundManager`'s API; we still call `playMessageReceived()`. Later tasks rename that call.

- [ ] **Step 1: Write the failing test**

Add this test to `PitsTests/ConversationStoreTests.swift`, immediately after `test_chime_onlyFiresOnFinalTurns` (around line 99):

```swift
func test_chime_skipsSubagentFinalTurns() {
    var chimedRequestIds: [String] = []
    let store = makeStore()
    store.setChimeCutoffForTesting(.distantPast)
    store.onNewTurn = { t in chimedRequestIds.append(t.requestId) }

    let url = URL(fileURLWithPath: "/tmp/-a/a.jsonl")
    // Top-level end_turn — chimes.
    store.ingestForTesting(url: url, line: #"{"type":"assistant","sessionId":"s","requestId":"r_top","timestamp":"2026-04-21T10:00:00.000Z","message":{"model":"claude-opus-4-6","stop_reason":"end_turn","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#)
    // Subagent end_turn (presence of agentId marks it subagent) — must NOT chime.
    store.ingestForTesting(url: url, line: #"{"type":"assistant","sessionId":"s","requestId":"r_sub","agentId":"agent-7","timestamp":"2026-04-21T10:00:01.000Z","message":{"model":"claude-opus-4-6","stop_reason":"end_turn","usage":{"input_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":1}}}"#)

    XCTAssertEqual(chimedRequestIds, ["r_top"])
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/jifarris/Projects/pits && xcodegen generate && xcodebuild -project Pits.xcodeproj -scheme Pits -destination "platform=macOS,arch=$(uname -m)" -only-testing:PitsTests/ConversationStoreTests/test_chime_skipsSubagentFinalTurns test 2>&1 | tail -20
```

Expected: FAIL with `XCTAssertEqual failed: ("["r_top", "r_sub"]") is not equal to ("["r_top"]")`.

- [ ] **Step 3: Add the subagent guard**

Edit `Pits/Stores/ConversationStore.swift` lines 275-283. Find the block:

```swift
                // Chime only on *final* turns — the ones a human would notice
                // as "Claude is done talking". Intermediate tool_use turns (and
                // streaming fragments with no stop_reason yet) stay silent.
                if case .turn(let t) = entry,
                   t.timestamp > chimeCutoff,
                   let stop = t.stopReason, stop != "tool_use" {
                    sound.playMessageReceived()
                    onNewTurn?(t)
                }
```

Replace with:

```swift
                // Chime only on *final top-level* turns — the ones a human would
                // notice as "Claude is done talking". Intermediate tool_use turns,
                // streaming fragments with no stop_reason yet, and subagent turns
                // (the user's not waiting on those personally) stay silent.
                if case .turn(let t) = entry,
                   t.timestamp > chimeCutoff,
                   !t.isSubagent,
                   let stop = t.stopReason, stop != "tool_use" {
                    sound.playMessageReceived()
                    onNewTurn?(t)
                }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /Users/jifarris/Projects/pits && xcodebuild -project Pits.xcodeproj -scheme Pits -destination "platform=macOS,arch=$(uname -m)" -only-testing:PitsTests/ConversationStoreTests test 2>&1 | tail -20
```

Expected: PASS for the new test and all sibling `ConversationStoreTests`.

- [ ] **Step 5: Commit**

```bash
git add Pits/Stores/ConversationStore.swift PitsTests/ConversationStoreTests.swift
git commit -m "$(cat <<'EOF'
fix: skip subagent turn-completion chime

Subagent end_turn entries were firing the message-received chime,
producing chime spam during multi-agent runs. Filter them out at the
ConversationStore predicate; only top-level agent turns chime now.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: SoundEvent enum

**Files:**
- Create: `Pits/Services/SoundEvent.swift`
- Create: `PitsTests/SoundEventTests.swift`

A pure-data enum with no behavior beyond label / storage key / preferred-default lookups. No side effects, no I/O. Foundation for every later task.

- [ ] **Step 1: Write the failing test**

Create `PitsTests/SoundEventTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/jifarris/Projects/pits && xcodegen generate && xcodebuild -project Pits.xcodeproj -scheme Pits -destination "platform=macOS,arch=$(uname -m)" -only-testing:PitsTests/SoundEventTests test 2>&1 | tail -20
```

Expected: FAIL with `cannot find 'SoundEvent' in scope` (or build error referencing the new file).

- [ ] **Step 3: Create the enum**

Create `Pits/Services/SoundEvent.swift`:

```swift
import Foundation

/// User-configurable chime events. Each case has a stable raw value used in
/// UserDefaults keys, a human-readable label for the Settings UI, and a
/// priority list of preferred system sound names (the first one that exists
/// on the user's macOS install becomes the default).
enum SoundEvent: String, CaseIterable {
    case agentTurnCompleted
    case fifteenSecondsUntilCold
    case oneMinuteUntilCold
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
        case .coldHumanTurn:             return ["Tink", "Pluck", "Pebble"]
        }
    }
}
```

Also add the file to the Xcode project: edit `project.yml` to ensure the `Services` directory is auto-globbed (it already is, per `Pits/**/*.swift` patterns — confirm by inspecting `project.yml`). Then run `xcodegen generate` (already in step 4 below).

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /Users/jifarris/Projects/pits && xcodegen generate && xcodebuild -project Pits.xcodeproj -scheme Pits -destination "platform=macOS,arch=$(uname -m)" -only-testing:PitsTests/SoundEventTests test 2>&1 | tail -20
```

Expected: PASS, all 5 tests green.

- [ ] **Step 5: Commit**

```bash
git add Pits/Services/SoundEvent.swift PitsTests/SoundEventTests.swift
git commit -m "$(cat <<'EOF'
feat: add SoundEvent enum

Centralizes the five user-configurable chime events with their display
labels, namespaced storage keys, and per-event priority lists of
preferred system sounds (handles the macOS 13 → 14 sound rename).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: SystemSounds helper

**Files:**
- Create: `Pits/Services/SystemSounds.swift`
- Create: `PitsTests/SystemSoundsTests.swift`

Tiny pure-function helper that lists `*.aiff` files in a directory. Default callsite uses `/System/Library/Sounds`; tests pass a tmp directory.

- [ ] **Step 1: Write the failing test**

Create `PitsTests/SystemSoundsTests.swift`:

```swift
import XCTest
@testable import Pits

final class SystemSoundsTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pits-system-sounds-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func touch(_ name: String) throws {
        try Data().write(to: tmp.appendingPathComponent(name))
    }

    func test_enumerate_returnsAiffNamesWithoutExtension_sortedAlphabetically() throws {
        try touch("Pluck.aiff")
        try touch("Boop.aiff")
        try touch("Sonumi.aiff")
        XCTAssertEqual(SystemSounds.enumerate(at: tmp), ["Boop", "Pluck", "Sonumi"])
    }

    func test_enumerate_skipsNonAiffFiles() throws {
        try touch("Boop.aiff")
        try touch("README.txt")
        try touch(".DS_Store")
        XCTAssertEqual(SystemSounds.enumerate(at: tmp), ["Boop"])
    }

    func test_enumerate_returnsEmptyForMissingDirectory() {
        let bogus = URL(fileURLWithPath: "/nonexistent/path-\(UUID().uuidString)")
        XCTAssertEqual(SystemSounds.enumerate(at: bogus), [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/jifarris/Projects/pits && xcodegen generate && xcodebuild -project Pits.xcodeproj -scheme Pits -destination "platform=macOS,arch=$(uname -m)" -only-testing:PitsTests/SystemSoundsTests test 2>&1 | tail -20
```

Expected: FAIL with `cannot find 'SystemSounds' in scope`.

- [ ] **Step 3: Create the helper**

Create `Pits/Services/SystemSounds.swift`:

```swift
import Foundation

/// Enumerates installed macOS system sounds. Default location is
/// `/System/Library/Sounds`. Callers pass a custom directory only in tests.
enum SystemSounds {
    static let systemDirectory = URL(fileURLWithPath: "/System/Library/Sounds")

    /// Names of installed sounds (extension stripped, sorted alphabetically).
    static var available: [String] { enumerate(at: systemDirectory) }

    static func enumerate(at directory: URL) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        return names
            .filter { ($0 as NSString).pathExtension.lowercased() == "aiff" }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /Users/jifarris/Projects/pits && xcodegen generate && xcodebuild -project Pits.xcodeproj -scheme Pits -destination "platform=macOS,arch=$(uname -m)" -only-testing:PitsTests/SystemSoundsTests test 2>&1 | tail -20
```

Expected: PASS, all 3 tests green.

- [ ] **Step 5: Commit**

```bash
git add Pits/Services/SystemSounds.swift PitsTests/SystemSoundsTests.swift
git commit -m "$(cat <<'EOF'
feat: add SystemSounds enumeration helper

Lists installed *.aiff files in a sounds directory (default
/System/Library/Sounds) so the picker reflects what's actually on the
user's macOS install — handling the Sonoma sound rename gracefully.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Rewrite SoundManager

**Files:**
- Modify: `Pits/Services/SoundManager.swift` (full rewrite)
- Modify: `Pits/Stores/ConversationStore.swift` (call site rename: `playMessageReceived` → `play(.agentTurnCompleted)`, `playOneMinuteWarning` → `play(.oneMinuteUntilCold)`)
- Modify: `PitsTests/SoundManagerTests.swift` (full rewrite)

Replace the two hard-coded methods with one event-keyed `play(_:)` (master-gated) and a `preview(soundName:)` (ungated). Init seeds per-event defaults from `SoundEvent.preferredDefaults` against the available system sounds.

- [ ] **Step 1: Write the failing tests**

Replace the entire contents of `PitsTests/SoundManagerTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/jifarris/Projects/pits && xcodebuild -project Pits.xcodeproj -scheme Pits -destination "platform=macOS,arch=$(uname -m)" -only-testing:PitsTests/SoundManagerTests test 2>&1 | tail -25
```

Expected: build error — `SoundManager` has no `play(_:)`, no `availableSounds:` init param, no `preview(soundName:)`.

- [ ] **Step 3: Rewrite `SoundManager.swift`**

Replace the entire contents of `Pits/Services/SoundManager.swift`:

```swift
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
```

- [ ] **Step 4: Update ConversationStore call sites**

Edit `Pits/Stores/ConversationStore.swift`. Two changes:

In `handleLines` (~line 281), replace `sound.playMessageReceived()` with `sound.play(.agentTurnCompleted)`:

```swift
                if case .turn(let t) = entry,
                   t.timestamp > chimeCutoff,
                   !t.isSubagent,
                   let stop = t.stopReason, stop != "tool_use" {
                    sound.play(.agentTurnCompleted)
                    onNewTurn?(t)
                }
```

In `tick` (~line 311), replace `sound.playOneMinuteWarning()` with `sound.play(.oneMinuteUntilCold)`:

```swift
            switch e {
            case .oneMinuteWarning:
                sound.play(.oneMinuteUntilCold)
            case .transitionedToCold:
                // Derived values recompute on the next UI tick via
                // TimelineView — no snapshot rebuild required.
                break
            }
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd /Users/jifarris/Projects/pits && xcodebuild -project Pits.xcodeproj -scheme Pits -destination "platform=macOS,arch=$(uname -m)" -only-testing:PitsTests/SoundManagerTests test 2>&1 | tail -25
```

Expected: PASS for all `SoundManagerTests`.

- [ ] **Step 6: Run the full suite to catch any other breakage**

```bash
cd /Users/jifarris/Projects/pits && xcodebuild -project Pits.xcodeproj -scheme Pits -destination "platform=macOS,arch=$(uname -m)" test 2>&1 | tail -25
```

Expected: ALL PASS. (The existing `test_chime_skipsSubagentFinalTurns` and `test_chime_onlyFiresOnFinalTurns` continue passing — the silent player is still used by `play(.agentTurnCompleted)`.)

- [ ] **Step 7: Commit**

```bash
git add Pits/Services/SoundManager.swift Pits/Stores/ConversationStore.swift PitsTests/SoundManagerTests.swift
git commit -m "$(cat <<'EOF'
refactor: event-keyed SoundManager API

Replace playMessageReceived / playOneMinuteWarning with a single
play(SoundEvent) entry point and a preview(soundName:) method that
ignores the master toggle. SoundManager now reads the per-event sound
name from UserDefaults and seeds defaults from SoundEvent's preferred
list against installed system sounds at init.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Wire newCold chime in tick

**Files:**
- Modify: `Pits/Stores/ConversationStore.swift` (~line 308-317)
- Modify: `PitsTests/ConversationStoreTests.swift`

The `transitionedToCold` event already fires from `CacheTimer`; it's currently a no-op in the tick handler. Wire it up.

- [ ] **Step 1: Write the failing test**

Add to `PitsTests/ConversationStoreTests.swift`. We need to track player invocations, so refactor `makeStore` to accept an optional `playedRef` (or add a parallel helper). Add this helper near the existing `makeStore` (around line 6):

```swift
    /// JSONL timestamps require fractional seconds (see JSONLDecoder).
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Variant of makeStore that captures every sound name the SoundManager plays.
    private func makeStoreCapturingSounds(
        openSessionsWatcher: OpenSessionsWatcher = OpenSessionsWatcher(
            sessionsDirectory: URL(fileURLWithPath: "/nonexistent/sessions")
        )
    ) -> (ConversationStore, () -> [String]) {
        let played = NSMutableArray()
        let suite = "net.farriswheel.Pits.test-\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suite)!
        let sound = SoundManager(
            defaults: testDefaults,
            availableSounds: ["Boop", "Breeze", "Sonumi", "Submerge", "Tink"],
            player: { name in played.add(name) }
        )
        let store = ConversationStore(
            rootDirectory: URL(fileURLWithPath: "/nonexistent"),
            sound: sound,
            openSessionsWatcher: openSessionsWatcher
        )
        return (store, { played.compactMap { $0 as? String } })
    }
```

Then add the test (anywhere after the existing chime tests):

```swift
    func test_tick_playsNewCold_whenConversationTransitions() {
        let (store, played) = makeStoreCapturingSounds()
        store.setChimeCutoffForTesting(.distantPast)

        // Ingest a single warm assistant turn so the conversation is tracked.
        let url = URL(fileURLWithPath: "/tmp/-a/a.jsonl")
        // Pick a recent timestamp so cacheStatus computes meaningfully.
        let now = Date()
        let lineTs = isoFormatter.string(from: now)
        store.ingestForTesting(url: url, line: #"{"type":"assistant","sessionId":"s","requestId":"r","timestamp":"\#(lineTs)","message":{"model":"claude-opus-4-6","stop_reason":"end_turn","usage":{"input_tokens":1,"cache_creation_input_tokens":1000,"cache_read_input_tokens":0,"output_tokens":1}}}"#)

        // Synchronously force a tick at "now + 6 minutes" — past the 5m TTL.
        // tickForTesting is added in this same task (see step 3).
        store.tickForTesting(at: now.addingTimeInterval(360))

        XCTAssertTrue(played().contains("Submerge"),
                      "expected Submerge (newCold default in test universe), got \(played())")
    }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/jifarris/Projects/pits && xcodegen generate && xcodebuild -project Pits.xcodeproj -scheme Pits -destination "platform=macOS,arch=$(uname -m)" -only-testing:PitsTests/ConversationStoreTests/test_tick_playsNewCold_whenConversationTransitions test 2>&1 | tail -20
```

Expected: FAIL — either "no method tickForTesting" (build error) or assertion failure once the helper exists but the wiring doesn't.

- [ ] **Step 3: Add `tickForTesting` and wire the chime**

Edit `Pits/Stores/ConversationStore.swift`. Add this in the `// MARK: - Testing hooks` block (around line 232, after `setChimeCutoffForTesting`):

```swift
    /// Synchronously runs one cache-timer tick. Tests use this to drive
    /// transitionedToCold / oneMinuteWarning / fifteenSecondWarning events
    /// without scheduling a real Timer.
    func tickForTesting(at now: Date) {
        let events = cacheTimer.tick(
            conversations: conversations,
            at: now,
            openSessionIds: openSessionIds
        )
        for e in events {
            handle(timerEvent: e)
        }
    }
```

Refactor `tick` (~line 301-321) to delegate to a shared `handle(timerEvent:)`:

```swift
    private func tick() {
        refreshOpenSessionIds()
        let events = cacheTimer.tick(
            conversations: conversations,
            at: Date(),
            openSessionIds: openSessionIds
        )
        for e in events { handle(timerEvent: e) }
        // Force a publish so SwiftUI pulls the latest `conversations` snapshot
        // and any subscribers (like TimelineView consumers) reflect new state.
        objectWillChange.send()
    }

    private func handle(timerEvent e: CacheTimerEvent) {
        switch e {
        case .oneMinuteWarning:
            sound.play(.oneMinuteUntilCold)
        case .transitionedToCold:
            // Cache just expired — chime so the user knows the next message
            // starts fresh. Derived values recompute on the next UI tick via
            // TimelineView, so no snapshot rebuild is needed.
            sound.play(.newCold)
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /Users/jifarris/Projects/pits && xcodebuild -project Pits.xcodeproj -scheme Pits -destination "platform=macOS,arch=$(uname -m)" -only-testing:PitsTests/ConversationStoreTests test 2>&1 | tail -25
```

Expected: PASS, including the new `test_tick_playsNewCold_whenConversationTransitions`.

- [ ] **Step 5: Commit**

```bash
git add Pits/Stores/ConversationStore.swift PitsTests/ConversationStoreTests.swift
git commit -m "$(cat <<'EOF'
feat: chime when a conversation transitions to cold

Wire the existing CacheTimer.transitionedToCold event to play the
newCold chime, signalling that the next message will start a fresh
cache window. Adds tickForTesting + extracts handle(timerEvent:) so
tests can drive single ticks deterministically.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: 15-second warning event in CacheTimer

**Files:**
- Modify: `Pits/Services/CacheTimer.swift`
- Modify: `PitsTests/CacheTimerTests.swift`

Mirror the existing `oneMinuteWarning` logic for a 15-second threshold. Same pattern: emit once per warm period, suppress for closed sessions, suppress on first observation if already inside the window, reset when a new turn warms the cache.

- [ ] **Step 1: Write the failing tests**

Add these tests to `PitsTests/CacheTimerTests.swift` after `test_tick_emitsOneMinuteWarning_onceOnly` (around line 58):

```swift
    func test_tick_emitsFifteenSecondWarning_onceOnly() {
        let timer = CacheTimer()
        let convs = [conversation(id: "s", lastResponse: 1000, ttl: 300)]

        // 16 seconds remaining: no 15s warning yet.
        let events1 = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1284), openSessionIds: ["s"])
        XCTAssertFalse(events1.contains(.fifteenSecondWarning("s")), "got: \(events1)")

        // 14 seconds remaining: warning fires.
        let events2 = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1286), openSessionIds: ["s"])
        XCTAssertTrue(events2.contains(.fifteenSecondWarning("s")), "got: \(events2)")

        // Subsequent ticks in the warning window: no repeat.
        let events3 = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1290), openSessionIds: ["s"])
        XCTAssertFalse(events3.contains(.fifteenSecondWarning("s")), "got: \(events3)")
    }

    func test_tick_suppressesFifteenSecondWarning_whenSessionNotOpen() {
        let timer = CacheTimer()
        let convs = [conversation(id: "s", lastResponse: 1000, ttl: 300)]
        // Establish state outside both warning windows.
        _ = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1100), openSessionIds: [])
        // Cross into 15s window with session closed.
        let events = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1289), openSessionIds: [])
        XCTAssertFalse(events.contains(.fifteenSecondWarning("s")), "got: \(events)")
    }

    func test_tick_suppressesFifteenSecondWarning_onFirstObservation_whenAlreadyInWindow() {
        let timer = CacheTimer()
        let convs = [conversation(id: "s", lastResponse: 1000, ttl: 300)]
        // First observation already inside the 15s window.
        _ = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1289), openSessionIds: [])
        // Reopen later, still inside: no warning.
        let events = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1292), openSessionIds: ["s"])
        XCTAssertFalse(events.contains(.fifteenSecondWarning("s")), "got: \(events)")
    }

    func test_warmAfterNewTurn_resetsFifteenSecondWarning() {
        let timer = CacheTimer()
        var convs = [conversation(id: "s", lastResponse: 1000, ttl: 300)]
        // Fire and consume the 15s warning.
        _ = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1100), openSessionIds: ["s"])
        _ = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1289), openSessionIds: ["s"])
        // New assistant reply at ts=1500 — cache warmed again.
        convs = [conversation(id: "s", lastResponse: 1500, ttl: 300)]
        // Tick well outside warning window first to refresh state.
        _ = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1550), openSessionIds: ["s"])
        // Cross into 15s window of the *new* warm period.
        let events = timer.tick(conversations: convs, at: Date(timeIntervalSince1970: 1789), openSessionIds: ["s"])
        XCTAssertTrue(events.contains(.fifteenSecondWarning("s")), "got: \(events)")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/jifarris/Projects/pits && xcodebuild -project Pits.xcodeproj -scheme Pits -destination "platform=macOS,arch=$(uname -m)" -only-testing:PitsTests/CacheTimerTests test 2>&1 | tail -25
```

Expected: build error — `.fifteenSecondWarning` not a member of `CacheTimerEvent`.

- [ ] **Step 3: Add the event + state machine logic**

Replace the entire contents of `Pits/Services/CacheTimer.swift`:

```swift
import Foundation

enum CacheTimerEvent: Equatable {
    case transitionedToCold(String)     // conversation id
    case oneMinuteWarning(String)       // conversation id
    case fifteenSecondWarning(String)   // conversation id
}

/// Pure state machine that, on each tick, diffs current vs. previous cache
/// status and remaining time to emit transition + warning events.
final class CacheTimer {
    private struct Snapshot {
        var status: CacheStatus
        var warnedOneMinute: Bool
        var warnedFifteenSeconds: Bool
        var lastResponse: Date?
    }

    private var states: [String: Snapshot] = [:]

    /// Advance all tracked conversations to `now`. Returns events to act on.
    ///
    /// `openSessionIds` gates user-facing warnings: sessions whose id is not in
    /// the set are treated as closed tabs and do not emit warning events
    /// (there's no user to warn). Internal state still tracks warm/cold
    /// transitions so that a subsequent reopen-within-window can fire normally.
    func tick(conversations: [Conversation], at now: Date, openSessionIds: Set<String>) -> [CacheTimerEvent] {
        var events: [CacheTimerEvent] = []
        var seen = Set<String>()

        for c in conversations {
            seen.insert(c.id)
            let status = c.cacheStatus(at: now)
            let remaining = c.cacheTTLRemaining(at: now)
            let last = c.lastResponseTimestamp

            if var prev = states[c.id] {
                // If there's a newer response than we last knew about, the cache
                // has been refreshed — reset both warnings so they can fire again
                // in the new warm period. `prev.status` is overwritten below
                // with the freshly-computed status; we don't pretend it was `.warm`.
                if let prevLast = prev.lastResponse, let newLast = last, newLast > prevLast {
                    prev.warnedOneMinute = false
                    prev.warnedFifteenSeconds = false
                }
                // Transition warm → cold fires once.
                if prev.status == .warm && status == .cold {
                    events.append(.transitionedToCold(c.id))
                }
                // One-minute warning fires once per warm period, only for open sessions.
                if status == .warm, remaining <= 60, !prev.warnedOneMinute,
                   openSessionIds.contains(c.id) {
                    events.append(.oneMinuteWarning(c.id))
                    prev.warnedOneMinute = true
                }
                // Fifteen-second warning fires once per warm period, only for open sessions.
                if status == .warm, remaining <= 15, !prev.warnedFifteenSeconds,
                   openSessionIds.contains(c.id) {
                    events.append(.fifteenSecondWarning(c.id))
                    prev.warnedFifteenSeconds = true
                }
                prev.status = status
                prev.lastResponse = last
                states[c.id] = prev
            } else {
                // First observation: no events, just record state. If we first
                // see the conversation already inside a warning window, mark
                // that warning as already-fired — we only alert on *entry*.
                var snap = Snapshot(
                    status: status,
                    warnedOneMinute: false,
                    warnedFifteenSeconds: false,
                    lastResponse: last
                )
                if status == .warm, remaining <= 60 { snap.warnedOneMinute = true }
                if status == .warm, remaining <= 15 { snap.warnedFifteenSeconds = true }
                states[c.id] = snap
            }
        }

        // Drop state for conversations that disappeared.
        states = states.filter { seen.contains($0.key) }
        return events
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/jifarris/Projects/pits && xcodebuild -project Pits.xcodeproj -scheme Pits -destination "platform=macOS,arch=$(uname -m)" -only-testing:PitsTests/CacheTimerTests test 2>&1 | tail -25
```

Expected: PASS for all `CacheTimerTests` (existing 1-minute tests still pass — same logic, parallel state field).

- [ ] **Step 5: Commit**

```bash
git add Pits/Services/CacheTimer.swift PitsTests/CacheTimerTests.swift
git commit -m "$(cat <<'EOF'
feat: 15-second cache warning event in CacheTimer

Mirrors the one-minute warning logic for a 15-second threshold: emits
once per warm period, suppressed for closed sessions, suppressed on
first observation if already inside the window, resets when a new turn
warms the cache.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Wire 15-second chime in ConversationStore tick

**Files:**
- Modify: `Pits/Stores/ConversationStore.swift` (in `handle(timerEvent:)`)
- Modify: `PitsTests/ConversationStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Add to `PitsTests/ConversationStoreTests.swift`:

```swift
    func test_tick_playsFifteenSecondWarning() {
        let (store, played) = makeStoreCapturingSounds()
        store.setChimeCutoffForTesting(.distantPast)

        // Assistant turn from 200s ago → 100s remaining (warm, outside both
        // warning windows). CacheTimer needs a first-tick baseline outside
        // the window so the second tick can detect entry into the window.
        let now = Date()
        let lineTs = isoFormatter.string(from: now.addingTimeInterval(-200))
        let url = URL(fileURLWithPath: "/tmp/-a/a.jsonl")
        store.ingestForTesting(url: url, line: #"{"type":"assistant","sessionId":"s","requestId":"r","timestamp":"\#(lineTs)","message":{"model":"claude-opus-4-6","stop_reason":"end_turn","usage":{"input_tokens":1,"cache_creation_input_tokens":1000,"cache_read_input_tokens":0,"output_tokens":1}}}"#)

        // Session must be open for warnings to fire; setOpenSessionIdsForTesting
        // is added alongside the chime wiring in step 3.
        store.setOpenSessionIdsForTesting(["s"])
        // Baseline tick: 100s remaining — warm, outside 60s and 15s windows.
        store.tickForTesting(at: now)
        // Cross into the 15s window: remaining = 300 - (200 + 85) = 15s.
        // Both oneMinuteWarning and fifteenSecondWarning fire in the same tick
        // (we crossed both thresholds in one jump); the 15s warning is what
        // this test asserts on.
        store.tickForTesting(at: now.addingTimeInterval(85))

        XCTAssertTrue(played().contains("Sonumi"),
                      "expected Sonumi (15s default in test universe), got \(played())")
    }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/jifarris/Projects/pits && xcodebuild -project Pits.xcodeproj -scheme Pits -destination "platform=macOS,arch=$(uname -m)" -only-testing:PitsTests/ConversationStoreTests/test_tick_playsFifteenSecondWarning test 2>&1 | tail -20
```

Expected: build error — `setOpenSessionIdsForTesting` does not exist; or assertion failure once the helper exists.

- [ ] **Step 3: Add testing helper + wire the chime**

Edit `Pits/Stores/ConversationStore.swift`. Add to the testing hooks block:

```swift
    func setOpenSessionIdsForTesting(_ ids: Set<String>) {
        openSessionIds = ids
    }
```

Update `handle(timerEvent:)` (added in Task 5) to handle the new case:

```swift
    private func handle(timerEvent e: CacheTimerEvent) {
        switch e {
        case .fifteenSecondWarning:
            sound.play(.fifteenSecondsUntilCold)
        case .oneMinuteWarning:
            sound.play(.oneMinuteUntilCold)
        case .transitionedToCold:
            sound.play(.newCold)
        }
    }
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /Users/jifarris/Projects/pits && xcodebuild -project Pits.xcodeproj -scheme Pits -destination "platform=macOS,arch=$(uname -m)" -only-testing:PitsTests/ConversationStoreTests test 2>&1 | tail -25
```

Expected: PASS, including the new test.

- [ ] **Step 5: Commit**

```bash
git add Pits/Stores/ConversationStore.swift PitsTests/ConversationStoreTests.swift
git commit -m "$(cat <<'EOF'
feat: chime on 15-second cache warning

Wire the new CacheTimer.fifteenSecondWarning event to the
fifteenSecondsUntilCold sound. Also add a setOpenSessionIdsForTesting
helper so timer-driven tests can simulate user-open sessions without
touching the filesystem watcher.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Cold-human-turn chime in handleLines

**Files:**
- Modify: `Pits/Stores/ConversationStore.swift` (`handleLines`, ~line 265-290)
- Modify: `PitsTests/ConversationStoreTests.swift`

When a user sends a message into a conversation whose cache has already gone cold, fire a chime. Skip subagent humans, skip backfill (`> chimeCutoff`), skip `.new` and `.warm` (only `.cold` qualifies).

- [ ] **Step 1: Write the failing tests**

Add to `PitsTests/ConversationStoreTests.swift`:

```swift
    func test_coldHumanTurn_playsChime_whenConversationIsCold() {
        let (store, played) = makeStoreCapturingSounds()
        store.setChimeCutoffForTesting(.distantPast)

        // Step 1: ingest a stale assistant turn so the conversation exists with an
        // observed TTL. Use a far-past timestamp so it's already cold.
        let url = URL(fileURLWithPath: "/tmp/-a/a.jsonl")
        store.ingestForTesting(url: url, line: #"{"type":"assistant","sessionId":"s","requestId":"r","timestamp":"2026-04-21T10:00:00.000Z","message":{"model":"claude-opus-4-6","stop_reason":"end_turn","usage":{"input_tokens":1,"cache_creation_input_tokens":1000,"cache_read_input_tokens":0,"output_tokens":1}}}"#)

        // Sanity: conversation has an observed TTL (5m write tokens present).
        XCTAssertNotNil(store.conversations.first?.observedTTLSeconds)

        // Step 2: ingest a non-subagent human turn well after the TTL expired.
        store.ingestForTesting(url: url, line: #"{"type":"user","sessionId":"s","timestamp":"2026-04-22T10:00:00.000Z","message":{"role":"user","content":"hello again"}}"#)

        XCTAssertTrue(played().contains("Tink"),
                      "expected Tink (coldHumanTurn default in test universe), got \(played())")
    }

    func test_coldHumanTurn_silent_whenConversationIsWarm() {
        let (store, played) = makeStoreCapturingSounds()
        store.setChimeCutoffForTesting(.distantPast)

        let url = URL(fileURLWithPath: "/tmp/-a/a.jsonl")
        // Recent assistant turn → still warm.
        let now = Date()
        let recentTs = isoFormatter.string(from: now.addingTimeInterval(-30))
        let humanTs = isoFormatter.string(from: now)
        store.ingestForTesting(url: url, line: #"{"type":"assistant","sessionId":"s","requestId":"r","timestamp":"\#(recentTs)","message":{"model":"claude-opus-4-6","stop_reason":"end_turn","usage":{"input_tokens":1,"cache_creation_input_tokens":1000,"cache_read_input_tokens":0,"output_tokens":1}}}"#)
        store.ingestForTesting(url: url, line: #"{"type":"user","sessionId":"s","timestamp":"\#(humanTs)","message":{"role":"user","content":"hi"}}"#)

        XCTAssertFalse(played().contains("Tink"), "warm conv should not chime, got \(played())")
    }

    func test_coldHumanTurn_silent_whenConversationIsNew() {
        let (store, played) = makeStoreCapturingSounds()
        store.setChimeCutoffForTesting(.distantPast)

        // No assistant turn yet → cacheStatus == .new → no chime.
        let url = URL(fileURLWithPath: "/tmp/-a/a.jsonl")
        store.ingestForTesting(url: url, line: #"{"type":"user","sessionId":"s","timestamp":"2026-04-22T10:00:00.000Z","message":{"role":"user","content":"first message"}}"#)

        XCTAssertFalse(played().contains("Tink"), "new conv should not chime, got \(played())")
    }

    func test_coldHumanTurn_silent_forSubagentHumans() {
        let (store, played) = makeStoreCapturingSounds()
        store.setChimeCutoffForTesting(.distantPast)

        let url = URL(fileURLWithPath: "/tmp/-a/a.jsonl")
        // Stale assistant turn → cold.
        store.ingestForTesting(url: url, line: #"{"type":"assistant","sessionId":"s","requestId":"r","timestamp":"2026-04-21T10:00:00.000Z","message":{"model":"claude-opus-4-6","stop_reason":"end_turn","usage":{"input_tokens":1,"cache_creation_input_tokens":1000,"cache_read_input_tokens":0,"output_tokens":1}}}"#)
        // Subagent human (agentId present) → must NOT chime.
        store.ingestForTesting(url: url, line: #"{"type":"user","sessionId":"s","agentId":"agent-7","timestamp":"2026-04-22T10:00:00.000Z","message":{"role":"user","content":"subagent prompt"}}"#)

        XCTAssertFalse(played().contains("Tink"), "subagent human should not chime, got \(played())")
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/jifarris/Projects/pits && xcodebuild -project Pits.xcodeproj -scheme Pits -destination "platform=macOS,arch=$(uname -m)" -only-testing:PitsTests/ConversationStoreTests test 2>&1 | tail -25
```

Expected: FAIL — `test_coldHumanTurn_playsChime_whenConversationIsCold` (no chime fires yet).

- [ ] **Step 3: Wire the chime in handleLines**

Edit `Pits/Stores/ConversationStore.swift`. Find the body of `handleLines` (~line 265). Add a new conditional block after the existing turn-completed chime block, before `parser.ingest(line: line)`:

```swift
                // Cold-human-turn chime: a non-subagent human entry landing in a
                // conversation whose cache has already gone cold. Lookup uses
                // the *pre-ingest* `conversations` snapshot — the new human
                // entry doesn't change cache state, only assistant turns do.
                // Skips `.new` so a fresh conversation's first message is silent.
                if case .human(let h) = entry,
                   h.timestamp > chimeCutoff,
                   !h.isSubagent,
                   let conv = conversations.first(where: { $0.id == h.sessionId }),
                   conv.cacheStatus(at: h.timestamp) == .cold {
                    sound.play(.coldHumanTurn)
                }
```

The full block in `handleLines` for a single line should now read:

```swift
            if let entry = JSONLDecoder.decode(line: line) {
                let sid: String
                switch entry {
                case .turn(let t): sid = t.sessionId
                case .human(let h): sid = h.sessionId
                case .title(let st): sid = st.sessionId
                }
                if fileBySession[sid] == nil { fileBySession[sid] = url }

                if case .turn(let t) = entry,
                   t.timestamp > chimeCutoff,
                   !t.isSubagent,
                   let stop = t.stopReason, stop != "tool_use" {
                    sound.play(.agentTurnCompleted)
                    onNewTurn?(t)
                }

                if case .human(let h) = entry,
                   h.timestamp > chimeCutoff,
                   !h.isSubagent,
                   let conv = conversations.first(where: { $0.id == h.sessionId }),
                   conv.cacheStatus(at: h.timestamp) == .cold {
                    sound.play(.coldHumanTurn)
                }
            }
            parser.ingest(line: line)
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/jifarris/Projects/pits && xcodebuild -project Pits.xcodeproj -scheme Pits -destination "platform=macOS,arch=$(uname -m)" -only-testing:PitsTests/ConversationStoreTests test 2>&1 | tail -25
```

Expected: PASS for all four new `coldHumanTurn` tests + all existing `ConversationStoreTests`.

- [ ] **Step 5: Commit**

```bash
git add Pits/Stores/ConversationStore.swift PitsTests/ConversationStoreTests.swift
git commit -m "$(cat <<'EOF'
feat: chime when typing into a cold conversation

When the user sends a non-subagent human turn into a conversation whose
cache has already gone cold, play the coldHumanTurn chime as a
heads-up that the next message starts fresh (no cache reuse). Skips
.new conversations (first message in a fresh thread is silent) and
subagent humans.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: SoundEventRow view

**Files:**
- Create: `Pits/Views/SoundEventRow.swift`

A single row used by the Settings UI: label + speaker preview button + sound picker. Picker change auto-plays the new sound; preview button replays the current selection.

No unit test — SwiftUI views are exercised by the manual smoke test in Task 11. The visual + interaction behavior is the contract.

- [ ] **Step 1: Create the row view**

Create `Pits/Views/SoundEventRow.swift`:

```swift
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
```

- [ ] **Step 2: Verify the project builds**

```bash
cd /Users/jifarris/Projects/pits && xcodegen generate && xcodebuild -project Pits.xcodeproj -scheme Pits -destination "platform=macOS,arch=$(uname -m)" -configuration Debug build 2>&1 | tail -15
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Pits/Views/SoundEventRow.swift
git commit -m "$(cat <<'EOF'
feat: SoundEventRow view for per-event sound picker

Single Settings row: label, speaker preview button, sound name picker
with None at top + system sounds. Auto-previews on picker change to
match macOS System Settings → Sound behavior.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 10: SettingsView rewrite

**Files:**
- Modify: `Pits/Views/SettingsView.swift`

Split into two `Section`s: "Sounds" (master toggle + per-event rows when on) and "Window" (existing `Keep window on top` and `Launch at login`). Drop the fixed `height: 180` and `.scrollDisabled(true)` so the window resizes naturally as rows reveal.

- [ ] **Step 1: Rewrite the view**

Replace the entire contents of `Pits/Views/SettingsView.swift`:

```swift
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @AppStorage(SoundManager.soundsEnabledKey) private var soundsEnabled: Bool = true
    @AppStorage("net.farriswheel.Pits.alwaysOnTop") private var alwaysOnTop: Bool = false
    @State private var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)
    @State private var launchError: String?

    private let availableSounds = SystemSounds.available
    private let soundManager = SoundManager()

    var body: some View {
        Form {
            Section("Sounds") {
                Toggle("Play notification sounds", isOn: $soundsEnabled)
                if soundsEnabled {
                    ForEach(SoundEvent.allCases, id: \.self) { event in
                        SoundEventRow(
                            event: event,
                            availableSounds: availableSounds,
                            soundManager: soundManager
                        )
                    }
                }
            }
            Section("Window") {
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
        .frame(width: 440)
    }
}
```

- [ ] **Step 2: Verify the project builds**

```bash
cd /Users/jifarris/Projects/pits && xcodegen generate && xcodebuild -project Pits.xcodeproj -scheme Pits -destination "platform=macOS,arch=$(uname -m)" -configuration Debug build 2>&1 | tail -15
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Pits/Views/SettingsView.swift
git commit -m "$(cat <<'EOF'
feat: per-sound picker UI in SettingsView

Split Settings into Sounds and Window sections. The Sounds section
discloses per-event picker rows under the master toggle (rows hidden
when master is off). Drop the fixed height + scrollDisabled so the
window resizes naturally with disclosure.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 11: Build, smoke test, full suite

**Files:** none — this is the verification gate.

- [ ] **Step 1: Run the full test suite**

```bash
cd /Users/jifarris/Projects/pits && xcodegen generate && xcodebuild -project Pits.xcodeproj -scheme Pits -destination "platform=macOS,arch=$(uname -m)" test 2>&1 | tail -30
```

Expected: ALL TESTS PASSED.

- [ ] **Step 2: Build and launch the app**

```bash
bash /Users/jifarris/Projects/pits/scripts/run.sh
```

Expected: app builds and launches; menu bar icon appears.

- [ ] **Step 3: Manual smoke test — Settings UI**

Open Pits → Settings (⌘,). Verify:

- "Sounds" section header is visible at top.
- "Play notification sounds" toggle is at top of the section, defaulting to ON.
- Five per-event rows appear below it: "Agent turn completed", "15 seconds until cold", "1 minute until cold", "New cold status", "Cold human turn".
- Each row shows: label on the left, speaker icon, picker on the right.
- Toggling the master OFF hides all five rows; toggling back ON re-reveals them.
- Each picker dropdown lists "None" at the top, then system sounds alphabetically.
- Selecting a different sound in any picker plays that sound immediately.
- Selecting "None" plays nothing; the speaker button becomes disabled.
- Clicking the speaker button replays the currently-selected sound.
- "Window" section appears below "Sounds" with "Keep window on top" and "Launch at login".

- [ ] **Step 4: Manual smoke test — chime behavior**

Verifying chimes requires running real Claude Code sessions, which is environment-specific. At minimum, confirm by reading the code path that:

- `agentTurnCompleted` chimes only on top-level final assistant turns (not subagent, not tool_use).
- `coldHumanTurn` only fires when typing into a conversation whose `cacheStatus` is `.cold` (not warm or new).

A faster-than-real-time check: open Pits with `scripts/smoke-fake-session.sh` if it produces sessions; otherwise rely on the unit tests as the behavioral contract and validate live during normal use.

- [ ] **Step 5: Final wrap-up commit (only if any tweaks were needed)**

If smoke testing surfaces any issues, fix them in a focused follow-up commit. Otherwise this task is informational only — no commit.

---

## Self-Review

- [x] Spec coverage: subagent fix (T1), SoundEvent enum (T2), SystemSounds (T3), SoundManager rewrite (T4), newCold wiring (T5), 15s event in CacheTimer (T6), 15s wiring in store (T7), coldHumanTurn (T8), SoundEventRow (T9), SettingsView rewrite (T10), smoke test (T11). All five sound events configurable; preview behavior matches spec (auto-play on selection, replay button); migration is no-op (defaults seeded idempotently); subagent filter applied.
- [x] Placeholders: none. All code blocks complete; all test commands have `Expected:` lines; all commit messages are concrete.
- [x] Type consistency: `SoundEvent.allCases`, `play(_:)`, `preview(soundName:)`, `soundsEnabled`, `soundName(for:)` used identically in tests and implementation across tasks. `CacheTimerEvent.fifteenSecondWarning` used identically in CacheTimer tests and the store wiring. `SoundEventRow.init` signature matches its only caller in `SettingsView`.
- [x] Branch policy: User memory says all in-flight work goes on the `vX.Y.Z` branch. Worktree is already on `v0.1.8`. No PR until release time.
