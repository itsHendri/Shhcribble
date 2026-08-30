import XCTest
import AppKit
import SwiftUI
@testable import Shhhcribble

/// Note-only convenience for the cases written before documents could be
/// pinned (2026-08-30). It forwards to the real `apply(items:)`, so these tests
/// still exercise the production path — it only saves wrapping every fixture.
extension StickyTabsModel {
    func apply(notes: [Note], preferredActive: UUID? = nil) {
        apply(items: notes.map(StickyItem.note), preferredActive: preferredActive)
    }

    func label(for note: Note) -> String { label(for: StickyItem.note(note)) }
}

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

    // MARK: - Through the real editor

    /// Everything above drives the model directly. These two drive a **real
    /// `NSTextView`, in a real window, through the SwiftUI wrapper the app
    /// actually builds** — the layer where the interesting bugs were, and the
    /// one that can't be reached by clicking, because a menu-bar-only
    /// (`LSUIElement`) app isn't visible to UI automation at all.

    private func hostEditor(
        model: StickyTabsModel,
        proxy: NoteEditorProxy? = nil
    ) throws -> (RichTextView, NSWindow) {
        let editor = RichTextEditor(
            attributed: Binding(get: { model.attributed }, set: { model.attributed = $0 }),
            hasPendingEdit: Binding(get: { model.hasPendingEdit }, set: { model.hasPendingEdit = $0 }),
            font: StickyTabsModel.font,
            onUserEdit: { model.scheduleSave() },
            resetsUndoOnExternalChange: true,
            proxy: proxy
        )
        let hosting = NSHostingView(rootView: editor)
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 240)
        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        let view = try XCTUnwrap(firstRichTextView(in: hosting), "no RichTextView was built")
        return (view, window)
    }

    private func firstRichTextView(in view: NSView) -> RichTextView? {
        if let match = view as? RichTextView { return match }
        for child in view.subviews {
            if let match = firstRichTextView(in: child) { return match }
        }
        return nil
    }

    /// **The end-to-end version of the data-loss risk.** A real keystroke, then
    /// a real tab switch: the words typed since the last debounce tick must be
    /// committed to the tab being left, not overwritten by the incoming note.
    @MainActor
    func testTypingInTheRealEditorSurvivesATabSwitch() throws {
        let model = StickyTabsModel()
        let notes = [stuck("first"), stuck("second")]
        model.apply(notes: notes)
        let commits = recording(model)

        let (view, window) = try hostEditor(model: model)
        XCTAssertTrue(window.makeFirstResponder(view))
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText(" and more", replacementRange: view.selectedRange())

        XCTAssertTrue(model.hasPendingEdit, "a real keystroke must arm the save")

        model.selectTab(notes[1].id)

        XCTAssertEqual(commits.entries.count, 1)
        XCTAssertEqual(commits.entries.first?.id, notes[0].id,
                       "the commit belongs to the tab being left")
        XCTAssertEqual(commits.entries.first?.text, "first and more")
        XCTAssertEqual(model.attributed.string, "second")
    }

    /// **Pins the append bug.** Dictation runs for as long as you talk, and you
    /// may keep typing throughout — so the append has to be computed from the
    /// text as it is when the words arrive, not as it was when recording
    /// started. Building it from a captured copy silently wiped the typing.
    @MainActor
    func testDictatedAppendUsesLiveEditorTextNotAStaleCopy() throws {
        let model = StickyTabsModel()
        model.apply(notes: [stuck("start")])
        let proxy = NoteEditorProxy()

        let (view, window) = try hostEditor(model: model, proxy: proxy)
        XCTAssertTrue(window.makeFirstResponder(view))

        // Snapshot the way the buggy version did — before the user types on.
        let staleCopy = model.attributed.string

        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText(" typed while recording", replacementRange: view.selectedRange())

        let attributes: [NSAttributedString.Key: Any] = [.font: StickyTabsModel.font]
        XCTAssertTrue(proxy.append(NSAttributedString(string: "dictated words",
                                                      attributes: attributes),
                                   attributes: attributes))

        XCTAssertEqual(view.string, "start typed while recording\n\ndictated words")
        XCTAssertNotEqual(staleCopy, "start typed while recording",
                          "sanity: the stale copy really was out of date")
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

/// Documents on screen — the half added 2026-08-30, when pinning stopped being
/// notes-only.
@MainActor
final class StuckDocumentTests: XCTestCase {

    private func makeStore() -> TranscriptStore { TranscriptStore(path: ":memory:") }

    private func document(_ title: String,
                          summary: String? = nil,
                          createdAt: Date = Date()) -> Transcript {
        Transcript(id: UUID(), createdAt: createdAt, source: .file, title: title,
                   text: "the full transcript, at length", rawText: "",
                   fileName: "\(title).m4a", summary: summary)
    }

    func testPinningADocumentPersistsAndSurvivesReopen() {
        let store = makeStore()
        let doc = document("standup")
        store.add(doc)

        store.setTranscriptStuck(id: doc.id, stuck: true)
        XCTAssertEqual(store.stuckDocuments.map(\.id), [doc.id])

        store.setTranscriptStuck(id: doc.id, stuck: false)
        XCTAssertTrue(store.stuckDocuments.isEmpty)
    }

    /// The retired column must stay retired: a rolled-back build reads `pinned`,
    /// and pinning to screen must not light it up.
    func testPinningADocumentDoesNotWriteTheRetiredPinnedColumn() {
        let store = makeStore()
        let doc = document("standup")
        store.add(doc)
        store.setTranscriptStuck(id: doc.id, stuck: true)

        let stored = store.transcripts.first { $0.id == doc.id }
        XCTAssertEqual(stored?.stuck, true)
        XCTAssertEqual(stored?.pinned, false)
    }

    /// A stuck document shows its summary — the ruling — and falls back to the
    /// transcript when none has been generated, saying which it is either way.
    func testStuckDocumentPrefersItsSummaryAndSaysSo() {
        let withSummary = StickyItem.document(document("a", summary: "three bullet points"))
        XCTAssertEqual(withSummary.documentBody, "three bullet points")
        XCTAssertTrue(withSummary.isShowingSummary)

        let without = StickyItem.document(document("b"))
        XCTAssertEqual(without.documentBody, "the full transcript, at length")
        XCTAssertFalse(without.isShowingSummary)

        // An empty-string summary is not a summary.
        let blank = StickyItem.document(document("c", summary: "   "))
        XCTAssertEqual(blank.documentBody, "the full transcript, at length")
        XCTAssertFalse(blank.isShowingSummary)
    }

    /// Tab order is creation order across *both* kinds — never recency, which
    /// changes on every keystroke and would reshuffle tabs mid-sentence.
    func testTabOrderInterleavesBothKindsByCreation() {
        let store = makeStore()
        let t0 = Date(timeIntervalSince1970: 1_000)

        var oldDoc = document("older file", createdAt: t0)
        oldDoc.stuck = true
        store.add(oldDoc)

        var newNote = Note(createdAt: t0.addingTimeInterval(60), text: "newer note")
        newNote.stuck = true
        store.addNote(newNote)

        XCTAssertEqual(store.stuckItemsInTabOrder.map(\.id), [oldDoc.id, newNote.id])

        // Touching the note must not move it: modifiedAt changes, createdAt doesn't.
        var touched = newNote
        touched.text = "edited"
        store.updateNote(touched)
        XCTAssertEqual(store.stuckItemsInTabOrder.map(\.id), [oldDoc.id, newNote.id])
    }

    /// The shelf's two groups stay exact complements once documents can be
    /// on screen — otherwise a pinned document would appear twice, or vanish.
    func testPartitionPutsPinnedDocumentsOnScreen() {
        var doc = document("pinned file")
        doc.stuck = true
        let plainDoc = document("ordinary file")
        var note = Note(text: "pinned note")
        note.stuck = true
        let plainNote = Note(text: "ordinary note")

        let rows = NotesLibrary.merged(notes: [note, plainNote], documents: [doc, plainDoc])
        let groups = NotesLibrary.partitioned(rows)

        XCTAssertEqual(Set(groups.onScreen.map(\.id)), [.document(doc.id), .note(note.id)])
        XCTAssertEqual(Set(groups.rest.map(\.id)), [.document(plainDoc.id), .note(plainNote.id)])
        XCTAssertEqual(groups.onScreen.count + groups.rest.count, rows.count)
    }
}
