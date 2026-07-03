import XCTest
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

    // MARK: - Helpers

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
