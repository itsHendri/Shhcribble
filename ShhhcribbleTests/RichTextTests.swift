import XCTest
import AppKit
@testable import Shhhcribble

/// Tests for the note rich-text encoding rules and the link-handling policy.
final class RichTextTests: XCTestCase {

    private let font = NSFont.systemFont(ofSize: 13)

    // MARK: - Encoding

    /// Colour must NOT survive into the stored RTF: RTF records literal
    /// resolved colours, so a note written in light mode would come back as
    /// near-black text on a dark background. `attributed(from:)` re-applies the
    /// dynamic `labelColor` on load instead.
    func testEncodingStripsForegroundColor() throws {
        let styled = NSMutableAttributedString(string: "hello", attributes: [.font: font])
        styled.addAttribute(.foregroundColor, value: NSColor.red,
                            range: NSRange(location: 0, length: 5))

        let data = try XCTUnwrap(RichText.data(from: styled))
        let decoded = try XCTUnwrap(NSAttributedString(rtf: data, documentAttributes: nil))
        let colour = decoded.attribute(.foregroundColor, at: 0, effectiveRange: nil)
        XCTAssertNil(colour)
    }

    func testEncodingPreservesBold() throws {
        let bold = NSFont.boldSystemFont(ofSize: 13)
        let styled = NSAttributedString(string: "loud", attributes: [.font: bold])

        let data = try XCTUnwrap(RichText.data(from: styled))
        let decoded = try XCTUnwrap(NSAttributedString(rtf: data, documentAttributes: nil))
        let decodedFont = try XCTUnwrap(decoded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(decodedFont.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testRoundTripPreservesPlainString() throws {
        let original = NSAttributedString(string: "line one\nline two", attributes: [.font: font])
        let data = try XCTUnwrap(RichText.data(from: original))
        let back = RichText.attributed(from: data, plain: "", font: font)
        XCTAssertEqual(back.string, "line one\nline two")
    }

    // MARK: - Decoding / fallback

    func testFallsBackToPlainWhenNoRichData() {
        let result = RichText.attributed(from: nil, plain: "just text", font: font)
        XCTAssertEqual(result.string, "just text")
        XCTAssertEqual(result.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, font)
    }

    func testFallsBackToPlainWhenDataIsNotRTF() {
        let garbage = Data("definitely not rtf".utf8)
        let result = RichText.attributed(from: garbage, plain: "fallback", font: font)
        XCTAssertEqual(result.string, "fallback")
    }

    func testEmptyStringDecodesWithoutCrashing() {
        XCTAssertEqual(RichText.attributed(from: nil, plain: "", font: font).string, "")
    }

    // MARK: - Link detection

    /// Notes that predate rich text (or arrive from an action item) are plain
    /// strings, so their URLs need an explicit detection pass to be clickable.
    func testLinksAreDetectedInPlainText() {
        let result = RichText.attributed(from: nil, plain: "see https://example.com for docs", font: font)
        let range = (result.string as NSString).range(of: "https://example.com")
        let link = result.attribute(.link, at: range.location, effectiveRange: nil)
        XCTAssertNotNil(link)
    }

    func testDetectionLeavesNonLinkTextAlone() {
        let result = RichText.attributed(from: nil, plain: "no urls at all here", font: font)
        var found = false
        result.enumerateAttribute(.link, in: NSRange(location: 0, length: result.length)) { value, _, _ in
            if value != nil { found = true }
        }
        XCTAssertFalse(found)
    }

    func testDetectionDoesNotOverwriteAnExistingLink() {
        let string = NSMutableAttributedString(string: "https://example.com", attributes: [.font: font])
        let custom = URL(string: "https://deliberately-different.example")!
        string.addAttribute(.link, value: custom, range: NSRange(location: 0, length: string.length))
        RichText.addDetectedLinks(to: string)
        XCTAssertEqual(string.attribute(.link, at: 0, effectiveRange: nil) as? URL, custom)
    }

    // MARK: - Link-opening policy

    /// Note text can originate from a transcript (dictated, or an AI-extracted
    /// action item), so a clicked link isn't necessarily something the user
    /// typed on purpose. Only the harmless web/mail schemes are handed to
    /// NSWorkspace.
    func testOnlyWebAndMailSchemesAreOpenable() {
        XCTAssertTrue(RichText.isOpenable(URL(string: "https://example.com")!))
        XCTAssertTrue(RichText.isOpenable(URL(string: "http://example.com")!))
        XCTAssertTrue(RichText.isOpenable(URL(string: "mailto:someone@example.com")!))

        XCTAssertFalse(RichText.isOpenable(URL(string: "file:///etc/passwd")!))
        XCTAssertFalse(RichText.isOpenable(URL(string: "ftp://example.com")!))
        XCTAssertFalse(RichText.isOpenable(URL(string: "javascript:alert(1)")!))
        XCTAssertFalse(RichText.isOpenable(URL(string: "x-apple-shortcuts://run-shortcut?name=x")!))
    }

    func testSchemeMatchIsCaseInsensitive() {
        XCTAssertTrue(RichText.isOpenable(URL(string: "HTTPS://example.com")!))
        XCTAssertFalse(RichText.isOpenable(URL(string: "FILE:///tmp/x")!))
    }
}
