import XCTest
import SQLite3
@testable import Shhhcribble

/// Tests for the `notes` table CRUD (Notes + Tasks program, schema v7).
/// In-memory DB for pure CRUD; a temp file for persistence round-trips.
@MainActor
final class NoteStoreTests: XCTestCase {

    private func makeStore() -> TranscriptStore { TranscriptStore(path: ":memory:") }

    private func tempDBPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("shhh-note-test-\(UUID().uuidString).sqlite").path
    }

    // MARK: - CRUD

    func testNotesDefaultEmpty() {
        XCTAssertTrue(makeStore().notes.isEmpty)
    }

    func testAddAndUpdateNote() {
        let store = makeStore()
        var note = Note(text: "buy milk")
        note.isTask = true
        store.addNote(note)
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes.first?.text, "buy milk")
        XCTAssertEqual(store.notes.first?.isTask, true)

        var updated = store.notes[0]
        updated.text = "buy oat milk"
        updated.dueAt = Date(timeIntervalSince1970: 2_000_000_000)
        store.updateNote(updated)
        XCTAssertEqual(store.notes.first?.text, "buy oat milk")
        XCTAssertEqual(store.notes.first?.dueAt, Date(timeIntervalSince1970: 2_000_000_000))
    }

    func testUpdateNoteStampsModifiedAt() {
        let store = makeStore()
        let created = Date(timeIntervalSince1970: 1_000)
        let note = Note(createdAt: created, modifiedAt: created, text: "n")
        store.addNote(note)

        let later = Date(timeIntervalSince1970: 5_000)
        var updated = store.notes[0]
        updated.text = "edited"
        store.updateNote(updated, modifiedAt: later)
        XCTAssertEqual(store.notes.first?.modifiedAt, later)
        XCTAssertEqual(store.notes.first?.createdAt, created)   // untouched
    }

    func testPersistenceRoundTripAcrossReopen() {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = TranscriptStore(path: path)
        var note = Note(text: "pinned task")
        note.isTask = true
        note.done = true
        note.completedAt = Date(timeIntervalSince1970: 42)
        note.dueAt = Date(timeIntervalSince1970: 99)
        note.reminderFiredAt = Date(timeIntervalSince1970: 100)
        note.pinned = true
        note.pinX = 120.5
        note.pinY = 340.25
        let tid = UUID()
        note.sourceTranscriptID = tid
        note.sourceActionItem = "original item"
        store.addNote(note)

        let reopened = TranscriptStore(path: path)
        XCTAssertEqual(reopened.notes.count, 1)
        let r = reopened.notes[0]
        XCTAssertEqual(r.id, note.id)
        XCTAssertEqual(r.text, "pinned task")
        XCTAssertTrue(r.isTask)
        XCTAssertTrue(r.done)
        XCTAssertEqual(r.completedAt, Date(timeIntervalSince1970: 42))
        XCTAssertEqual(r.dueAt, Date(timeIntervalSince1970: 99))
        XCTAssertEqual(r.reminderFiredAt, Date(timeIntervalSince1970: 100))
        XCTAssertTrue(r.pinned)
        XCTAssertEqual(r.pinX, 120.5)
        XCTAssertEqual(r.pinY, 340.25)
        XCTAssertEqual(r.sourceTranscriptID, tid)
        XCTAssertEqual(r.sourceActionItem, "original item")
    }

    func testDeleteRenumbersPositionsDense() {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = TranscriptStore(path: path)
        store.addNote(Note(text: "a"))
        store.addNote(Note(text: "b"))
        store.addNote(Note(text: "c"))
        store.deleteNote(id: store.notes[0].id)   // delete "a"

        // Order survives a reopen — positions were renumbered densely, so the
        // ORDER BY position load reproduces [b, c].
        let reopened = TranscriptStore(path: path)
        XCTAssertEqual(reopened.notes.map { $0.text }, ["b", "c"])

        // And a new add lands at the end, not colliding with a stale position.
        reopened.addNote(Note(text: "d"))
        let again = TranscriptStore(path: path)
        XCTAssertEqual(again.notes.map { $0.text }, ["b", "c", "d"])
    }

    // MARK: - Task semantics

    func testToggleDoneStampsAndClearsCompletedAt() {
        let store = makeStore()
        var note = Note(text: "t")
        note.isTask = true
        store.addNote(note)

        store.toggleNoteDone(id: note.id)
        XCTAssertTrue(store.notes[0].done)
        XCTAssertNotNil(store.notes[0].completedAt)

        store.toggleNoteDone(id: note.id)
        XCTAssertFalse(store.notes[0].done)
        XCTAssertNil(store.notes[0].completedAt)
    }

    func testSnoozeReArmsFiredReminder() {
        let store = makeStore()
        var note = Note(text: "t")
        note.isTask = true
        note.dueAt = Date(timeIntervalSince1970: 100)
        store.addNote(note)
        store.markNoteReminderFired(id: note.id, at: Date(timeIntervalSince1970: 101))
        XCTAssertFalse(store.notes[0].hasArmedReminder)

        let snoozeUntil = Date(timeIntervalSince1970: 700)
        store.snoozeNote(id: note.id, until: snoozeUntil)
        XCTAssertEqual(store.notes[0].dueAt, snoozeUntil)
        XCTAssertNil(store.notes[0].reminderFiredAt)
        XCTAssertTrue(store.notes[0].hasArmedReminder)
    }

    func testSetPinnedKeepsLastOriginAcrossUnpin() {
        let store = makeStore()
        let note = Note(text: "sticky")
        store.addNote(note)
        store.setNotePinned(id: note.id, pinned: true, origin: CGPoint(x: 10, y: 20))
        XCTAssertTrue(store.notes[0].pinned)
        XCTAssertEqual(store.notes[0].pinX, 10)

        store.setNotePinned(id: note.id, pinned: false)
        XCTAssertFalse(store.notes[0].pinned)
        XCTAssertEqual(store.notes[0].pinX, 10)   // origin survives for re-pin
    }

    // MARK: - Action-item promotion

    func testPromoteActionItemCreatesLinkedTask() {
        let store = makeStore()
        let tid = UUID()
        let note = store.promoteActionItem(transcriptID: tid, item: "Email Sam the doc")
        XCTAssertTrue(note.isTask)
        XCTAssertEqual(note.text, "Email Sam the doc")
        XCTAssertEqual(note.sourceTranscriptID, tid)
        XCTAssertEqual(note.sourceActionItem, "Email Sam the doc")
        XCTAssertEqual(store.notes.count, 1)
    }

    func testPromoteActionItemIsIdempotent() {
        let store = makeStore()
        let tid = UUID()
        let first = store.promoteActionItem(transcriptID: tid, item: "same item")
        let second = store.promoteActionItem(transcriptID: tid, item: "same item")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.notes.count, 1)

        // Same wording from a DIFFERENT transcript is a distinct task.
        store.promoteActionItem(transcriptID: UUID(), item: "same item")
        XCTAssertEqual(store.notes.count, 2)
    }

    func testActionItemLookupSurvivesNoteTextEdit() {
        let store = makeStore()
        let tid = UUID()
        let note = store.promoteActionItem(transcriptID: tid, item: "call the bank")

        var edited = store.notes[0]
        edited.text = "call the bank about the mortgage — before Friday"
        store.updateNote(edited)

        // The Summary tab resolves promotion state by the verbatim snapshot,
        // not the (now edited) note text.
        XCTAssertEqual(store.noteForActionItem(transcriptID: tid, item: "call the bank")?.id, note.id)
    }
}
