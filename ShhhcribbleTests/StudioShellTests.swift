import XCTest
@testable import Shhhcribble

/// Guards the Studio's locked information architecture.
///
/// The rail's exact destinations, and Settings holding exactly four pages, are
/// *design decisions* recorded in docs/design/studio-wireframes.md —
/// not an implementation detail. It's also the kind of thing that drifts one
/// well-meaning addition at a time, so these tests fail loudly when the shape
/// changes and make whoever changed it go and update the contract.
final class StudioShellTests: XCTestCase {

    func testRailIsTheLockedDestinationsInOrder() {
        XCTAssertEqual(TranscriptionsView.RailSection.allCases,
                       [.dictations, .notes, .settings],
                       "The rail's shape is locked in the wireframes decision record — "
                       + "update that first if this is a deliberate change.")
    }

    func testSettingsHoldsTheFourLockedPagesInOrder() {
        XCTAssertEqual(TranscriptionsView.SettingsPage.allCases,
                       [.preferences, .styles, .dictionary, .feedback],
                       "Styles, Dictionary and Feedback were demoted into Settings on purpose.")
    }

    /// Every destination needs a label and a glyph, and no two may share
    /// either — a rail with two identical icons is a rail you can't read.
    func testRailDestinationsHaveDistinctLabelsAndIcons() {
        let sections = TranscriptionsView.RailSection.allCases
        XCTAssertTrue(sections.allSatisfy { !$0.label.isEmpty && !$0.systemImage.isEmpty })
        XCTAssertEqual(Set(sections.map(\.label)).count, sections.count)
        XCTAssertEqual(Set(sections.map(\.systemImage)).count, sections.count)
    }

    func testSettingsPagesHaveDistinctLabelsAndIcons() {
        let pages = TranscriptionsView.SettingsPage.allCases
        XCTAssertTrue(pages.allSatisfy { !$0.label.isEmpty && !$0.systemImage.isEmpty })
        XCTAssertEqual(Set(pages.map(\.label)).count, pages.count)
        XCTAssertEqual(Set(pages.map(\.systemImage)).count, pages.count)
    }

    /// The rail's raw values are the identity used for selection; renaming one
    /// silently is how a saved selection stops matching.
    func testRailIdentifiersAreStable() {
        XCTAssertEqual(TranscriptionsView.RailSection.allCases.map(\.id),
                       ["dictations", "notes", "settings"])
        XCTAssertEqual(TranscriptionsView.SettingsPage.allCases.map(\.id),
                       ["preferences", "styles", "dictionary", "feedback"])
    }

    /// Each source belongs to exactly one half of the app, and `isDocument` is
    /// the single line between them — the predicate Documents, the Today
    /// stream's two weights, and search grouping all read.
    func testSourcesSplitCleanlyIntoTheTwoHalves() {
        XCTAssertFalse(TranscriptSource.dictation.isDocument)
        XCTAssertTrue(TranscriptSource.file.isDocument)
        XCTAssertTrue(TranscriptSource.call.isDocument)
        // Chrome for each, so a new source can't slip in unlabelled.
        for source in [TranscriptSource.dictation, .file, .call] {
            XCTAssertFalse(source.icon.isEmpty)
            XCTAssertFalse(source.label.isEmpty)
        }
    }
}
