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
    /// (a note created before rich text, or promoted from an action item).
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

/// An editable rich-text view: bold/italic/underline via the Format menu
/// (⌘B/⌘I/⌘U), automatic link detection, and clickable links.
///
/// **Why `NSTextView` and not SwiftUI's `TextEditor`:** `TextEditor` only
/// binds to a `String` on our macOS 14 target (the `AttributedString` binding
/// is macOS 15+), and it exposes no link handling. `NSTextView` gives rich
/// text, `NSFontManager` trait toggling, and link clicks for free.
///
/// Bold works because `AppDelegate.installMainMenu()` installs a **Format**
/// menu — the same LSUIElement gap that made ⌘C/⌘V dead before the Edit menu
/// was added: with no menu carrying the key equivalent, the shortcut reaches
/// nothing.
struct RichTextEditor: NSViewRepresentable {

    @Binding var attributed: NSAttributedString
    var font: NSFont = .systemFont(ofSize: 13)
    var insets: NSSize = NSSize(width: 12, height: 10)
    /// Called when the editor gains or loses focus — the sticky panel uses it
    /// to activate the app and to flush its debounced save.
    var onFocusChange: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return scroll }

        textView.delegate = context.coordinator
        textView.isRichText = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = font
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = insets
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        textView.textStorage?.setAttributedString(attributed)
        context.coordinator.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
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
        weak var textView: NSTextView?
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
