import XCTest
@testable import Shhhcribble

/// Pins the hotkey-release branch. The load-bearing case is `.toggle` never
/// ending a recording on keyUp — that immunity to a stalled recording start is
/// the whole reason the explicit modes were brought back.
final class ActivationModeTests: XCTestCase {

    private let threshold: TimeInterval = 0.5

    // MARK: Toggle — keyUp is inert

    func testToggleNeverEndsOnKeyUp() {
        for held: TimeInterval? in [nil, 0, 0.1, 0.49, 0.5, 2.0, 60.0] {
            XCTAssertFalse(
                ModelManager.ActivationMode.toggle
                    .keyUpShouldEndRecording(heldFor: held, holdThreshold: threshold),
                "toggle must ignore keyUp regardless of hold (\(String(describing: held)))")
        }
    }

    // MARK: Push-to-talk — keyUp always ends

    func testPushToTalkAlwaysEndsOnKeyUp() {
        for held: TimeInterval? in [nil, 0, 0.1, 5.0] {
            XCTAssertTrue(
                ModelManager.ActivationMode.pushToTalk
                    .keyUpShouldEndRecording(heldFor: held, holdThreshold: threshold),
                "push-to-talk must end on release regardless of hold")
        }
    }

    // MARK: Automatic — threshold decides

    func testAutomaticEndsOnlyWhenHeldPastThreshold() {
        let auto = ModelManager.ActivationMode.automatic
        XCTAssertFalse(auto.keyUpShouldEndRecording(heldFor: 0.1, holdThreshold: threshold))
        XCTAssertFalse(auto.keyUpShouldEndRecording(heldFor: 0.49, holdThreshold: threshold))
        XCTAssertTrue(auto.keyUpShouldEndRecording(heldFor: 0.5, holdThreshold: threshold),
                      "exactly at the threshold counts as a hold")
        XCTAssertTrue(auto.keyUpShouldEndRecording(heldFor: 3.0, holdThreshold: threshold))
    }

    /// A missing start timestamp must not be read as a zero-length hold that
    /// somehow ends the recording — it means we never saw the keyDown.
    func testAutomaticIgnoresKeyUpWithNoRecordedStart() {
        XCTAssertFalse(
            ModelManager.ActivationMode.automatic
                .keyUpShouldEndRecording(heldFor: nil, holdThreshold: threshold))
    }

    // MARK: Persistence

    func testDefaultsToAutomaticAndDoesNotReadTheLegacyKey() {
        let defaults = UserDefaults.standard
        let legacyKey = "activationMode"
        let liveKey = "activationModeV2"
        let savedLegacy = defaults.string(forKey: legacyKey)
        let savedLive = defaults.string(forKey: liveKey)
        defer {
            defaults.set(savedLegacy, forKey: legacyKey)
            defaults.set(savedLive, forKey: liveKey)
        }

        // A stale pre-smart-activation preference must not resurrect itself.
        defaults.set("pushToTalk", forKey: legacyKey)
        defaults.removeObject(forKey: liveKey)
        XCTAssertEqual(ModelManager.activationMode, .automatic)
    }

    func testRoundTripsThroughDefaults() {
        let key = "activationModeV2"
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        for mode in ModelManager.ActivationMode.allCases {
            ModelManager.activationMode = mode
            XCTAssertEqual(ModelManager.activationMode, mode)
        }
    }

    func testUnrecognisedStoredValueFallsBackToAutomatic() {
        let key = "activationModeV2"
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        UserDefaults.standard.set("nonsense", forKey: key)
        XCTAssertEqual(ModelManager.activationMode, .automatic)
    }

    func testEveryModeHasDistinctUserFacingCopy() {
        let labels = Set(ModelManager.ActivationMode.allCases.map(\.label))
        let details = Set(ModelManager.ActivationMode.allCases.map(\.detail))
        XCTAssertEqual(labels.count, ModelManager.ActivationMode.allCases.count)
        XCTAssertEqual(details.count, ModelManager.ActivationMode.allCases.count)
    }
}
