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

    // MARK: - Inline styling
    //
    // `RichTextView` implements ⌘B/⌘I/⌘U itself rather than going through the
    // Format menu → NSFontManager route (which silently did nothing in this
    // LSUIElement app). These pin the toggle behaviour directly.

    @MainActor
    private func makeView(_ text: String) -> RichTextView {
        let view = RichTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        view.isRichText = true
        view.font = font
        view.textStorage?.setAttributedString(
            NSAttributedString(string: text, attributes: [.font: font]))
        return view
    }

    @MainActor
    private func isBold(_ view: RichTextView, at index: Int) -> Bool {
        guard let f = view.textStorage?.attribute(.font, at: index, effectiveRange: nil) as? NSFont
        else { return false }
        return f.fontDescriptor.symbolicTraits.contains(.bold)
    }

    @MainActor
    func testBoldAppliesToSelection() {
        let view = makeView("hello world")
        view.setSelectedRange(NSRange(location: 0, length: 5))
        view.toggleBoldTrait(nil)

        XCTAssertTrue(isBold(view, at: 0))
        XCTAssertFalse(isBold(view, at: 6))   // outside the selection, untouched
    }

    @MainActor
    func testBoldTogglesBackOffWhenAlreadyBold() {
        let view = makeView("hello")
        view.setSelectedRange(NSRange(location: 0, length: 5))
        view.toggleBoldTrait(nil)
        XCTAssertTrue(isBold(view, at: 0))

        view.toggleBoldTrait(nil)
        XCTAssertFalse(isBold(view, at: 0))
    }

    /// A selection that's only partly bold should end up uniformly bold, not
    /// have each run flip against itself.
    @MainActor
    func testMixedSelectionFlipsTogether() {
        let view = makeView("hello world")
        view.setSelectedRange(NSRange(location: 0, length: 5))
        view.toggleBoldTrait(nil)          // "hello" bold, " world" plain

        view.setSelectedRange(NSRange(location: 0, length: 11))
        view.toggleBoldTrait(nil)          // leading run is bold → remove
        XCTAssertFalse(isBold(view, at: 0))
        XCTAssertFalse(isBold(view, at: 6))
    }

    @MainActor
    func testItalicAppliesToSelection() {
        let view = makeView("hello")
        view.setSelectedRange(NSRange(location: 0, length: 5))
        view.toggleItalicTrait(nil)

        let f = view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(f?.fontDescriptor.symbolicTraits.contains(.italic), true)
    }

    @MainActor
    func testUnderlineTogglesOnAndOff() {
        let view = makeView("hello")
        view.setSelectedRange(NSRange(location: 0, length: 5))

        view.toggleUnderlineTrait(nil)
        let on = view.textStorage?.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
        XCTAssertEqual(on, NSUnderlineStyle.single.rawValue)

        view.toggleUnderlineTrait(nil)
        let off = view.textStorage?.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
        XCTAssertEqual(off, 0)
    }

    /// With no selection the shortcut changes what gets typed next, rather
    /// than doing nothing.
    @MainActor
    func testBoldWithEmptySelectionSetsTypingAttributes() {
        let view = makeView("hello")
        view.setSelectedRange(NSRange(location: 5, length: 0))
        view.toggleBoldTrait(nil)

        let typing = view.typingAttributes[.font] as? NSFont
        XCTAssertEqual(typing?.fontDescriptor.symbolicTraits.contains(.bold), true)
    }

    /// Styling must survive the store round-trip, or bold would vanish the
    /// moment a note is reopened.
    @MainActor
    func testStylingSurvivesStorageRoundTrip() throws {
        let view = makeView("hello world")
        view.setSelectedRange(NSRange(location: 0, length: 5))
        view.toggleBoldTrait(nil)

        let data = try XCTUnwrap(RichText.data(from: view.attributedString()))
        let restored = RichText.attributed(from: data, plain: "", font: font)
        let restoredFont = try XCTUnwrap(restored.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(restoredFont.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(restored.string, "hello world")
    }
}
