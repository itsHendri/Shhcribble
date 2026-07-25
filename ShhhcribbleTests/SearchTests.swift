import XCTest
@testable import Shhhcribble

/// Tests for cross-category search — the grouping, and the snippet windowing
/// that decides whether a result explains itself or just shows its first line.
final class SearchTests: XCTestCase {

    private func transcript(_ text: String, title: String? = nil,
                            source: TranscriptSource = .dictation,
                            at: Date = Date()) -> Transcript {
        Transcript(id: UUID(), createdAt: at, source: source,
                   title: title ?? String(text.prefix(60)), text: text, rawText: text)
    }

    private func note(_ text: String, at: Date = Date()) -> Note {
        Note(createdAt: at, modifiedAt: at, text: text)
    }

    // MARK: - Snippet windowing

    func testSnippetWindowsAroundTheMatchRatherThanTheStart() {
        let body = String(repeating: "filler ", count: 40) + "pricing decision" + String(repeating: " tail", count: 40)
        let snippet = Search.snippet(in: body, query: "pricing")

        XCTAssertEqual(snippet.match, "pricing")
        XCTAssertTrue(snippet.leading.hasPrefix("…"), "a cut head should say so")
        XCTAssertTrue(snippet.trailing.hasSuffix("…"), "a cut tail should say so")
        XCTAssertTrue(snippet.plain.contains("pricing decision"))
    }

    /// A match at the very start has nothing cut before it, so no leading
    /// ellipsis — the classic "…Pricing ideas" wart.
    func testSnippetAtTheStartHasNoLeadingEllipsis() {
        let snippet = Search.snippet(in: "Pricing ideas for the launch", query: "pricing")
        XCTAssertEqual(snippet.leading, "")
        XCTAssertEqual(snippet.match, "Pricing", "the source's own casing is preserved")
        XCTAssertFalse(snippet.trailing.hasSuffix("…"))
    }

    func testSnippetIsCaseAndDiacriticInsensitive() {
        XCTAssertEqual(Search.snippet(in: "the CAFÉ list", query: "cafe").match, "CAFÉ")
    }

    func testSnippetWithNoMatchShowsTheHeadAndReportsNoMatch() {
        let snippet = Search.snippet(in: "nothing relevant here", query: "pricing")
        XCTAssertFalse(snippet.isMatch)
        XCTAssertEqual(snippet.match, "")
        XCTAssertTrue(snippet.plain.hasPrefix("nothing relevant"))
    }

    /// Newlines are flattened so a snippet is one readable line rather than a
    /// column of fragments.
    func testSnippetFlattensNewlines() {
        let snippet = Search.snippet(in: "first line\npricing on the second", query: "pricing")
        XCTAssertFalse(snippet.plain.contains("\n"))
    }

    // MARK: - Grouping

    func testResultsGroupByCategory() {
        let grouped = Search.results(
            for: "pricing",
            transcripts: [transcript("summarise the pricing thread"),
                          transcript("hold the pricing discussion", title: "standup.m4a", source: .file),
                          transcript("call about pricing", title: "Call — Zoom", source: .call),
                          transcript("nothing to see")],
            notes: [note("Pricing ideas\nthe paid line is sync"), note("unrelated")])

        XCTAssertEqual(grouped[.notes]?.count, 1)
        XCTAssertEqual(grouped[.dictations]?.count, 1)
        XCTAssertEqual(grouped[.documents]?.count, 2, "calls are documents")
        XCTAssertEqual(Search.total(grouped), 4)
    }

    func testCategoryOrderIsNotesThenDictationsThenDocuments() {
        XCTAssertEqual(SearchCategory.allCases, [.notes, .dictations, .documents])
    }

    func testEmptyQueryReturnsNothing() {
        XCTAssertTrue(Search.results(for: "   ", transcripts: [transcript("pricing")], notes: []).isEmpty)
    }

    /// A note whose *title* matches but whose body doesn't must still appear —
    /// and vice versa.
    func testMatchOnEitherTitleOrBodyQualifies() {
        let titleOnly = Search.results(
            for: "standup",
            transcripts: [transcript("no mention in the body", title: "standup.m4a", source: .file)],
            notes: [])
        XCTAssertEqual(titleOnly[.documents]?.count, 1)

        let bodyOnly = Search.results(
            for: "commitment",
            transcripts: [transcript("anything that looks like a commitment", title: "meeting.m4a", source: .file)],
            notes: [])
        XCTAssertEqual(bodyOnly[.documents]?.count, 1)
    }

    func testResultsAreNewestFirstWithinACategory() {
        let older = transcript("pricing one", at: Date(timeIntervalSince1970: 1_000))
        let newer = transcript("pricing two", at: Date(timeIntervalSince1970: 9_000))
        let grouped = Search.results(for: "pricing", transcripts: [older, newer], notes: [])
        XCTAssertEqual(grouped[.dictations]?.map(\.id), [newer.id, older.id])
    }

    /// Equal timestamps must not reorder between renders.
    func testEqualTimestampsOrderStably() {
        let at = Date(timeIntervalSince1970: 5_000)
        let a = transcript("pricing a", at: at)
        let b = transcript("pricing b", at: at)
        let first = Search.results(for: "pricing", transcripts: [a, b], notes: [])
        let second = Search.results(for: "pricing", transcripts: [b, a], notes: [])
        XCTAssertEqual(first[.dictations]?.map(\.id), second[.dictations]?.map(\.id))
    }

    func testAnchoringMatchesTheStreamsTwoWeights() {
        let grouped = Search.results(
            for: "pricing",
            transcripts: [transcript("pricing chat"),
                          transcript("pricing file", title: "f.m4a", source: .file)],
            notes: [note("pricing note")])

        XCTAssertEqual(grouped[.dictations]?.first?.isAnchored, false)
        XCTAssertEqual(grouped[.documents]?.first?.isAnchored, true)
        XCTAssertEqual(grouped[.notes]?.first?.isAnchored, true)
    }

    /// A note's first line *is* its title, so a match there must not also be
    /// windowed into the body — the result card would print it twice.
    func testTitleMatchIsNotRepeatedInTheBody() {
        let grouped = Search.results(
            for: "pricing",
            transcripts: [],
            notes: [note("Pricing ideas\nthe paid line is sync, not volume")])
        let result = grouped[.notes]!.first!

        XCTAssertTrue(result.title.isMatch)
        XCTAssertFalse(result.body.isMatch, "the body is searched past the first line")
        XCTAssertFalse(result.body.plain.contains("Pricing ideas"))
        XCTAssertTrue(result.body.plain.contains("the paid line"))
    }

    /// …but a match that's only in the body still has to be found.
    func testBodyOnlyMatchInANoteIsStillFound() {
        let grouped = Search.results(
            for: "sync",
            transcripts: [],
            notes: [note("Pricing ideas\nthe paid line is sync")])
        let result = grouped[.notes]!.first!
        XCTAssertFalse(result.title.isMatch)
        XCTAssertTrue(result.body.isMatch)
    }

    func testSnippetFlattensEveryKindOfLineBreak() {
        for breaker in ["\n", "\r\n", "\u{2028}", "\u{2029}"] {
            let snippet = Search.snippet(in: "first\(breaker)pricing second", query: "pricing")
            XCTAssertFalse(snippet.plain.contains(breaker),
                           "line break \(breaker.unicodeScalars.map { $0.value }) survived")
        }
    }

    func testEmptyNoteGetsAStandInTitle() {
        let grouped = Search.results(for: "pricing", transcripts: [], notes: [note("\npricing in the body")])
        XCTAssertEqual(grouped[.notes]?.first?.title.plain, "New note")
    }
}
