import XCTest
@testable import Shhhcribble

/// Pins the SKILL.md import parsing: frontmatter name/description extraction,
/// body-as-prompt, and the graceful whole-file fallback.
final class SkillFileParserTests: XCTestCase {

    func testFrontmatterNameAndBody() {
        let md = """
        ---
        name: Email Style
        description: Formal email tone
        ---
        Rewrite the transcript as a polite email.
        Keep it professional.
        """
        let parsed = SkillFileParser.parse(md)
        XCTAssertEqual(parsed.name, "Email Style")
        XCTAssertEqual(parsed.prompt, "Rewrite the transcript as a polite email.\nKeep it professional.")
    }

    func testDescriptionUsedWhenNoName() {
        let md = """
        ---
        description: My tone
        ---
        Body text.
        """
        let parsed = SkillFileParser.parse(md)
        XCTAssertEqual(parsed.name, "My tone")
        XCTAssertEqual(parsed.prompt, "Body text.")
    }

    func testNoFrontmatterWholeFileIsPrompt() {
        let md = "Just an instruction with no frontmatter."
        let parsed = SkillFileParser.parse(md)
        XCTAssertNil(parsed.name)
        XCTAssertEqual(parsed.prompt, "Just an instruction with no frontmatter.")
    }

    func testQuotedNameIsUnwrapped() {
        let md = """
        ---
        name: "Quoted Name"
        ---
        Body.
        """
        XCTAssertEqual(SkillFileParser.parse(md).name, "Quoted Name")
    }

    func testFrontmatterOnlyFallsBackToDescriptionAsPrompt() {
        let md = """
        ---
        name: Terse
        description: Make it terse and direct
        ---
        """
        let parsed = SkillFileParser.parse(md)
        XCTAssertEqual(parsed.name, "Terse")
        XCTAssertEqual(parsed.prompt, "Make it terse and direct")
    }

    func testCRLFNewlinesHandled() {
        let md = "---\r\nname: Win\r\n---\r\nWindows body.\r\n"
        let parsed = SkillFileParser.parse(md)
        XCTAssertEqual(parsed.name, "Win")
        XCTAssertEqual(parsed.prompt, "Windows body.")
    }

    func testUnterminatedFrontmatterTreatedAsWholeFile() {
        // A leading `---` with no closing fence isn't valid frontmatter — the
        // whole thing is the prompt, name nil.
        let md = "---\nname: Broken\nstill going"
        let parsed = SkillFileParser.parse(md)
        XCTAssertNil(parsed.name)
        XCTAssertTrue(parsed.prompt.contains("still going"))
    }

    func testLeadingAndTrailingWhitespaceTrimmed() {
        let parsed = SkillFileParser.parse("\n\n  hello  \n\n")
        XCTAssertEqual(parsed.prompt, "hello")
    }
}
