import XCTest
@testable import Shhhcribble

/// Tests for the merged Notes shelf — the list that replaced two identical
/// master-details with one (2026-08-28). The ordering is the part worth pinning:
/// a list that reshuffles between renders churns `ForEach` identity, and the
/// interleave is the whole claim the merge rests on.
final class NotesLibraryTests: XCTestCase {

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_000_000 + offset)
    }

    private func note(_ offset: TimeInterval, _ text: String, id: UUID = UUID()) -> Note {
        Note(id: id, createdAt: date(offset), modifiedAt: date(offset), text: text)
    }

    private func document(_ offset: TimeInterval, _ title: String,
                          source: TranscriptSource = .file, id: UUID = UUID()) -> Transcript {
        Transcript(id: id, createdAt: date(offset), source: source,
                   title: title, text: "body", rawText: "raw")
    }

    func testMergedInterleavesBothKindsNewestFirst() {
        let rows = NotesLibrary.merged(
            notes: [note(10, "older note"), note(40, "newest note")],
            documents: [document(20, "import.m4a"), document(30, "Call — WhatsApp", source: .call)])

        XCTAssertEqual(rows.map(\.title),
                       ["newest note", "Call — WhatsApp", "import.m4a", "older note"])
    }

    func testMergedIsEmptyForAnEmptyLibrary() {
        XCTAssertTrue(NotesLibrary.merged(notes: [], documents: []).isEmpty)
    }

    /// Equal timestamps must produce a stable order or the list reshuffles
    /// between renders. Likelier here than in the day stream: a note promoted
    /// from a document's action item can share its second.
    func testEqualTimestampsOrderStably() {
        let n = note(10, "note")
        let d = document(10, "doc.m4a")
        let first = NotesLibrary.merged(notes: [n], documents: [d])
        let second = NotesLibrary.merged(notes: [n], documents: [d])
        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    /// The row carries which kind it is, because the detail pane forks on it.
    func testRowsReportTheirKindAndIdentity() {
        let n = note(10, "written")
        let d = document(20, "recorded.m4a")
        let rows = NotesLibrary.merged(notes: [n], documents: [d])

        XCTAssertEqual(rows.first?.id, .document(d.id))
        XCTAssertEqual(rows.last?.id, .note(n.id))
        XCTAssertTrue(rows.first?.isDocument == true)
        XCTAssertFalse(rows.last?.isDocument == true)
    }

    /// A selection names its kind, so a note and a document that somehow shared
    /// an id could never be confused for each other.
    func testSelectionDistinguishesKindsSharingAnID() {
        let id = UUID()
        XCTAssertNotEqual(NoteListSelection.note(id), NoteListSelection.document(id))
        XCTAssertEqual(NoteListSelection.note(id).id, id)
        XCTAssertEqual(NoteListSelection.document(id).id, id)
    }

    // MARK: - The stuck / rest partition

    /// The two groups must be exact complements: every row appears in exactly
    /// one, so nothing is dropped from the list or shown twice. This is the
    /// assertion the merged shelf rests on.
    func testPartitionIsExhaustiveAndDisjoint() {
        var stuck = note(30, "on screen"); stuck.stuck = true
        let rows = NotesLibrary.merged(
            notes: [note(10, "plain"), stuck, note(40, "another")],
            documents: [document(20, "import.m4a"), document(35, "call", source: .call)])

        let groups = NotesLibrary.partitioned(rows)
        XCTAssertEqual(groups.onScreen.count + groups.rest.count, rows.count)
        XCTAssertEqual(Set(groups.onScreen.map(\.id)).intersection(groups.rest.map(\.id)), [])
        XCTAssertEqual(Set(groups.onScreen.map(\.id)).union(groups.rest.map(\.id)),
                       Set(rows.map(\.id)))
    }

    /// A document can never reach the "On your screen" group — it isn't
    /// something you put on your screen, and `Transcript` has no `stuck`.
    func testDocumentsAreNeverOnScreen() {
        let groups = NotesLibrary.partitioned(NotesLibrary.merged(
            notes: [], documents: [document(20, "import.m4a"), document(30, "call", source: .call)]))

        XCTAssertTrue(groups.onScreen.isEmpty)
        XCTAssertEqual(groups.rest.count, 2)
    }

    func testPartitionSelectsExactlyTheStuckNotes() {
        var stuck = note(30, "on screen"); stuck.stuck = true
        let groups = NotesLibrary.partitioned(NotesLibrary.merged(
            notes: [note(10, "plain"), stuck], documents: [document(20, "doc.m4a")]))

        XCTAssertEqual(groups.onScreen.map(\.title), ["on screen"])
        XCTAssertEqual(groups.rest.map(\.title), ["doc.m4a", "plain"])
    }

    func testPartitionOfNothingIsTwoEmptyGroups() {
        let groups = NotesLibrary.partitioned([])
        XCTAssertTrue(groups.onScreen.isEmpty)
        XCTAssertTrue(groups.rest.isEmpty)
    }

    /// A document's title comes from the transcript, a note's from its first
    /// line — the row shows one field, so it has to pick the right one.
    func testTitleComesFromTheRightField() {
        let rows = NotesLibrary.merged(
            notes: [note(10, "First line\nsecond line")],
            documents: [document(20, "standup.m4a")])
        XCTAssertEqual(rows.map(\.title), ["standup.m4a", "First line"])
    }
}
