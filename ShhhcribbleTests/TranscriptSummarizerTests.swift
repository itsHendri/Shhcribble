import XCTest
@testable import Shhhcribble

/// Logic tests for the on-device summarizer. The model itself can't run in CI
/// (no macOS 26 + Apple Intelligence), so these pin the graceful-degradation
/// contract and skip the live path when a model happens to be present.
final class TranscriptSummarizerTests: XCTestCase {

    func testAvailabilityReasonIsNonEmptyWhenUnavailable() {
        if case .unavailable(let reason) = TranscriptSummarizer.availability {
            XCTAssertFalse(reason.isEmpty, "Unavailable reason should be user-presentable.")
        }
    }

    func testSummarizeReturnsNilWhenUnavailable() async throws {
        guard case .unavailable = TranscriptSummarizer.availability else {
            throw XCTSkip("On-device model is available here; skipping the unavailable-path assertion.")
        }
        let result = await TranscriptSummarizer.summarize("This is a short transcript.")
        XCTAssertNil(result, "Summarize must return nil when the model is unavailable.")
    }

    func testResultEquatable() {
        let a = TranscriptSummarizer.Result(summary: "s", actionItems: [ActionItem(text: "x")])
        let b = TranscriptSummarizer.Result(summary: "s", actionItems: [ActionItem(text: "x")])
        XCTAssertEqual(a, b)
    }

    /// An action item defaults to nobody's, with nothing to cite — which is what
    /// a legacy stored item decodes to.
    func testActionItemDefaults() {
        let item = ActionItem(text: "Book the offsite")
        XCTAssertEqual(item.owner, .unassigned)
        XCTAssertEqual(item.quote, "")
        XCTAssertNil(item.owner.label, "Unassigned shows no tag — it's the normal case for a dictation.")
    }

    func testOwnerLabels() {
        XCTAssertEqual(ActionItemOwner.me.label, "You")
        XCTAssertEqual(ActionItemOwner.others.label, "Them")
    }
}
