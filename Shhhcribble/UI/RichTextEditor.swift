import SwiftUI
import AppKit

/// Conversion between an `NSAttributedString` and the RTF blob we persist,
/// plus the link-detection pass. Kept separate from the view so the encoding
/// rules are testable and shared by the store.
enum RichText {

    /// Attributes we intentionally persist. Everything else (notably colour —
    /// see `data(from:)`) is stripped so notes render correctly in whichever
    /// appearance they're later opened in.
    static let documentType: [NSAttributedString.DocumentAttributeKey: Any] =
        [.documentType: NSAttributedString.DocumentType.rtf]

    /// Encode for storage. **Foreground colour is deliberately stripped:** RTF
    /// stores literal resolved colours, so a note typed in light mode would
    /// persist near-black text and become invisible after a switch to dark
    /// mode. With no colour stored, `attributed(from:)` re-applies the dynamic
    /// `labelColor`, which resolves per appearance at draw time.
    static func data(from attributed: NSAttributedString) -> Data? {
        let clean = NSMutableAttributedString(attributedString: attributed)
        let full = NSRange(location: 0, length: clean.length)
        clean.removeAttribute(.foregroundColor, range: full)
        clean.removeAttribute(.backgroundColor, range: full)
        return clean.rtf(from: full, documentAttributes: documentType)
    }

    /// Decode a stored blob, falling back to `plain` when there's no RTF yet
    /// (a note created before rich text, or added from an action item).
    /// Always normalises colour and re-runs link detection so migrated plain
    /// text gets clickable links too.
    static func attributed(from data: Data?, plain: String, font: NSFont) -> NSAttributedString {
        let base: NSMutableAttributedString
        if let data, let decoded = NSAttributedString(rtf: data, documentAttributes: nil) {
            base = NSMutableAttributedString(attributedString: decoded)
        } else {
            base = NSMutableAttributedString(string: plain, attributes: [.font: font])
        }
        let full = NSRange(location: 0, length: base.length)
        guard full.length > 0 else { return base }

        // Any run without a font (possible in hand-built strings) gets ours, so
        // the editor never falls back to Helvetica 12.
        base.enumerateAttribute(.font, in: full) { value, range, _ in
            if value == nil { base.addAttribute(.font, value: font, range: range) }
        }
        // Dynamic colour, resolved per appearance at draw time. Links still
        // render blue: `linkTextAttributes` overrides this for `.link` ranges.
        base.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
        addDetectedLinks(to: base)
        return base
    }

    /// Add `.link` attributes for any URL-shaped text that doesn't already
    /// carry one. NSTextView's automatic detection only fires while typing or
    /// pasting, so loaded text needs this explicit pass.
    static func addDetectedLinks(to string: NSMutableAttributedString) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let full = NSRange(location: 0, length: string.length)
        for match in detector.matches(in: string.string, range: full) {
            guard let url = match.url else { continue }
            if string.attribute(.link, at: match.range.location, effectiveRange: nil) == nil {
                string.addAttribute(.link, value: url, range: match.range)
            }
        }
    }

    /// Schemes we're willing to hand to `NSWorkspace`. Note text can originate
    /// from a transcript (dictated, or an AI-extracted action item), so a
    /// clicked link is not necessarily something the user typed deliberately —
    /// keep this to the harmless web/mail set rather than opening arbitrary
    /// schemes like `file:` or a third-party app's custom scheme.
    static let openableSchemes: Set<String> = ["http", "https", "mailto"]

    static func isOpenable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return openableSchemes.contains(scheme)
    }
}

/// The text view behind `RichTextEditor`.
///
/// **It handles ⌘B/⌘I/⌘U itself** rather than relying on the standard
/// Format-menu → `NSFontManager.addFontTrait(_:)` route. That route has several
/// links that must all hold (the menu item must survive auto-enable validation
/// against the font manager, the font manager must be tracking the view's
/// selected font, and `changeFont:` must reach the view through the responder
/// chain) — and in this LSUIElement app it silently did nothing. A view-level
/// `performKeyEquivalent` is one link instead of four, and it fires *before*
/// the main menu gets the event, so it works the same in the Studio window and
/// in a nonactivating sticky panel.
final class RichTextView: NSTextView {

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only claim the shortcut when this view actually has focus —
        // otherwise ⌘B typed into the search field would style a note.
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "b": toggleBoldTrait(nil);      return true
        case "i": toggleItalicTrait(nil);    return true
        case "u": toggleUnderlineTrait(nil); return true
        default:  return super.performKeyEquivalent(with: event)
        }
    }

    // Also exposed as actions so the Format menu items (nil target → responder
    // chain) drive the exact same code.

    @objc func toggleBoldTrait(_ sender: Any?) { toggleTrait(.boldFontMask) }

    @objc func toggleItalicTrait(_ sender: Any?) { toggleTrait(.italicFontMask) }

    @objc func toggleUnderlineTrait(_ sender: Any?) {
        let range = selectedRange()
        if range.length == 0 {
            let current = typingAttributes[.underlineStyle] as? Int ?? 0
            typingAttributes[.underlineStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            return
        }
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: nil) else { return }
        let current = storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0
        let updated = current == 0 ? NSUnderlineStyle.single.rawValue : 0
        storage.beginEditing()
        storage.addAttribute(.underlineStyle, value: updated, range: range)
        storage.endEditing()
        didChangeText()
    }

    /// Add the trait, or remove it if the selection already starts with it, so
    /// the shortcut toggles the way it does everywhere else. With an empty
    /// selection it changes what gets typed next (also standard).
    private func toggleTrait(_ trait: NSFontTraitMask) {
        let manager = NSFontManager.shared
        let fallback = font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let range = selectedRange()

        if range.length == 0 {
            let current = typingAttributes[.font] as? NSFont ?? fallback
            typingAttributes[.font] = converted(current, trait: trait,
                                                removing: manager.traits(of: current).contains(trait))
            return
        }

        guard let storage = textStorage, shouldChangeText(in: range, replacementString: nil) else { return }
        // Decide once, from the start of the selection, so a mixed run flips
        // together instead of each sub-run toggling against itself.
        let leading = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        let removing = leading.map { manager.traits(of: $0).contains(trait) } ?? false

        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let base = value as? NSFont ?? fallback
            storage.addAttribute(.font, value: converted(base, trait: trait, removing: removing),
                                 range: subrange)
        }
        storage.endEditing()
        didChangeText()
    }

    private func converted(_ font: NSFont, trait: NSFontTraitMask, removing: Bool) -> NSFont {
        let manager = NSFontManager.shared
        return removing ? manager.convert(font, toNotHaveTrait: trait)
                        : manager.convert(font, toHaveTrait: trait)
    }
}

/// An editable rich-text view: bold/italic/underline via ⌘B/⌘I/⌘U, automatic
/// link detection, and clickable links.
///
/// **Why `NSTextView` and not SwiftUI's `TextEditor`:** `TextEditor` only binds
/// to a `String` on our macOS 14 target (the `AttributedString` binding is
/// macOS 15+), and it exposes no link handling.
struct RichTextEditor: NSViewRepresentable {

    @Binding var attributed: NSAttributedString
    var font: NSFont = .systemFont(ofSize: 13)
    var insets: NSSize = NSSize(width: 12, height: 10)
    /// Called when the editor gains or loses focus — the sticky panel uses it
    /// to activate the app and to flush its debounced save.
    var onFocusChange: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // Built by hand rather than via `NSTextView.scrollableTextView()` so
        // the view is our `RichTextView` subclass (which owns the formatting
        // shortcuts).
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let unbounded = CGFloat.greatestFiniteMagnitude
        let container = NSTextContainer(size: NSSize(width: CGFloat.zero, height: unbounded))
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)

        let textView = RichTextView(frame: .zero, textContainer: container)
        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = font
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = insets
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: CGFloat.zero, height: CGFloat.zero)
        textView.maxSize = NSSize(width: unbounded, height: unbounded)
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
        textView.textStorage?.setAttributedString(attributed)

        scroll.documentView = textView
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? RichTextView else { return }
        context.coordinator.parent = self

        // Never overwrite while the user is typing: the binding lags the view
        // by the caller's save debounce, so pushing it back in would fight the
        // cursor. (Same invariant as the sticky's `update(with:)`.)
        guard !context.coordinator.isEditing,
              textView.attributedString() != attributed else { return }
        textView.textStorage?.setAttributedString(attributed)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        weak var textView: RichTextView?
        private(set) var isEditing = false

        init(_ parent: RichTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.attributed = textView.attributedString()
        }

        func textDidBeginEditing(_ notification: Notification) {
            isEditing = true
            parent.onFocusChange?(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            isEditing = false
            // Push the final value through before the caller flushes its save.
            if let textView = notification.object as? NSTextView {
                parent.attributed = textView.attributedString()
            }
            parent.onFocusChange?(false)
        }

        /// Open a clicked link, but only for schemes we've vetted — see
        /// `RichText.openableSchemes`. Returning `true` marks the click handled
        /// either way, so an unvetted link is inert rather than dangerous.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url: URL?
            switch link {
            case let u as URL:      url = u
            case let s as String:   url = URL(string: s)
            default:                url = nil
            }
            guard let url, RichText.isOpenable(url) else { return true }
            NSWorkspace.shared.open(url)
            return true
        }
    }
}
