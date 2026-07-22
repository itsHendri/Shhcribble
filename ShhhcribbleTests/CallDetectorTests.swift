import XCTest
@testable import Shhhcribble

/// Pins the pure attribution logic of call detection. The HAL plumbing is
/// hardware-only; what must never regress silently is which bundle ids count
/// as a call app and how a match is picked.
final class CallDetectorTests: XCTestCase {

    func testKnownCallAppMatches() {
        let match = CallDetector.firstKnownCallApp(in: ["net.whatsapp.WhatsApp"])
        XCTAssertEqual(match?.name, "WhatsApp")
    }

    func testUnknownAppsDoNotMatch() {
        XCTAssertNil(CallDetector.firstKnownCallApp(in: [
            "com.apple.QuickTimePlayerX",   // screen/audio recorder — not a call
            "com.apple.VoiceMemos",
            "com.google.Chrome",            // browser calls are out of scope v1
            "com.spotify.client",
        ]))
    }

    func testEmptyListDoesNotMatch() {
        XCTAssertNil(CallDetector.firstKnownCallApp(in: []))
    }

    /// A call app hiding among unknown apps is still found.
    func testMatchAmongOtherMicUsers() {
        let match = CallDetector.firstKnownCallApp(
            in: ["com.example.someapp", "us.zoom.xos", "com.other.thing"])
        XCTAssertEqual(match?.name, "Zoom")
    }

    /// Electron call apps run audio in a ".helper" child process — observed
    /// live: Slack's mic input attributes to com.tinyspeck.slackmacgap.helper.
    /// The helper must match its parent.
    func testElectronHelperMatchesParentApp() {
        let slack = CallDetector.firstKnownCallApp(in: ["com.tinyspeck.slackmacgap.helper"])
        XCTAssertEqual(slack?.name, "Slack")
        let zoom = CallDetector.firstKnownCallApp(in: ["us.zoom.xos.Helper"])
        XCTAssertEqual(zoom?.name, "Zoom", "suffix match is case-insensitive")
    }

    /// Non-helper lookalike suffixes still must not trigger.
    func testLookalikeSuffixDoesNotMatch() {
        XCTAssertNil(CallDetector.firstKnownCallApp(in: ["net.whatsapp.WhatsApp.ServiceExtension"]))
        XCTAssertNil(CallDetector.firstKnownCallApp(in: ["us.zoom.xos.renderer"]))
    }

    /// Every entry in the curated list carries a non-empty display name —
    /// that name goes straight into the notification title.
    func testAllKnownAppsHaveDisplayNames() {
        for (id, name) in CallDetector.knownCallApps {
            XCTAssertFalse(name.isEmpty, "\(id) has an empty display name")
        }
    }
}
