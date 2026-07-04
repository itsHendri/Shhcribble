import XCTest
import SQLite3
@testable import Shhhcribble

/// Pure-logic tests for the SQLite-backed transcript store. Uses an in-memory
/// DB (":memory:") so nothing touches disk; migration tests seed and clean up
/// UserDefaults.standard around themselves.
@MainActor
final class TranscriptStoreTests: XCTestCase {

    private let legacyKey = "transcriptionHistory"
    private let migrationFlag = "didMigrateHistoryToSQLite"

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: legacyKey)
        UserDefaults.standard.removeObject(forKey: migrationFlag)
        super.tearDown()
    }

    private func makeStore() -> TranscriptStore { TranscriptStore(path: ":memory:") }

    // MARK: - CRUD

    func testAddDictationStoresBothTexts() {
        let store = makeStore()
        let t = store.addDictation(text: "Hello world.", rawText: "hello world")
        XCTAssertEqual(store.transcripts.count, 1)
        XCTAssertEqual(store.transcripts.first?.id, t.id)
        XCTAssertEqual(store.transcripts.first?.text, "Hello world.")
        XCTAssertEqual(store.transcripts.first?.rawText, "hello world")
        XCTAssertEqual(store.transcripts.first?.source, .dictation)
        XCTAssertEqual(store.transcripts.first?.title, "Hello world.")
    }

    func testNewestFirstOrdering() {
        let store = makeStore()
        let older = Date(timeIntervalSince1970: 1000)
        let newer = Date(timeIntervalSince1970: 2000)
        store.add(makeFile(title: "old.m4a", date: older))
        store.add(makeFile(title: "new.m4a", date: newer))
        // add() prepends, and reload sorts by createdAt DESC — newest on top.
        XCTAssertEqual(store.transcripts.first?.title, "new.m4a")
        XCTAssertEqual(store.transcripts.last?.title, "old.m4a")
    }

    func testDeleteRemovesRow() {
        let store = makeStore()
        let a = store.addDictation(text: "one", rawText: "one")
        _ = store.addDictation(text: "two", rawText: "two")
        store.delete(a.id)
        XCTAssertEqual(store.transcripts.count, 1)
        XCTAssertFalse(store.transcripts.contains { $0.id == a.id })
    }

    func testClearAllEmptiesStore() {
        let store = makeStore()
        store.addDictation(text: "one", rawText: "one")
        store.addDictation(text: "two", rawText: "two")
        store.clearAll()
        XCTAssertTrue(store.transcripts.isEmpty)
    }

    func testFileTranscriptPersistsMetadata() {
        let store = makeStore()
        store.add(Transcript(
            id: UUID(), createdAt: Date(), source: .file,
            title: "interview.m4a", text: "cleaned", rawText: "raw",
            fileName: "interview.m4a", sourcePath: "/tmp/interview.m4a", durationSec: 62.5
        ))
        let stored = store.transcripts.first
        XCTAssertEqual(stored?.source, .file)
        XCTAssertEqual(stored?.fileName, "interview.m4a")
        XCTAssertEqual(stored?.sourcePath, "/tmp/interview.m4a")
        XCTAssertEqual(stored?.durationSec, 62.5)
    }

    // MARK: - Search

    func testMatchingIsCaseInsensitiveOverTitleAndText() {
        let store = makeStore()
        store.add(makeFile(title: "Standup.m4a", text: "Discussing the ROADMAP today"))
        store.addDictation(text: "Reply to Marcus about billing", rawText: "reply")

        XCTAssertEqual(store.matching("roadmap").count, 1)        // matches text
        XCTAssertEqual(store.matching("standup").count, 1)        // matches title, case-insensitive
        XCTAssertEqual(store.matching("MARCUS").count, 1)         // matches dictation text
        XCTAssertEqual(store.matching("nonexistent").count, 0)
        XCTAssertEqual(store.matching("").count, 2)               // empty → everything
    }

    // MARK: - Migration

    func testMigratesLegacyHistoryNewestFirstAsDictation() throws {
        // Seed legacy history (newest-first, as the old code stored it).
        let legacy = [
            ["text": "newest", "date": 3000.0],
            ["text": "middle", "date": 2000.0],
            ["text": "oldest", "date": 1000.0],
        ]
        let payload = legacy.map { ["text": $0["text"] as! String,
                                    "date": Date(timeIntervalSinceReferenceDate: $0["date"] as! Double)] }
        let data = try JSONEncoder().encode(payload.map { LegacyRow(text: $0["text"] as! String,
                                                                    date: $0["date"] as! Date) })
        UserDefaults.standard.set(data, forKey: legacyKey)
        UserDefaults.standard.removeObject(forKey: migrationFlag)

        let store = makeStore()
        store.migrateLegacyHistoryIfNeeded()

        XCTAssertEqual(store.transcripts.count, 3)
        XCTAssertEqual(store.transcripts.first?.text, "newest")
        XCTAssertEqual(store.transcripts.last?.text, "oldest")
        XCTAssertTrue(store.transcripts.allSatisfy { $0.source == .dictation })
        XCTAssertTrue(UserDefaults.standard.bool(forKey: migrationFlag))
    }

    func testMigrationRunsOnlyOnce() throws {
        let data = try JSONEncoder().encode([LegacyRow(text: "one", date: Date())])
        UserDefaults.standard.set(data, forKey: legacyKey)
        UserDefaults.standard.removeObject(forKey: migrationFlag)

        let store = makeStore()
        store.migrateLegacyHistoryIfNeeded()
        store.migrateLegacyHistoryIfNeeded()   // second call is a no-op
        XCTAssertEqual(store.transcripts.count, 1)
    }

    // MARK: - Summary (Sprint 4b)

    func testUpdateSummaryPersistsAcrossReload() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let id: UUID
        do {
            let store = TranscriptStore(path: path)
            let t = store.addDictation(text: "Talked about the Q3 launch and budget.", rawText: "raw")
            id = t.id
            store.updateSummary(id: id,
                                summary: "The team discussed the Q3 launch and its budget.",
                                actionItems: ["Draft the launch plan", "Confirm the budget"],
                                generatedAt: Date(timeIntervalSince1970: 5000))
            // In-memory copy reflects the update immediately.
            let mem = store.transcripts.first { $0.id == id }
            XCTAssertEqual(mem?.summary, "The team discussed the Q3 launch and its budget.")
            XCTAssertEqual(mem?.actionItems, ["Draft the launch plan", "Confirm the budget"])
            XCTAssertEqual(mem?.summaryGeneratedAt, Date(timeIntervalSince1970: 5000))
        }
        // Fresh store on the same file → data must survive a reload.
        let reopened = TranscriptStore(path: path)
        let row = reopened.transcripts.first { $0.id == id }
        XCTAssertEqual(row?.summary, "The team discussed the Q3 launch and its budget.")
        XCTAssertEqual(row?.actionItems, ["Draft the launch plan", "Confirm the budget"])
        XCTAssertEqual(row?.summaryGeneratedAt, Date(timeIntervalSince1970: 5000))
    }

    func testEmptyActionItemsRoundTripsAsEmpty() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let id: UUID
        do {
            let store = TranscriptStore(path: path)
            let t = store.addDictation(text: "Just a note to self.", rawText: "raw")
            id = t.id
            store.updateSummary(id: id, summary: "A short note.", actionItems: [])
        }
        let reopened = TranscriptStore(path: path)
        let row = reopened.transcripts.first { $0.id == id }
        XCTAssertEqual(row?.summary, "A short note.")
        XCTAssertEqual(row?.actionItems, [])
    }

    func testTranscriptWithoutSummaryHasNilDefaults() {
        let store = makeStore()
        let t = store.addDictation(text: "no summary yet", rawText: "raw")
        let row = store.transcripts.first { $0.id == t.id }
        XCTAssertNil(row?.summary)
        XCTAssertEqual(row?.actionItems, [])
        XCTAssertNil(row?.summaryGeneratedAt)
    }

    func testUpdateSummaryUnknownIDIsNoOp() {
        let store = makeStore()
        store.addDictation(text: "one", rawText: "one")
        store.updateSummary(id: UUID(), summary: "orphan", actionItems: ["x"])
        XCTAssertTrue(store.transcripts.allSatisfy { $0.summary == nil })
    }

    // MARK: - Notes (Sprint 4c)

    func testNotesDefaultsToEmpty() {
        let store = makeStore()
        let t = store.addDictation(text: "no notes yet", rawText: "raw")
        XCTAssertEqual(store.transcripts.first { $0.id == t.id }?.notes, "")
    }

    func testUpdateNotesPersistsAcrossReload() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let id: UUID
        do {
            let store = TranscriptStore(path: path)
            id = store.addDictation(text: "meeting recap", rawText: "raw").id
            store.updateNotes(id: id, notes: "follow up with Sarah\ncheck the numbers")
            XCTAssertEqual(store.transcripts.first { $0.id == id }?.notes,
                           "follow up with Sarah\ncheck the numbers")
        }
        let reopened = TranscriptStore(path: path)
        XCTAssertEqual(reopened.transcripts.first { $0.id == id }?.notes,
                       "follow up with Sarah\ncheck the numbers")
    }

    func testClearingNotesRoundTripsAsEmpty() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let id: UUID
        do {
            let store = TranscriptStore(path: path)
            id = store.addDictation(text: "note", rawText: "raw").id
            store.updateNotes(id: id, notes: "temporary")
            store.updateNotes(id: id, notes: "")   // cleared
        }
        let reopened = TranscriptStore(path: path)
        XCTAssertEqual(reopened.transcripts.first { $0.id == id }?.notes, "")
    }

    func testUpdateNotesUnknownIDIsNoOp() {
        let store = makeStore()
        store.addDictation(text: "one", rawText: "one")
        store.updateNotes(id: UUID(), notes: "orphan")
        XCTAssertTrue(store.transcripts.allSatisfy { $0.notes.isEmpty })
    }

    func testSearchMatchesNotes() {
        let store = makeStore()
        let t = store.addDictation(text: "unrelated body", rawText: "raw")
        store.updateNotes(id: t.id, notes: "Zephyr project kickoff")
        XCTAssertEqual(store.matching("zephyr").count, 1)   // case-insensitive, notes-only hit
        XCTAssertEqual(store.matching("nothere").count, 0)
    }

    // MARK: - Schema migration (v0 → latest)

    /// Latest schema version — bumped as migrations are added (v1 summary, v2 notes).
    private let latestSchemaVersion: Int32 = 2

    func testMigrationAddsColumnsToOldSchemaAndKeepsRows() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Seed a pre-4b (9-column, user_version 0) database with one row.
        let existingID = UUID()
        seedOldSchemaDB(at: path, id: existingID)

        // Opening with the current store must ALTER in all later columns,
        // preserve the old row, and bump user_version to the latest.
        let store = TranscriptStore(path: path)
        XCTAssertEqual(store.transcripts.count, 1)
        let old = store.transcripts.first
        XCTAssertEqual(old?.id, existingID)
        XCTAssertEqual(old?.text, "legacy body")
        XCTAssertNil(old?.summary)                 // new columns default to NULL
        XCTAssertEqual(old?.actionItems, [])
        XCTAssertNil(old?.summaryGeneratedAt)
        XCTAssertEqual(old?.notes, "")             // v2 column, coalesced from NULL
        XCTAssertEqual(userVersion(at: path), latestSchemaVersion)

        // And the migrated DB is fully writable via the new column paths.
        store.updateSummary(id: existingID, summary: "now summarized", actionItems: ["do it"])
        store.updateNotes(id: existingID, notes: "my note")
        let reopened = TranscriptStore(path: path)
        XCTAssertEqual(reopened.transcripts.first?.summary, "now summarized")
        XCTAssertEqual(reopened.transcripts.first?.actionItems, ["do it"])
        XCTAssertEqual(reopened.transcripts.first?.notes, "my note")
    }

    func testMigrationHealsPartiallyAppliedSchema() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Simulate a migration interrupted after adding only `summary` (still at
        // user_version 0). Re-opening must add ONLY the missing columns — not
        // fail on "duplicate column name" for `summary` — and reach the latest.
        let existingID = UUID()
        seedOldSchemaDB(at: path, id: existingID, extraColumns: ["summary TEXT"])

        let store = TranscriptStore(path: path)
        XCTAssertEqual(store.transcripts.count, 1)
        XCTAssertEqual(userVersion(at: path), latestSchemaVersion)
        // All columns now usable end to end.
        store.updateSummary(id: existingID, summary: "healed", actionItems: ["a", "b"])
        store.updateNotes(id: existingID, notes: "healed note")
        let reopened = TranscriptStore(path: path)
        XCTAssertEqual(reopened.transcripts.first?.summary, "healed")
        XCTAssertEqual(reopened.transcripts.first?.actionItems, ["a", "b"])
        XCTAssertEqual(reopened.transcripts.first?.notes, "healed note")
    }

    /// A DB already at v1 (summary columns present, notes absent) must take only
    /// the v2 step and add `notes`.
    func testMigrationV1ToV2AddsNotes() throws {
        let path = tempDBPath()
        defer { try? FileManager.default.removeItem(atPath: path) }

        let existingID = UUID()
        seedOldSchemaDB(at: path, id: existingID,
                        extraColumns: ["summary TEXT", "actionItems TEXT", "summaryGeneratedAt REAL"],
                        userVersion: 1)

        let store = TranscriptStore(path: path)
        XCTAssertEqual(store.transcripts.count, 1)
        XCTAssertEqual(store.transcripts.first?.notes, "")
        XCTAssertEqual(userVersion(at: path), latestSchemaVersion)
        store.updateNotes(id: existingID, notes: "added at v2")
        let reopened = TranscriptStore(path: path)
        XCTAssertEqual(reopened.transcripts.first?.notes, "added at v2")
    }

    // MARK: - Helpers

    private func tempDBPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("shhh-test-\(UUID().uuidString).sqlite").path
    }

    /// Creates a database matching the original (pre-summary) schema so the
    /// migration path can be exercised against a realistic upgrade.
    private func seedOldSchemaDB(at path: String, id: UUID, extraColumns: [String] = [], userVersion: Int32 = 0) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let create = """
        CREATE TABLE transcripts (
            id TEXT PRIMARY KEY, createdAt REAL NOT NULL, source TEXT NOT NULL,
            title TEXT NOT NULL, text TEXT NOT NULL, rawText TEXT NOT NULL,
            fileName TEXT, sourcePath TEXT, durationSec REAL
        );
        """
        XCTAssertEqual(sqlite3_exec(db, create, nil, nil, nil), SQLITE_OK)
        // Optionally pre-add some later columns to model a partial/prior migration.
        for column in extraColumns {
            XCTAssertEqual(sqlite3_exec(db, "ALTER TABLE transcripts ADD COLUMN \(column);", nil, nil, nil), SQLITE_OK)
        }
        let insert = """
        INSERT INTO transcripts (id, createdAt, source, title, text, rawText, fileName, sourcePath, durationSec)
        VALUES ('\(id.uuidString)', 1000.0, 'dictation', 'Legacy', 'legacy body', 'legacy raw', NULL, NULL, NULL);
        """
        XCTAssertEqual(sqlite3_exec(db, insert, nil, nil, nil), SQLITE_OK)
        // user_version defaults to 0; set explicitly when modeling a prior migration.
        if userVersion != 0 {
            XCTAssertEqual(sqlite3_exec(db, "PRAGMA user_version = \(userVersion);", nil, nil, nil), SQLITE_OK)
        }
    }

    private func userVersion(at path: String) -> Int32 {
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { return -1 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : -1
    }

    private func makeFile(title: String, text: String = "body", date: Date = Date()) -> Transcript {
        Transcript(id: UUID(), createdAt: date, source: .file,
                   title: title, text: text, rawText: text,
                   fileName: title, sourcePath: "/tmp/\(title)", durationSec: nil)
    }

    /// Mirrors the store's private legacy shape for encoding test fixtures.
    private struct LegacyRow: Codable {
        let text: String
        let date: Date
    }
}
