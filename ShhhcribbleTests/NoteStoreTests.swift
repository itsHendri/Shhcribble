import XCTest
import SQLite3
@testable import Shhhcribble

/// Tests for the `notes` table CRUD (Notes module). In-memory DB for pure
/// CRUD; a temp file for persistence round-trips and migrations.
@MainActor
final class NoteStoreTests: XCTestCase {

    private let transcriptNotesFlag = "didMigrateTranscriptNotesToNotes"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: transcriptNotesFlag)
        super.tearDown()
    }

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
        store.addNote(Note(text: "buy milk"))
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes.first?.text, "buy milk")

        var updated = store.notes[0]
        updated.text = "buy oat milk"
        store.updateNote(updated)
        XCTAssertEqual(store.notes.first?.text, "buy oat milk")
    }

    func testUpdateNoteStampsModifiedAt() {
        let store = makeStore()
        let created = Date(timeIntervalSince1970: 1_000)
        store.addNote(Note(createdAt: created, modifiedAt: created, text: "n"))

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
        var note = Note(text: "pinned note")
        note.richText = Data("not-real-rtf-but-a-blob".utf8)
        note.pinned = true
        note.pinX = 120.5
        note.pinY = 340.25
        note.pinW = 320
        note.pinH = 260
        let tid = UUID()
        note.sourceTranscriptID = tid
        note.sourceActionItem = "original item"
        store.addNote(note)

        let reopened = TranscriptStore(path: path)
        XCTAssertEqual(reopened.notes.count, 1)
        let r = reopened.notes[0]
        XCTAssertEqual(r.id, note.id)
        XCTAssertEqual(r.text, "pinned note")
        XCTAssertEqual(r.richText, note.richText)
        XCTAssertTrue(r.pinned)
        XCTAssertEqual(r.pinX, 120.5)
        XCTAssertEqual(r.pinY, 340.25)
        XCTAssertEqual(r.pinW, 320)
        XCTAssertEqual(r.pinH, 260)
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

    /// A styling-only edit (same words, now bold) must be visible as a change,
    /// or the second live editor for a note — a pinned sticky — silently keeps
    /// showing the old formatting. Both surfaces diff on the stored fields, so
    /// `richText` changing alone has to be enough.
    func testStylingOnlyEditIsADetectableChange() {
        let store = makeStore()
        store.addNote(Note(text: "same words"))

        var styled = store.notes[0]
        styled.richText = Data("pretend-rtf-with-bold".utf8)
        store.updateNote(styled)

        XCTAssertEqual(store.notes[0].text, "same words")        // unchanged
        XCTAssertEqual(store.notes[0].richText, styled.richText) // but the row did change
    }

    // MARK: - Pinning

    /// Pinning changes where a note is shown, not what it says, so it must not
    /// stamp `modifiedAt` — otherwise an untouched note is labelled "Edited"
    /// just for being pinned.
    func testPinningDoesNotMarkTheNoteEdited() {
        let store = makeStore()
        let created = Date(timeIntervalSince1970: 1_000)
        store.addNote(Note(createdAt: created, modifiedAt: created, text: "untouched"))
        let id = store.notes[0].id

        store.setNotePinned(id: id, pinned: true, origin: CGPoint(x: 1, y: 2))
        XCTAssertEqual(store.notes[0].modifiedAt, created)

        store.updateNotePinFrame(id: id, frame: CGRect(x: 3, y: 4, width: 200, height: 200))
        XCTAssertEqual(store.notes[0].modifiedAt, created)
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

    func testUpdatePinFrameStoresOriginAndSize() {
        let store = makeStore()
        let note = Note(text: "sticky")
        store.addNote(note)
        store.updateNotePinFrame(id: note.id, frame: CGRect(x: 5, y: 6, width: 300, height: 240))
        XCTAssertEqual(store.notes[0].pinX, 5)
        XCTAssertEqual(store.notes[0].pinY, 6)
        XCTAssertEqual(store.notes[0].pinW, 300)
        XCTAssertEqual(store.notes[0].pinH, 240)
    }

    // MARK: - Legacy notes-table migration (v7 shape → current)

    /// A DB whose notes table predates the sticky-size and rich-text columns
    /// (the v7 first cut) must get them ALTERed in, keep its rows, and reach
    /// the latest version — this is the shape of any machine that ran an
    /// earlier build of this branch.
    func testV7NotesTableGainsLaterColumns() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let ddl = """
        CREATE TABLE notes (
            id TEXT PRIMARY KEY, createdAt REAL NOT NULL, modifiedAt REAL NOT NULL,
            text TEXT NOT NULL, isTask INTEGER NOT NULL DEFAULT 0, done INTEGER NOT NULL DEFAULT 0,
            completedAt REAL, dueAt REAL, reminderFiredAt REAL,
            pinned INTEGER NOT NULL DEFAULT 0, pinX REAL, pinY REAL,
            sourceTranscriptID TEXT, sourceActionItem TEXT, position INTEGER NOT NULL
        );
        """
        XCTAssertEqual(sqlite3_exec(db, ddl, nil, nil, nil), SQLITE_OK)
        let noteID = UUID().uuidString
        let insert = """
        INSERT INTO notes (id, createdAt, modifiedAt, text, pinned, pinX, pinY, position)
        VALUES ('\(noteID)', 100, 100, 'old sticky', 1, 40, 50, 0);
        """
        XCTAssertEqual(sqlite3_exec(db, insert, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version = 7;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let store = TranscriptStore(path: path)
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes.first?.text, "old sticky")
        XCTAssertEqual(store.notes.first?.pinX, 40)
        XCTAssertNil(store.notes.first?.pinW)       // new columns, NULL for old rows
        XCTAssertNil(store.notes.first?.richText)

        // The new columns are fully writable end to end.
        var updated = store.notes[0]
        updated.richText = Data("blob".utf8)
        store.updateNote(updated)
        store.updateNotePinFrame(id: UUID(uuidString: noteID)!,
                                 frame: CGRect(x: 10, y: 20, width: 300, height: 240))
        let reopened = TranscriptStore(path: path)
        XCTAssertEqual(reopened.notes.first?.pinW, 300)
        XCTAssertEqual(reopened.notes.first?.pinH, 240)
        XCTAssertEqual(reopened.notes.first?.richText, Data("blob".utf8))
    }

    // MARK: - Transcript-notes migration

    func testTranscriptNotesMigrateIntoStandaloneNotes() {
        let store = makeStore()
        let withNotes = store.addDictation(text: "meeting body", rawText: "raw")
        store.updateNotes(id: withNotes.id, notes: "my own thoughts")
        store.addDictation(text: "no notes here", rawText: "raw")

        UserDefaults.standard.removeObject(forKey: transcriptNotesFlag)
        store.migrateTranscriptNotesIfNeeded()

        XCTAssertEqual(store.notes.count, 1)
        XCTAssertEqual(store.notes[0].text, "my own thoughts")
        XCTAssertEqual(store.notes[0].sourceTranscriptID, withNotes.id)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: transcriptNotesFlag))
    }

    func testTranscriptNotesMigrationIsIdempotent() {
        let store = makeStore()
        let t = store.addDictation(text: "body", rawText: "raw")
        store.updateNotes(id: t.id, notes: "keep me")

        UserDefaults.standard.removeObject(forKey: transcriptNotesFlag)
        store.migrateTranscriptNotesIfNeeded()
        UserDefaults.standard.removeObject(forKey: transcriptNotesFlag)   // simulate an interrupted run
        store.migrateTranscriptNotesIfNeeded()

        XCTAssertEqual(store.notes.count, 1)   // the sentinel key stops a duplicate
    }

    // MARK: - Action items → Notes

    func testAddActionItemCreatesLinkedNote() {
        let store = makeStore()
        let tid = UUID()
        let note = store.promoteActionItem(transcriptID: tid, item: "Email Sam the doc")
        XCTAssertEqual(note.text, "Email Sam the doc")
        XCTAssertEqual(note.sourceTranscriptID, tid)
        XCTAssertEqual(note.sourceActionItem, "Email Sam the doc")
        XCTAssertEqual(store.notes.count, 1)
    }

    func testAddActionItemIsIdempotent() {
        let store = makeStore()
        let tid = UUID()
        let first = store.promoteActionItem(transcriptID: tid, item: "same item")
        let second = store.promoteActionItem(transcriptID: tid, item: "same item")
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.notes.count, 1)

        // Same wording from a DIFFERENT transcript is a distinct note.
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

        // The Summary tab resolves "already added" by the verbatim snapshot,
        // not the (now edited) note text.
        XCTAssertEqual(store.noteForActionItem(transcriptID: tid, item: "call the bank")?.id, note.id)
    }
}
