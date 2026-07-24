import XCTest
import AppKit
import SwiftUI
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

        let data = try XCTUnwrap(RichText.data(from: styled, font: font))
        let decoded = try XCTUnwrap(NSAttributedString(rtf: data, documentAttributes: nil))
        let colour = decoded.attribute(.foregroundColor, at: 0, effectiveRange: nil)
        XCTAssertNil(colour)
    }

    func testEncodingPreservesBold() throws {
        let bold = NSFont.boldSystemFont(ofSize: 13)
        let styled = NSAttributedString(string: "loud", attributes: [.font: bold])

        let data = try XCTUnwrap(RichText.data(from: styled, font: font))
        let decoded = try XCTUnwrap(NSAttributedString(rtf: data, documentAttributes: nil))
        let decodedFont = try XCTUnwrap(decoded.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(decodedFont.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testRoundTripPreservesPlainString() throws {
        let original = NSAttributedString(string: "line one\nline two", attributes: [.font: font])
        let data = try XCTUnwrap(RichText.data(from: original, font: font))
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

    // MARK: - Real key-equivalent dispatch
    //
    // The tests above call the action methods directly, which proves the trait
    // maths but NOT that ⌘B ever reaches them — the bug the user hit. These
    // drive the actual AppKit path: a real window, the view as first responder,
    // a synthetic ⌘B, through `NSWindow.performKeyEquivalent`.

    @MainActor
    private func commandKeyEvent(_ character: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: character,
            charactersIgnoringModifiers: character,
            isARepeat: false,
            keyCode: 0
        )!
    }

    @MainActor
    func testCommandBReachesTheViewThroughTheWindow() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = makeView("hello world")
        window.contentView?.addSubview(view)
        view.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertTrue(window.makeFirstResponder(view))

        let handled = window.performKeyEquivalent(with: commandKeyEvent("b"))
        XCTAssertTrue(handled, "⌘B was not claimed by the text view")
        XCTAssertTrue(isBold(view, at: 0), "⌘B reached the view but didn't bold the selection")
    }

    /// **The bug that made ⌘B look dead.** `NSApplication` offers a key
    /// equivalent to the **main menu before the key window**, so any main-menu
    /// item carrying ⌘B/⌘I/⌘U swallows the shortcut — the view's handler never
    /// runs. A Format menu did exactly that: it claimed ⌘B and its action never
    /// reached the text view. The menu was removed (an LSUIElement app shows no
    /// menu bar, so it only ever carried key equivalents); this test stops one
    /// being reintroduced.
    @MainActor
    func testMainMenuDoesNotSwallowStylingKeys() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu, "the app installs a main menu at launch")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = makeView("hello world")
        window.contentView?.addSubview(view)
        view.setSelectedRange(NSRange(location: 0, length: 5))
        window.makeFirstResponder(view)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }

        for key in ["b", "i", "u"] {
            XCTAssertFalse(
                menu.performKeyEquivalent(with: commandKeyEvent(key)),
                "a main-menu item claimed ⌘\(key.uppercased()); it will swallow the shortcut before the editor sees it"
            )
        }
    }

    /// The same path, but through the SwiftUI wrapper the app actually uses —
    /// an `NSHostingView` sits between the window and the text view, and it
    /// must not swallow the key equivalent.
    @MainActor
    func testCommandBSurvivesTheSwiftUIHostingView() throws {
        final class Box { var value = NSAttributedString(string: "hello world") }
        let box = Box()
        let editor = RichTextEditor(
            attributed: Binding(get: { box.value }, set: { box.value = $0 }),
            font: font
        )
        let hosting = NSHostingView(rootView: editor)
        hosting.frame = NSRect(x: 0, y: 0, width: 300, height: 200)

        let window = NSWindow(contentRect: hosting.frame,
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        let view = try XCTUnwrap(firstRichTextView(in: hosting), "no RichTextView was built")
        view.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertTrue(window.makeFirstResponder(view))

        let handled = window.performKeyEquivalent(with: commandKeyEvent("b"))
        XCTAssertTrue(handled, "⌘B was swallowed before reaching the text view")
        XCTAssertTrue(isBold(view, at: 0))
    }

    /// Focus must be reported from first-responder changes, not from
    /// `textDidBeginEditing` — a sticky the user clicked into but hasn't typed
    /// in yet has to count as focused, or the app is never activated and ⌘V
    /// (which routes through the *active* app's Edit menu) does nothing.
    @MainActor
    func testFocusIsReportedOnClickInNotFirstKeystroke() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = makeView("hello")
        window.contentView?.addSubview(view)

        var reported: [Bool] = []
        view.onFocusChange = { reported.append($0) }

        XCTAssertTrue(window.makeFirstResponder(view))
        XCTAssertEqual(reported, [true], "focus was not reported without an edit")

        window.makeFirstResponder(nil)
        XCTAssertEqual(reported, [true, false], "focus loss was not reported")
    }

    @MainActor
    private func firstRichTextView(in view: NSView) -> RichTextView? {
        if let match = view as? RichTextView { return match }
        for subview in view.subviews {
            if let match = firstRichTextView(in: subview) { return match }
        }
        return nil
    }

    // MARK: - Line height stability

    /// Bold/italic faces have different ascender+descender than regular, so
    /// without a pinned minimum the line height changes the instant you press
    /// ⌘B and surrounding text jumps.
    func testLineHeightCoversTheBoldestVariant() {
        let style = RichText.paragraphStyle(for: font)
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let boldHeight = ceil(bold.ascender - bold.descender + bold.leading)

        XCTAssertGreaterThanOrEqual(style.minimumLineHeight, boldHeight,
                                    "bold text would be taller than the pinned line, so it would still jump")
    }

    /// Only a minimum is pinned — a maximum would clip text pasted in at a
    /// larger size, the one case where the line *should* grow.
    func testLineHeightIsNotCapped() {
        XCTAssertEqual(RichText.paragraphStyle(for: font).maximumLineHeight, 0)
    }

    func testLoadedTextCarriesTheLineHeight() throws {
        let result = RichText.attributed(from: nil, plain: "hello", font: font)
        let style = try XCTUnwrap(
            result.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertGreaterThan(style.minimumLineHeight, 0)
    }

    /// The line-height floor is display-only, re-applied on load — baking it
    /// into the stored RTF would freeze today's metric into every existing note.
    func testLineHeightFloorIsNotPersisted() throws {
        let styled = RichText.attributed(from: nil, plain: "hello", font: font)
        let data = try XCTUnwrap(RichText.data(from: styled, font: font))
        let decoded = try XCTUnwrap(NSAttributedString(rtf: data, documentAttributes: nil))
        let style = decoded.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        // RTF always yields *some* paragraph style; what matters is that our
        // pinned minimum isn't among what got written.
        XCTAssertEqual(style?.minimumLineHeight ?? 0, 0)
    }

    /// Only the injected floor is cleared on save. An earlier cut removed the
    /// whole `.paragraphStyle` attribute, which silently flattened anything
    /// pasted in — a bulleted or indented block survived until the autosave
    /// fired and then came back as plain text.
    func testPastedParagraphFormattingSurvivesARoundTrip() throws {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.headIndent = 24
        paragraph.firstLineHeadIndent = 12
        paragraph.paragraphSpacing = 7
        let pasted = NSAttributedString(string: "indented and centred",
                                        attributes: [.font: font, .paragraphStyle: paragraph])

        let data = try XCTUnwrap(RichText.data(from: pasted, font: font))
        let restored = RichText.attributed(from: data, plain: "", font: font)
        let style = try XCTUnwrap(
            restored.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)

        XCTAssertEqual(style.alignment, .center)
        XCTAssertEqual(style.headIndent, 24)
        XCTAssertEqual(style.firstLineHeadIndent, 12)
        XCTAssertEqual(style.paragraphSpacing, 7)
        // …and the floor is layered back on top of the preserved structure.
        XCTAssertGreaterThan(style.minimumLineHeight, 0)
    }

    /// A paragraph that already asks for more room than our floor keeps its own
    /// value — the floor raises, it never lowers.
    func testExistingLargerLineHeightIsNotReduced() throws {
        let roomy = NSMutableParagraphStyle()
        roomy.minimumLineHeight = 400
        let pasted = NSAttributedString(string: "big",
                                        attributes: [.font: font, .paragraphStyle: roomy])
        let restored = RichText.attributed(from: RichText.data(from: pasted, font: font), plain: "", font: font)
        let style = try XCTUnwrap(
            restored.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.minimumLineHeight, 400)
    }

    /// Styling must survive the store round-trip, or bold would vanish the
    /// moment a note is reopened.
    @MainActor
    func testStylingSurvivesStorageRoundTrip() throws {
        let view = makeView("hello world")
        view.setSelectedRange(NSRange(location: 0, length: 5))
        view.toggleBoldTrait(nil)

        let data = try XCTUnwrap(RichText.data(from: view.attributedString(), font: font))
        let restored = RichText.attributed(from: data, plain: "", font: font)
        let restoredFont = try XCTUnwrap(restored.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(restoredFont.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(restored.string, "hello world")
    }
}
