import XCTest
@testable import Shhhcribble

final class PersonalDictionaryTests: XCTestCase {

    private func entry(_ phrase: String, _ replacement: String,
                       caseSensitive: Bool = false) -> DictionaryEntry {
        DictionaryEntry(phrase: phrase, replacement: replacement, caseSensitive: caseSensitive)
    }

    func testBasicReplacement() {
        XCTAssertEqual(
            PersonalDictionary.apply([entry("parakeet", "Parakeet")], to: "i met parakeet today"),
            "i met Parakeet today"
        )
    }

    /// Whole-word boundaries: phrases never match inside larger words.
    func testWholeWordDoesNotMatchSubstring() {
        XCTAssertEqual(
            PersonalDictionary.apply([entry("cat", "dog")], to: "the catalog lists a cat"),
            "the catalog lists a dog"
        )
    }

    func testCaseInsensitiveMatchesAnyCaseAndReplacesVerbatim() {
        let entries = [entry("swiss borg", "SwissBorg")]
        XCTAssertEqual(PersonalDictionary.apply(entries, to: "Swiss Borg is great"), "SwissBorg is great")
        XCTAssertEqual(PersonalDictionary.apply(entries, to: "SWISS BORG is great"), "SwissBorg is great")
        XCTAssertEqual(PersonalDictionary.apply(entries, to: "swiss borg is great"), "SwissBorg is great")
    }

    func testCaseSensitiveRequiresExactCase() {
        let entries = [entry("hendri", "Hendri", caseSensitive: true)]
        XCTAssertEqual(PersonalDictionary.apply(entries, to: "ask hendri"), "ask Hendri")
        XCTAssertEqual(PersonalDictionary.apply(entries, to: "ask Hendri"), "ask Hendri")
        XCTAssertEqual(PersonalDictionary.apply(entries, to: "ask HENDRI"), "ask HENDRI")
    }

    func testMultiWordPhraseMidSentence() {
        XCTAssertEqual(
            PersonalDictionary.apply([entry("fluid audio", "FluidAudio")],
                                     to: "we use fluid audio for transcription"),
            "we use FluidAudio for transcription"
        )
    }

    func testPunctuationAdjacentMatchesArePreserved() {
        let entries = [entry("parakeet", "Parakeet")]
        XCTAssertEqual(PersonalDictionary.apply(entries, to: "parakeet, parakeet. (parakeet)"),
                       "Parakeet, Parakeet. (Parakeet)")
    }

    /// Entries apply sequentially in array order — entry 2 sees entry 1's
    /// output, so ordering is the overlap-resolution mechanism.
    func testEntriesApplyInOrderAndCanChain() {
        let forward = [entry("foo", "bar"), entry("bar", "baz")]
        XCTAssertEqual(PersonalDictionary.apply(forward, to: "foo"), "baz")

        let reversed = [entry("bar", "baz"), entry("foo", "bar")]
        XCTAssertEqual(PersonalDictionary.apply(reversed, to: "foo"), "bar")
    }

    func testEmptyDictionaryIsNoOp() {
        XCTAssertEqual(PersonalDictionary.apply([], to: "hello there"), "hello there")
    }

    func testEmptyPhraseEntryIsIgnored() {
        XCTAssertEqual(
            PersonalDictionary.apply([entry("  ", "nope")], to: "hello there"),
            "hello there"
        )
    }

    /// Regex metacharacters in phrase and template metacharacters ($) in the
    /// replacement are treated literally. Also exercises the lookaround
    /// boundaries on a phrase that ends in non-word characters ("c++").
    func testRegexSpecialCharactersAreTreatedLiterally() {
        XCTAssertEqual(
            PersonalDictionary.apply([entry("c++", "C++")], to: "i write c++ daily"),
            "i write C++ daily"
        )
        XCTAssertEqual(
            PersonalDictionary.apply([entry("buck", "$100")], to: "one buck"),
            "one $100"
        )
    }

    func testNoMatchReturnsInputUnchanged() {
        XCTAssertEqual(
            PersonalDictionary.apply([entry("zebra", "Zebra")], to: "no animals here"),
            "no animals here"
        )
    }

    func testEmptyTextStaysEmpty() {
        XCTAssertEqual(PersonalDictionary.apply([entry("a", "b")], to: ""), "")
    }

    /// Stored JSON missing optional keys (`id`, `caseSensitive`) must still
    /// decode — one strict-decode failure would wipe the whole dictionary.
    func testDecodingToleratesMissingOptionalKeys() throws {
        let json = #"[{"phrase": "foo", "replacement": "bar"}]"#
        let decoded = try JSONDecoder().decode([DictionaryEntry].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].phrase, "foo")
        XCTAssertEqual(decoded[0].replacement, "bar")
        XCTAssertFalse(decoded[0].caseSensitive)
    }

    /// Leading non-word characters also anchor correctly (the ".NET" case the
    /// lookaround boundaries exist for).
    func testPhraseWithLeadingNonWordCharacter() {
        XCTAssertEqual(
            PersonalDictionary.apply([entry("dot net", ".NET")], to: "we use dot net here"),
            "we use .NET here"
        )
        XCTAssertEqual(
            PersonalDictionary.apply([entry(".net", ".NET")], to: "i like .net a lot"),
            "i like .NET a lot"
        )
    }
}

/// Tests for `DictionaryImport.parse` — the bulk "paste a word list" parser
/// (left = misheard/phrase, right = correct/replacement).
final class DictionaryImportTests: XCTestCase {

    func testParsesArrowLines() {
        let entries = DictionaryImport.parse("entropic => Anthropic\nclawed => Claude")
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].phrase, "entropic")
        XCTAssertEqual(entries[0].replacement, "Anthropic")
        XCTAssertEqual(entries[1].phrase, "clawed")
        XCTAssertEqual(entries[1].replacement, "Claude")
    }

    func testAcceptsAlternateSeparators() {
        // ->, →, comma
        let entries = DictionaryImport.parse("cube control -> kubectl\nzoo shang → Xuchang\nnext fi, Nexlify")
        XCTAssertEqual(entries.map(\.replacement), ["kubectl", "Xuchang", "Nexlify"])
    }

    func testParsesMarkdownTableRowsAndSkipsHeaderAndSeparator() {
        let table = """
        | Misheard | Correct |
        | --- | --- |
        | entropic | Anthropic |
        | clawed | Claude |
        """
        let entries = DictionaryImport.parse(table)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].phrase, "entropic")
        XCTAssertEqual(entries[0].replacement, "Anthropic")
    }

    func testSkipsBlankAndUnparseableLines() {
        let entries = DictionaryImport.parse("\n  \nentropic => Anthropic\njust some prose with no separator\n")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].replacement, "Anthropic")
    }

    func testTrimsWhitespaceAroundTerms() {
        let entries = DictionaryImport.parse("   entropic    =>    Anthropic   ")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].phrase, "entropic")
        XCTAssertEqual(entries[0].replacement, "Anthropic")
    }

    func testEmptyInputYieldsNoEntries() {
        XCTAssertTrue(DictionaryImport.parse("").isEmpty)
    }
}
