import XCTest
@testable import Shhhcribble

/// Tests for the tabbed sticky panel's model — the half of the feature that can
/// silently lose or reshuffle a user's text.
///
/// The debounced flush itself lives in `StickyView` (a private SwiftUI view) and
/// can't be driven from here; what these cover is everything the flush depends
/// on being true, plus the ordering guarantee that makes tabs usable at all.
@MainActor
final class StickyTabsTests: XCTestCase {

    private func makeStore() -> TranscriptStore { TranscriptStore(path: ":memory:") }

    private func stuck(_ text: String) -> Note {
        var note = Note(text: text)
        note.stuck = true
        note.pinned = true
        return note
    }

    // MARK: - Tab order

    /// The whole reason `stuckNotesInTabOrder` exists: `stuckNotes` is
    /// recency-ordered, and recency changes on every keystroke. As tabs that
    /// would reshuffle under the pointer mid-sentence.
    func testTabOrderIsCreationOrderAndSurvivesAnEdit() {
        let store = makeStore()
        for text in ["first", "second", "third"] { store.addNote(stuck(text)) }
        XCTAssertEqual(store.stuckNotesInTabOrder.map(\.text), ["first", "second", "third"])

        // Touch the oldest note — recency now puts it top, tab order must not.
        var oldest = store.notes[0]
        oldest.text = "first, edited"
        store.updateNote(oldest)

        XCTAssertEqual(store.stuckNotesInTabOrder.map(\.text),
                       ["first, edited", "second", "third"])
        XCTAssertEqual(store.stuckNotes.first?.text, "first, edited",
                       "stuckNotes stays recency-ordered for the Pinned board")
    }

    func testTabOrderExcludesUnstuckNotes() {
        let store = makeStore()
        store.addNote(stuck("on screen"))
        store.addNote(Note(text: "just a note"))
        XCTAssertEqual(store.stuckNotesInTabOrder.map(\.text), ["on screen"])
    }

    // MARK: - Activation

    func testFirstApplyActivatesFirstTab() {
        let model = StickyTabsModel()
        let notes = [stuck("a"), stuck("b")]
        model.apply(notes: notes)
        XCTAssertEqual(model.activeID, notes[0].id)
        XCTAssertEqual(model.attributed.string, "a")
    }

    func testFirstApplyHonoursPreferredActive() {
        let model = StickyTabsModel()
        let notes = [stuck("a"), stuck("b")]
        model.apply(notes: notes, preferredActive: notes[1].id)
        XCTAssertEqual(model.activeID, notes[1].id)
        XCTAssertEqual(model.attributed.string, "b")
    }

    func testUnknownPreferredActiveFallsBackToFirst() {
        let model = StickyTabsModel()
        let notes = [stuck("a"), stuck("b")]
        model.apply(notes: notes, preferredActive: UUID())
        XCTAssertEqual(model.activeID, notes[0].id)
    }

    /// Closing a tab lands on the one that slid into its index — browser
    /// behaviour, and the only choice that doesn't feel random.
    func testClosingActiveTabLandsOnTheTabThatTookItsIndex() {
        let model = StickyTabsModel()
        let notes = [stuck("a"), stuck("b"), stuck("c")]
        model.apply(notes: notes, preferredActive: notes[1].id)

        model.apply(notes: [notes[0], notes[2]])   // middle tab unstuck

        XCTAssertEqual(model.activeID, notes[2].id)
        XCTAssertEqual(model.attributed.string, "c")
    }

    func testClosingLastTabLandsOnTheNewLastTab() {
        let model = StickyTabsModel()
        let notes = [stuck("a"), stuck("b")]
        model.apply(notes: notes, preferredActive: notes[1].id)

        model.apply(notes: [notes[0]])

        XCTAssertEqual(model.activeID, notes[0].id)
        XCTAssertEqual(model.attributed.string, "a")
    }

    func testActivatingClearsThePendingEditFlag() {
        let model = StickyTabsModel()
        let notes = [stuck("a"), stuck("b")]
        model.apply(notes: notes)
        model.hasPendingEdit = true

        model.activate(notes[1].id)

        XCTAssertFalse(model.hasPendingEdit)
        XCTAssertEqual(model.attributed.string, "b")
    }

    // MARK: - Store echo vs external edit

    func testExternalEditIsPushedIntoTheActiveTab() {
        let model = StickyTabsModel()
        var note = stuck("original")
        model.apply(notes: [note])

        note.text = "edited in the Notes pane"
        model.apply(notes: [note])

        XCTAssertEqual(model.attributed.string, "edited in the Notes pane")
    }

    /// The keystroke-eating guard: while this editor holds an unsaved edit, a
    /// store push must not overwrite what's on screen.
    func testExternalEditIsRefusedWhileAnEditIsPending() {
        let model = StickyTabsModel()
        var note = stuck("original")
        model.apply(notes: [note])
        model.hasPendingEdit = true

        note.text = "arrives while typing"
        model.apply(notes: [note])

        XCTAssertEqual(model.attributed.string, "original")
    }

    // MARK: - The flush invariant

    /// Records every commit the model makes, standing in for the store.
    private func recording(_ model: StickyTabsModel) -> Commits {
        let commits = Commits()
        model.onCommit = { id, text in commits.entries.append((id, text.string)) }
        return commits
    }

    private final class Commits {
        var entries: [(id: UUID, text: String)] = []
    }

    /// **The feature's main data-loss risk.** One editor serves every tab, so
    /// switching without committing first loses everything typed since the last
    /// debounce tick.
    func testSwitchingTabsCommitsTheOutgoingTabsUnsavedEdit() {
        let model = StickyTabsModel()
        let notes = [stuck("a"), stuck("b")]
        model.apply(notes: notes)
        let commits = recording(model)

        // Simulate typing into tab A: the editor sets the text and the flag.
        model.attributed = NSAttributedString(string: "a, typed but not yet saved")
        model.hasPendingEdit = true

        model.selectTab(notes[1].id)

        XCTAssertEqual(commits.entries.count, 1)
        XCTAssertEqual(commits.entries.first?.id, notes[0].id,
                       "the commit must be attributed to the tab being left")
        XCTAssertEqual(commits.entries.first?.text, "a, typed but not yet saved")
        XCTAssertEqual(model.attributed.string, "b")
        XCTAssertFalse(model.hasPendingEdit)
    }

    /// Merely clicking between tabs must not write. `modifiedAt` orders the
    /// Notes list and the Pinned board's on-screen strip, so a spurious write
    /// would reshuffle both under the user.
    func testSwitchingTabsWithNoEditWritesNothing() {
        let model = StickyTabsModel()
        let notes = [stuck("a"), stuck("b")]
        model.apply(notes: notes)
        let commits = recording(model)

        model.selectTab(notes[1].id)
        model.selectTab(notes[0].id)

        XCTAssertTrue(commits.entries.isEmpty)
    }

    func testFlushingTwiceWritesOnce() {
        let model = StickyTabsModel()
        let note = stuck("a")
        model.apply(notes: [note])
        let commits = recording(model)

        model.attributed = NSAttributedString(string: "changed")
        model.hasPendingEdit = true
        model.flushSave()
        model.flushSave()

        XCTAssertEqual(commits.entries.count, 1)
    }

    /// Discarding an empty note is the one path that deliberately drops the
    /// pending edit — the row is about to be deleted.
    func testDiscardPendingEditWritesNothing() {
        let model = StickyTabsModel()
        let note = stuck("")
        model.apply(notes: [note])
        let commits = recording(model)

        model.attributed = NSAttributedString(string: "typed then discarded")
        model.hasPendingEdit = true
        model.discardPendingEdit()
        model.flushSave()

        XCTAssertTrue(commits.entries.isEmpty)
        XCTAssertFalse(model.hasPendingEdit)
    }

    /// The other half of the flush: here the switch is forced from outside —
    /// the note you are typing in gets unstuck from the Notes pane — so nothing
    /// goes through `selectTab` and the edit would otherwise be overwritten by
    /// the next tab's content.
    func testATabRemovedWhileBeingEditedStillCommitsItsEdit() {
        let model = StickyTabsModel()
        let notes = [stuck("a"), stuck("b")]
        model.apply(notes: notes)
        let commits = recording(model)

        model.attributed = NSAttributedString(string: "a, typed then unstuck elsewhere")
        model.hasPendingEdit = true

        model.apply(notes: [notes[1]])   // tab A unstuck from the Notes pane

        XCTAssertEqual(commits.entries.count, 1)
        XCTAssertEqual(commits.entries.first?.id, notes[0].id)
        XCTAssertEqual(commits.entries.first?.text, "a, typed then unstuck elsewhere")
        XCTAssertEqual(model.attributed.string, "b")
    }

    /// A confirmation left open belongs to the tab being left — carrying it over
    /// would leave "Close this sticky?" hanging over a different note, and
    /// pressing Unstick would unstick the wrong one.
    func testSwitchingTabsDismissesAnOpenCloseConfirmation() {
        let model = StickyTabsModel()
        let notes = [stuck("a"), stuck("b")]
        model.apply(notes: notes)

        model.showingCloseConfirm = true
        model.selectTab(notes[1].id)

        XCTAssertFalse(model.showingCloseConfirm)
    }

    func testATabRemovedElsewhereAlsoDismissesTheCloseConfirmation() {
        let model = StickyTabsModel()
        let notes = [stuck("a"), stuck("b")]
        model.apply(notes: notes)

        model.showingCloseConfirm = true
        model.apply(notes: [notes[1]])

        XCTAssertFalse(model.showingCloseConfirm)
    }

    /// After a commit, the model must recognise its own value coming back from
    /// the store rather than treating it as an external edit.
    func testStoreEchoOfOurOwnWriteIsNotTreatedAsExternal() {
        let model = StickyTabsModel()
        var note = stuck("original")
        model.apply(notes: [note])
        let commits = recording(model)

        model.attributed = NSAttributedString(string: "edited here")
        model.hasPendingEdit = true
        model.flushSave()
        XCTAssertEqual(commits.entries.count, 1)

        // The store persists it and republishes the row.
        note.text = "edited here"
        note.richText = RichText.data(from: model.attributed, font: StickyTabsModel.font)
        model.apply(notes: [note])

        XCTAssertEqual(model.attributed.string, "edited here")
        XCTAssertFalse(model.hasPendingEdit)
    }

    // MARK: - Tab labels

    func testLabelUsesFirstNonEmptyLine() {
        let model = StickyTabsModel()
        let note = stuck("\n\n  Groceries  \nmilk\neggs")
        model.apply(notes: [note])
        XCTAssertEqual(model.label(for: note), "Groceries")
    }

    func testLabelFallsBackForAnEmptyNote() {
        let model = StickyTabsModel()
        let note = stuck("   \n  ")
        model.apply(notes: [note])
        XCTAssertEqual(model.label(for: note), "New note")
    }

    func testLongLabelIsTruncated() {
        let model = StickyTabsModel()
        let note = stuck("a title far longer than any tab could hope to show")
        model.apply(notes: [note])
        let label = model.label(for: note)
        XCTAssertEqual(label.count, 18)
        XCTAssertTrue(label.hasSuffix("…"))
    }

    /// The active tab's label tracks the editor, not the stored row — otherwise
    /// a title you are typing reads "New note" until the save debounce fires.
    func testActiveTabLabelFollowsTheLiveEditor() {
        let model = StickyTabsModel()
        let note = stuck("")
        model.apply(notes: [note])
        XCTAssertEqual(model.label(for: note), "New note")

        model.attributed = NSAttributedString(string: "Shopping list")
        XCTAssertEqual(model.label(for: note), "Shopping list")
    }

    func testInactiveTabLabelUsesTheStoredRow() {
        let model = StickyTabsModel()
        let notes = [stuck("alpha"), stuck("beta")]
        model.apply(notes: notes, preferredActive: notes[1].id)
        model.attributed = NSAttributedString(string: "beta, being typed")

        XCTAssertEqual(model.label(for: notes[0]), "alpha")
        XCTAssertEqual(model.label(for: notes[1]), "beta, being typed")
    }
}
