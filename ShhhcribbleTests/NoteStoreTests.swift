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
        var note = Note(text: "stuck note")
        note.richText = Data("not-real-rtf-but-a-blob".utf8)
        note.stuck = true
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
        XCTAssertEqual(r.text, "stuck note")
        XCTAssertEqual(r.richText, note.richText)
        XCTAssertTrue(r.stuck)
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

    /// Sticking changes where a note is shown, not what it says, so it may not
    /// stamp `modifiedAt` — otherwise an untouched note is labelled "Edited"
    /// just for being put on screen, and reorders in the list.
    func testStickingDoesNotMarkTheNoteEdited() {
        let store = makeStore()
        let created = Date(timeIntervalSince1970: 1_000)
        store.addNote(Note(createdAt: created, modifiedAt: created, text: "untouched"))
        let id = store.notes[0].id

        store.setNoteStuck(id: id, stuck: true, origin: CGPoint(x: 1, y: 2))
        XCTAssertEqual(store.notes[0].modifiedAt, created)

        store.updateNotePinFrame(id: id, frame: CGRect(x: 3, y: 4, width: 200, height: 200))
        XCTAssertEqual(store.notes[0].modifiedAt, created)
    }

    func testStickingKeepsLastOriginAcrossUnstick() {
        let store = makeStore()
        let note = Note(text: "sticky")
        store.addNote(note)
        store.setNoteStuck(id: note.id, stuck: true, origin: CGPoint(x: 10, y: 20))
        XCTAssertTrue(store.notes[0].stuck)
        XCTAssertEqual(store.notes[0].pinX, 10)

        store.setNoteStuck(id: note.id, stuck: false)
        XCTAssertFalse(store.notes[0].stuck)
        XCTAssertEqual(store.notes[0].pinX, 10)   // origin survives for re-stick
    }

    // MARK: - Pin vs stick

    /// **Pin is retired** (2026-08-28) and the column must stay untouched:
    /// it is kept only so a rollback to a build that still reads it finds the
    /// data it left behind. Sticking used to auto-pin; if this ever writes
    /// `true` again, a rolled-back build pops every sticky onto the Pinned board.
    func testStickingDoesNotWritePinned() {
        let store = makeStore()
        let note = Note(text: "urgent")
        store.addNote(note)

        store.setNoteStuck(id: note.id, stuck: true)
        XCTAssertTrue(store.notes[0].stuck)
        XCTAssertFalse(store.notes[0].pinned, "pin is retired — sticking must not write it")
    }

    /// The "On your screen" group is fed by `stuckNotes` alone now.
    func testStuckAccessorSelectsOnlyStuckNotes() {
        let store = makeStore()
        let plain = Note(text: "plain")
        let stuck = Note(text: "stuck")
        [plain, stuck].forEach { store.addNote($0) }
        store.setNoteStuck(id: stuck.id, stuck: true)

        XCTAssertEqual(store.stuckNotes.map(\.id), [stuck.id])
    }

    func testStuckSurvivesReopen() {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = TranscriptStore(path: path)
        let note = Note(text: "sticky")
        store.addNote(note)
        store.setNoteStuck(id: note.id, stuck: true)

        let reopened = TranscriptStore(path: path)
        XCTAssertTrue(reopened.notes[0].stuck)
    }

    /// The retired `transcripts.pinned` column must still round-trip whatever
    /// an older build left in it — that is the whole point of keeping it.
    /// Nothing in the app writes it any more.
    func testRetiredTranscriptPinColumnStillRoundTrips() {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = TranscriptStore(path: path)
        var t = Transcript(id: UUID(), createdAt: Date(), source: .file,
                           title: "worth keeping.m4a", text: "body", rawText: "raw")
        t.pinned = true
        store.add(t)

        XCTAssertTrue(TranscriptStore(path: path).transcripts[0].pinned)
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

    // MARK: - Pin/stick split migration (v9 → v10)

    /// The split reuses the existing `pinned` column for *importance* and adds
    /// `stuck` for the sticky, seeded from it. Every note that was on screen
    /// before the upgrade must come out both stuck AND pinned — which is what
    /// the auto-pin rule says it should be, so nothing needs correcting by hand.
    func testV9StickiesBecomeStuckAndPinned() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Build a v9-shaped notes table: `pinned` still means "on screen".
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let ddl = """
        CREATE TABLE notes (
            id TEXT PRIMARY KEY, createdAt REAL NOT NULL, modifiedAt REAL NOT NULL,
            text TEXT NOT NULL, isTask INTEGER NOT NULL DEFAULT 0, done INTEGER NOT NULL DEFAULT 0,
            completedAt REAL, dueAt REAL, reminderFiredAt REAL, richText BLOB,
            pinned INTEGER NOT NULL DEFAULT 0, pinX REAL, pinY REAL, pinW REAL, pinH REAL,
            sourceTranscriptID TEXT, sourceActionItem TEXT, position INTEGER NOT NULL
        );
        """
        XCTAssertEqual(sqlite3_exec(db, ddl, nil, nil, nil), SQLITE_OK)
        let onScreen = UUID().uuidString
        let filed = UUID().uuidString
        let insert = """
        INSERT INTO notes (id, createdAt, modifiedAt, text, pinned, position)
        VALUES ('\(onScreen)', 100, 100, 'was a sticky', 1, 0),
               ('\(filed)', 100, 100, 'was just a note', 0, 1);
        """
        XCTAssertEqual(sqlite3_exec(db, insert, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version = 9;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let store = TranscriptStore(path: path)
        let sticky = try XCTUnwrap(store.notes.first { $0.id.uuidString == onScreen })
        XCTAssertTrue(sticky.stuck, "an existing sticky must still be on screen after the upgrade")
        // The v9 row's own `pinned` value survives the migration untouched.
        // Pin is retired, so nothing reads this any more — but the column is
        // kept for rollback, which is only worth anything if it still holds
        // what the old build wrote.
        XCTAssertTrue(sticky.pinned, "the retired column keeps whatever v9 left in it")

        let plain = try XCTUnwrap(store.notes.first { $0.id.uuidString == filed })
        XCTAssertFalse(plain.stuck)
        XCTAssertFalse(plain.pinned)
    }

    /// Transcripts predate the pin column entirely; an existing library must
    /// come back unpinned rather than failing to load.
    func testTranscriptsPredatingThePinColumnLoadUnpinned() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let ddl = """
        CREATE TABLE transcripts (
            id TEXT PRIMARY KEY, createdAt REAL NOT NULL, source TEXT NOT NULL,
            title TEXT NOT NULL, text TEXT NOT NULL, rawText TEXT NOT NULL,
            fileName TEXT, sourcePath TEXT, durationSec REAL
        );
        """
        XCTAssertEqual(sqlite3_exec(db, ddl, nil, nil, nil), SQLITE_OK)
        let insert = """
        INSERT INTO transcripts (id, createdAt, source, title, text, rawText)
        VALUES ('\(UUID().uuidString)', 100, 'dictation', 'old', 'old body', 'raw');
        """
        XCTAssertEqual(sqlite3_exec(db, insert, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let store = TranscriptStore(path: path)
        XCTAssertEqual(store.transcripts.count, 1)
        XCTAssertFalse(store.transcripts[0].pinned)
    }

    /// The v10 step must be all-or-nothing. If the `stuck` column could land
    /// without the backfill and the version bump, the *next launch* would re-run
    /// `UPDATE notes SET stuck = pinned` over a whole session of the user's own
    /// pin and stick choices — popping every favourite onto the screen and
    /// taking down any sticky they'd deliberately unpinned. This simulates that
    /// partial state directly: `stuck` present, `user_version` still 9, and the
    /// two flags already diverged.
    func testInterruptedV10DoesNotClobberDivergedFlags() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let ddl = """
        CREATE TABLE notes (
            id TEXT PRIMARY KEY, createdAt REAL NOT NULL, modifiedAt REAL NOT NULL,
            text TEXT NOT NULL, isTask INTEGER NOT NULL DEFAULT 0, done INTEGER NOT NULL DEFAULT 0,
            completedAt REAL, dueAt REAL, reminderFiredAt REAL, richText BLOB,
            pinned INTEGER NOT NULL DEFAULT 0, stuck INTEGER NOT NULL DEFAULT 0,
            pinX REAL, pinY REAL, pinW REAL, pinH REAL,
            sourceTranscriptID TEXT, sourceActionItem TEXT, position INTEGER NOT NULL
        );
        """
        XCTAssertEqual(sqlite3_exec(db, ddl, nil, nil, nil), SQLITE_OK)
        let favourite = UUID().uuidString      // pinned only — must stay off screen
        let onScreen = UUID().uuidString       // stuck but deliberately unpinned
        let insert = """
        INSERT INTO notes (id, createdAt, modifiedAt, text, pinned, stuck, position)
        VALUES ('\(favourite)', 100, 100, 'important, not urgent', 1, 0, 0),
               ('\(onScreen)', 100, 100, 'on screen, unpinned by hand', 0, 1, 1);
        """
        XCTAssertEqual(sqlite3_exec(db, insert, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version = 9;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let store = TranscriptStore(path: path)
        let pinnedOnly = try XCTUnwrap(store.notes.first { $0.id.uuidString == favourite })
        XCTAssertFalse(pinnedOnly.stuck, "a favourite must not be thrown onto the screen by a re-run backfill")
        let stuckOnly = try XCTUnwrap(store.notes.first { $0.id.uuidString == onScreen })
        XCTAssertTrue(stuckOnly.stuck, "a deliberately unpinned sticky must stay on screen")
        XCTAssertTrue(store.schemaIsCurrent, "and the migration must still complete")
    }

    /// `insert` is INSERT OR REPLACE over every column, so a field it forgets is
    /// a field that silently resets — including the retired `pinned` column,
    /// which must survive re-insertion so a rollback still finds what the old
    /// build wrote.
    func testAddedTranscriptKeepsItsRetiredPinColumn() {
        let store = makeStore()
        var t = Transcript(id: UUID(), createdAt: Date(), source: .file,
                           title: "t", text: "body", rawText: "raw")
        t.pinned = true
        store.add(t)
        XCTAssertTrue(store.transcripts[0].pinned)
    }

    // MARK: - Call transcripts get their own source (v12)

    /// Call captures shipped before there was a source for them. The migration
    /// has to find them by shape, and the shape it keys on is `durationSec`:
    /// `addDictation` never sets one, a call capture always does. A dictation
    /// that merely *starts* with "Call — " must be left alone.
    func testV11CallCapturesAreReclassifiedButDictationsAreNot() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let ddl = """
        CREATE TABLE transcripts (
            id TEXT PRIMARY KEY, createdAt REAL NOT NULL, source TEXT NOT NULL,
            title TEXT NOT NULL, text TEXT NOT NULL, rawText TEXT NOT NULL,
            fileName TEXT, sourcePath TEXT, durationSec REAL
        );
        """
        XCTAssertEqual(sqlite3_exec(db, ddl, nil, nil, nil), SQLITE_OK)
        let call = UUID().uuidString
        let lookalike = UUID().uuidString
        let plain = UUID().uuidString
        let insert = """
        INSERT INTO transcripts (id, createdAt, source, title, text, rawText, durationSec) VALUES
          ('\(call)', 300, 'dictation', 'Call — WhatsApp, 14:02', 'call body', 'raw', 240.0),
          ('\(lookalike)', 200, 'dictation', 'Call — remind me to ring Ben', 'dictated body', 'raw', NULL),
          ('\(plain)', 100, 'dictation', 'ordinary note', 'body', 'raw', NULL);
        """
        XCTAssertEqual(sqlite3_exec(db, insert, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let store = TranscriptStore(path: path)
        XCTAssertEqual(store.transcripts.first { $0.id.uuidString == call }?.source, .call)
        XCTAssertEqual(store.transcripts.first { $0.id.uuidString == lookalike }?.source, .dictation,
                       "a dictation that merely starts with the call prefix must not be reclassified")
        XCTAssertEqual(store.transcripts.first { $0.id.uuidString == plain }?.source, .dictation)

        // And the reclassified call is now a document, so it lists in Documents.
        XCTAssertEqual(store.documents(matching: "").map(\.id.uuidString), [call])
    }

    func testDocumentsCoversFilesAndCallsButNotDictations() {
        let store = makeStore()
        store.addDictation(text: "quick thought", rawText: "raw")
        store.add(Transcript(id: UUID(), createdAt: Date(), source: .file,
                             title: "memo.m4a", text: "imported", rawText: "raw"))
        store.add(Transcript(id: UUID(), createdAt: Date(), source: .call,
                             title: "Call — Zoom, 09:00", text: "call", rawText: "raw"))

        XCTAssertEqual(Set(store.documents(matching: "").map(\.source)), [.file, .call])
    }

    func testCallSourceRoundTripsThroughTheDatabase() {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let store = TranscriptStore(path: path)
        store.add(Transcript(id: UUID(), createdAt: Date(), source: .call,
                             title: "Call — Slack, 11:30", text: "body", rawText: "raw"))
        XCTAssertEqual(TranscriptStore(path: path).transcripts.first?.source, .call)
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
