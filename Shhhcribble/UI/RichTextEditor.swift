import SwiftUI
import AppKit


/// Conversion between an `NSAttributedString` and the RTF blob we persist,
/// plus the link-detection pass. Kept separate from the view so the encoding
/// rules are testable and shared by the store.
enum RichText {

    /// The editor's default body font — one base for the Notes pane and the
    /// stickies alike, so the same note doesn't get a different line-height
    /// floor depending on which editor last saved it.
    static let baseFont = NoteTextStyle.paragraph.font

    /// Classes allowed when decoding a stored note. Explicit (rather than
    /// switching secure coding off) so a corrupt or tampered blob can't
    /// instantiate arbitrary classes; anything outside this set fails the
    /// decode and falls back to the plain-text mirror.
    private static let decodableClasses: [AnyClass] = [
        NSAttributedString.self, NSMutableAttributedString.self,
        NSFont.self, NSColor.self, NSParagraphStyle.self, NSMutableParagraphStyle.self,
        NSTextAttachment.self, NSImage.self, NSURL.self, NSTextList.self,
        NSString.self, NSNumber.self, NSArray.self, NSDictionary.self,
    ]

    /// Encode for storage as a keyed archive of the attributed string.
    ///
    /// **Not RTF — measured, not assumed.** RTF cannot represent the system
    /// font: `.AppleSystemUIFont` round-trips to `HelveticaNeue`, so a note
    /// silently changed typeface the first time it was reloaded, and pasted
    /// text degraded to whatever the RTF font table could resolve. A keyed
    /// archive preserves fonts, colours, paragraph structure and attachments
    /// exactly.
    ///
    /// It also removes the reason colour used to be stripped here: RTF stores
    /// literal resolved colours (so a note typed in light mode came back
    /// near-black on dark), but an archive keeps `labelColor` as the *dynamic*
    /// colour it is, resolving per appearance at draw time. Pasted colours and
    /// highlights are therefore kept as-is.
    ///
    /// - Parameter font: the editor's base font, needed to recognise the exact
    ///   line-height floor this editor injected so only that value is cleared.
    static func data(from attributed: NSAttributedString, font: NSFont) -> Data? {
        let clean = NSMutableAttributedString(attributedString: attributed)
        clearLineHeightFloor(in: clean, font: font)
        return try? NSKeyedArchiver.archivedData(withRootObject: clean, requiringSecureCoding: true)
    }

    /// Decode a stored blob: a keyed archive, or — for notes written before the
    /// format change — the legacy RTF. Returns nil if it is neither, and the
    /// caller falls back to the plain-text mirror.
    private static func decode(_ data: Data) -> NSAttributedString? {
        if let archived = try? NSKeyedUnarchiver.unarchivedObject(
            ofClasses: decodableClasses, from: data) as? NSAttributedString {
            return archived
        }
        return NSAttributedString(rtf: data, documentAttributes: nil)
    }

    /// Drop **only** the line-height floor this editor injected, leaving lists,
    /// indents, alignment, spacing — and a paragraph's *own* line height —
    /// intact.
    ///
    /// The floor is a display concern, re-applied on load — same treatment as
    /// colour — so the constant stays tunable and old notes aren't frozen to
    /// today's metric. Removing the whole `.paragraphStyle` attribute (the
    /// first cut) destroyed the structure of anything pasted in: a bulleted or
    /// indented block survived until the autosave fired and then came back as
    /// flat text. Matching the exact floor value, rather than clearing any
    /// non-zero minimum, is what also preserves a pasted paragraph's own
    /// generous line spacing.
    private static func clearLineHeightFloor(in string: NSMutableAttributedString, font: NSFont) {
        let floor = paragraphStyle(for: font).minimumLineHeight
        rewriteParagraphStyles(in: string) { style in
            guard style.minimumLineHeight == floor else { return nil }
            let stripped = NSMutableParagraphStyle()
            stripped.setParagraphStyle(style)
            stripped.minimumLineHeight = 0
            return stripped
        }
    }

    /// Raise each paragraph's `minimumLineHeight` to our floor, preserving
    /// every other paragraph attribute. Runs carrying no style at all get the
    /// plain floor style.
    private static func applyLineHeightFloor(to string: NSMutableAttributedString, font: NSFont) {
        let floor = paragraphStyle(for: font).minimumLineHeight
        rewriteParagraphStyles(in: string) { style in
            guard style.minimumLineHeight < floor else { return nil }
            let raised = NSMutableParagraphStyle()
            raised.setParagraphStyle(style)
            raised.minimumLineHeight = floor
            return raised
        }
    }

    /// Apply `transform` to every paragraph-style run (absent styles are seen
    /// as `.default`); returning nil leaves a run untouched. Ranges are
    /// collected first, then written — mutating inside `enumerateAttribute`
    /// invalidates the enumeration.
    private static func rewriteParagraphStyles(
        in string: NSMutableAttributedString,
        _ transform: (NSParagraphStyle) -> NSParagraphStyle?
    ) {
        let full = NSRange(location: 0, length: string.length)
        guard full.length > 0 else { return }
        var updates: [(NSRange, NSParagraphStyle)] = []
        string.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            let base = (value as? NSParagraphStyle) ?? .default
            if let replacement = transform(base) { updates.append((range, replacement)) }
        }
        for (range, style) in updates {
            string.addAttribute(.paragraphStyle, value: style, range: range)
        }
    }

    /// Paragraph style that keeps the baseline grid steady as text is styled.
    ///
    /// **Why:** bold and italic variants of a face don't share the regular
    /// one's ascender/descender, so line height changes the moment you press
    /// ⌘B and the surrounding text visibly jumps. Pinning
    /// `minimumLineHeight` to the *tallest* variant we can produce means every
    /// weight already fits within it, so nothing moves.
    ///
    /// Deliberately only a **minimum**, never `maximumLineHeight`: pinning both
    /// would clip text pasted in at a larger size, which is the one case where
    /// growing the line is correct.
    static func paragraphStyle(for font: NSFont) -> NSParagraphStyle {
        let manager = NSFontManager.shared
        let bold = manager.convert(font, toHaveTrait: .boldFontMask)
        let italic = manager.convert(font, toHaveTrait: .italicFontMask)
        let boldItalic = manager.convert(bold, toHaveTrait: .italicFontMask)

        let tallest = [font, bold, italic, boldItalic]
            .map { ceil($0.ascender - $0.descender + $0.leading) }
            .max() ?? ceil(font.ascender - font.descender + font.leading)

        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = tallest
        return style
    }

    /// Decode a stored blob, falling back to `plain` when there's no RTF yet
    /// (a note created before rich text, or added from an action item).
    /// Always normalises colour and re-runs link detection so migrated plain
    /// text gets clickable links too.
    static func attributed(from data: Data?, plain: String, font: NSFont) -> NSAttributedString {
        let base: NSMutableAttributedString
        if let data, let decoded = decode(data) {
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
        // Only runs with NO colour of their own get the dynamic `labelColor`
        // (plain text, and legacy RTF notes, which were stored colourless).
        // Deliberate colour — including anything pasted in — is left alone;
        // blanket-overriding it would wipe a pasted highlight's text colour.
        // Links still render blue regardless: `linkTextAttributes` overrides
        // this for `.link` ranges.
        base.enumerateAttribute(.foregroundColor, in: full) { value, range, _ in
            if value == nil {
                base.addAttribute(.foregroundColor, value: NSColor.labelColor, range: range)
            }
        }
        applyLineHeightFloor(to: base, font: font)
        addDetectedLinks(to: base)
        return base
    }

    /// Convert every font in `string` onto the app's ramp: the system family,
    /// with each run's size mapped by how large it is relative to the pasted
    /// content's *own* body text. Bold and italic are carried over; everything
    /// that isn't a font — links, highlights, colours, lists, indentation,
    /// alignment — is left untouched.
    ///
    /// This is what keeps a note reading as one document instead of a
    /// patchwork of whatever fonts its sources happened to use.
    static func normalizingFonts(in string: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: string)
        let full = NSRange(location: 0, length: result.length)
        guard full.length > 0 else { return result }

        let body = dominantFontSize(in: result) ?? NoteTextStyle.paragraph.size
        let manager = NSFontManager.shared
        var updates: [(NSRange, NSFont)] = []

        result.enumerateAttribute(.font, in: full) { value, range, _ in
            guard let incoming = value as? NSFont else {
                updates.append((range, NoteTextStyle.paragraph.font))
                return
            }
            let step = NoteTextStyle.step(forRatio: incoming.pointSize / body)
            var replacement = step.font
            let traits = manager.traits(of: incoming)
            // Heading steps supply their own weight — only carry bold across
            // when the step wouldn't already be bold, or body text that was
            // emphasised loses its emphasis.
            if traits.contains(.boldFontMask), step.weight == .regular {
                replacement = manager.convert(replacement, toHaveTrait: .boldFontMask)
            }
            if traits.contains(.italicFontMask) {
                replacement = manager.convert(replacement, toHaveTrait: .italicFontMask)
            }
            updates.append((range, replacement))
        }
        for (range, font) in updates { result.addAttribute(.font, value: font, range: range) }
        return result
    }

    /// The font size covering the most characters — the document's body size,
    /// which anchors the relative mapping above.
    private static func dominantFontSize(in string: NSAttributedString) -> CGFloat? {
        var coverage: [CGFloat: Int] = [:]
        string.enumerateAttribute(.font, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            coverage[font.pointSize, default: 0] += range.length
        }
        return coverage.max { $0.value < $1.value }?.key
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

    /// Reports **focus**, not the edit lifecycle. Driven by first-responder
    /// changes rather than `textDidBeginEditing`/`textDidEndEditing`, which
    /// only fire once the text actually changes: a sticky the user had clicked
    /// into but not yet typed in was still reported unfocused, so the app was
    /// never activated and ⌘V — which routes through the *active* app's Edit
    /// menu — did nothing until a character had been typed first.
    var onFocusChange: ((Bool) -> Void)?

    /// Focus means "the caret is here **and** this window is the one receiving
    /// keys" — not merely first-responder status.
    ///
    /// **Load-bearing:** first-responder changes alone are not enough. Clicking
    /// a floating sticky makes *that panel* key while the Studio window keeps
    /// its text view as first responder, so `resignFirstResponder` never fires
    /// there. The detail pane then believed it was still being edited forever:
    /// it refused every store update (leaving it stale next to the sticky) and
    /// later wrote that stale content back over the sticky's edits.
    /// Tracked rather than read back from `window?.firstResponder`: AppKit
    /// updates that property *after* calling these overrides, so reading it
    /// here always reports the previous responder.
    private var holdsFirstResponder = false

    /// Test seam. The XCTest host app is never activated, so no window is ever
    /// key inside it and the focus transition this whole mechanism exists for
    /// can't otherwise be exercised. Always nil in the app.
    var windowKeyOverride: Bool?

    private var windowIsKey: Bool { windowKeyOverride ?? (window?.isKeyWindow == true) }

    private var isFocused: Bool { holdsFirstResponder && windowIsKey }

    private var lastReportedFocus = false
    private var focusObservers: [NSObjectProtocol] = []

    /// Re-evaluate and report focus. Called by the overrides and the window-key
    /// notifications; exposed so a test can drive it after flipping
    /// `windowKeyOverride`.
    func refreshFocusState() { reportFocusIfChanged() }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            holdsFirstResponder = true
            reportFocusIfChanged()
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            holdsFirstResponder = false
            reportFocusIfChanged()
        }
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
        focusObservers.removeAll()
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                focusObservers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in self?.reportFocusIfChanged() })
            }
        }
        reportFocusIfChanged()
    }

    /// Report only on an actual edge — `resignFirstResponder` and the window
    /// notifications can both fire for one logical focus change.
    private func reportFocusIfChanged() {
        let focused = isFocused
        guard focused != lastReportedFocus else { return }
        lastReportedFocus = focused
        onFocusChange?(focused)
    }

    /// The highlighter colour. **Translucent on purpose:** a solid yellow with
    /// the dynamic `labelColor` on top is unreadable in dark mode (white text
    /// on bright yellow). At 30% the underlying background shows through, so it
    /// reads as pale yellow on light and muted amber on dark, and the text
    /// stays legible in both without needing an appearance-specific colour.
    static let highlightColor = NSColor.systemYellow.withAlphaComponent(0.30)

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Compare only the modifiers we care about — a stuck Caps Lock or the
        // function flag would otherwise stop an exact `== .command` match.
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // Only claim the shortcut when this view actually has focus —
        // otherwise ⌘B typed into the search field would style a note.
        guard window?.firstResponder === self,
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        if flags == .command, let style = NoteTextStyle.allCases.first(where: { $0.shortcutKey == key }) {
            applyTextStyle(style)
            return true
        }
        switch (flags, key) {
        case (.command, "b"):          toggleBoldTrait(nil);      return true
        case (.command, "i"):          toggleItalicTrait(nil);    return true
        case (.command, "u"):          toggleUnderlineTrait(nil); return true
        case ([.command, .shift], "h"): toggleHighlight(nil);     return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    /// Right-click menu carries the styling commands too. An LSUIElement app
    /// shows no menu bar, so without this the shortcuts would be the *only*
    /// way to discover that notes can be styled at all. Safe where a Format
    /// menu was not: a contextual menu is built per-click and never sits in
    /// the main menu, so it can't intercept the key equivalents.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let commands: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Bold",      #selector(toggleBoldTrait(_:)),      "b", .command),
            ("Italic",    #selector(toggleItalicTrait(_:)),    "i", .command),
            ("Underline", #selector(toggleUnderlineTrait(_:)), "u", .command),
            ("Highlight", #selector(toggleHighlight(_:)),      "h", [.command, .shift]),
        ]
        for (index, command) in commands.enumerated() {
            let item = NSMenuItem(title: command.0, action: command.1, keyEquivalent: command.2)
            item.keyEquivalentModifierMask = command.3
            item.target = self
            menu.insertItem(item, at: index)
        }

        let styleItem = NSMenuItem(title: "Style", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        let current = currentTextStyle
        for style in NoteTextStyle.allCases {
            let item = NSMenuItem(title: style.label,
                                  action: #selector(applyStyleFromMenu(_:)),
                                  keyEquivalent: style.shortcutKey)
            item.keyEquivalentModifierMask = .command
            item.representedObject = style.rawValue
            item.target = self
            // Tick the step the caret is currently in — without it the menu is
            // write-only: you can't tell what a paragraph is or whether ⌘2 took.
            item.state = (style == current) ? .on : .off
            styleMenu.addItem(item)
        }
        styleItem.submenu = styleMenu
        menu.insertItem(styleItem, at: commands.count)

        menu.insertItem(.separator(), at: commands.count + 1)
        return menu
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleBoldTrait(_:)), #selector(toggleItalicTrait(_:)),
             #selector(toggleUnderlineTrait(_:)), #selector(toggleHighlight(_:)),
             #selector(applyStyleFromMenu(_:)):
            return isEditable
        default:
            return super.validateMenuItem(item)
        }
    }

    // Exposed as `@objc` actions so they're also reachable through the
    // responder chain — but note there is deliberately **no Format menu**
    // carrying ⌘B/⌘I/⌘U (see `AppDelegate.installMainMenu`): a menu item is
    // offered the key equivalent before the key window and swallows it.

    @objc func toggleBoldTrait(_ sender: Any?) { toggleTrait(.boldFontMask) }

    @objc func toggleItalicTrait(_ sender: Any?) { toggleTrait(.italicFontMask) }

    /// Paste, converting the incoming fonts onto the app's ramp so a note stays
    /// typographically consistent no matter where its content came from.
    /// Structure, links, colours and highlights come through untouched — see
    /// `RichText.normalizingFonts`.
    ///
    /// `pasteAsPlainText(_:)` (⌥⇧⌘V) is deliberately left to `super`: it
    /// already discards all formatting, so there is nothing to normalise.
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        guard let incoming = pasteboard.readObjects(
                forClasses: [NSAttributedString.self], options: nil)?.first as? NSAttributedString,
              incoming.length > 0 else {
            super.paste(sender)
            return
        }
        let normalized = RichText.normalizingFonts(in: incoming)
        let range = rangeForUserTextChange
        guard range.location != NSNotFound,
              shouldChangeText(in: range, replacementString: normalized.string) else {
            super.paste(sender)
            return
        }
        textStorage?.replaceCharacters(in: range, with: normalized)
        didChangeText()
    }

    /// Apply a ramp step to every paragraph the selection touches (⌘1–⌘5).
    ///
    /// Paragraph-scoped on purpose: a heading is a property of the line, not of
    /// whichever characters happened to be selected. Italic is carried over —
    /// the step's own weight wins, so applying Title to bold text isn't a
    /// double-bold.
    func applyTextStyle(_ style: NoteTextStyle) {
        guard let storage = textStorage else { return }
        let paragraph = (string as NSString).paragraphRange(for: selectedRange())
        guard paragraph.length > 0,
              shouldChangeText(in: paragraph, replacementString: nil) else { return }

        let manager = NSFontManager.shared
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: paragraph) { value, subrange, _ in
            var replacement = style.font
            if let existing = value as? NSFont,
               manager.traits(of: existing).contains(.italicFontMask) {
                replacement = manager.convert(replacement, toHaveTrait: .italicFontMask)
            }
            storage.addAttribute(.font, value: replacement, range: subrange)
        }
        storage.endEditing()
        didChangeText()
        // Keep typing in the style just applied.
        typingAttributes[.font] = style.font
    }

    /// The ramp step the caret's paragraph is in, or nil when its size matches
    /// no step (mid-edit, or pasted text that hasn't been restyled).
    var currentTextStyle: NoteTextStyle? {
        guard let storage = textStorage, storage.length > 0 else {
            return NoteTextStyle.matching(size: (font ?? RichText.baseFont).pointSize)
        }
        let paragraph = (string as NSString).paragraphRange(for: selectedRange())
        let probe = min(paragraph.location, storage.length - 1)
        guard let font = storage.attribute(.font, at: probe, effectiveRange: nil) as? NSFont else {
            return nil
        }
        return NoteTextStyle.matching(size: font.pointSize)
    }

    @objc private func applyStyleFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = NoteTextStyle(rawValue: raw) else { return }
        applyTextStyle(style)
    }

    deinit {
        focusObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Toggle the highlighter over the selection (⌘⇧H). Un-highlighting clears
    /// any background colour on the run, including one that arrived by paste —
    /// "remove the highlight" is the only sensible reading of the command.
    @objc func toggleHighlight(_ sender: Any?) {
        let range = selectedRange()
        if range.length == 0 {
            let highlighted = typingAttributes[.backgroundColor] != nil
            typingAttributes[.backgroundColor] = highlighted ? nil : Self.highlightColor
            return
        }
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: nil) else { return }
        let highlighted = storage.attribute(.backgroundColor, at: range.location, effectiveRange: nil) != nil
        storage.beginEditing()
        if highlighted {
            storage.removeAttribute(.backgroundColor, range: range)
        } else {
            storage.addAttribute(.backgroundColor, value: Self.highlightColor, range: range)
        }
        storage.endEditing()
        didChangeText()
    }

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

/// A handle onto a live `RichTextEditor`, for edits that have to be applied to
/// the text view itself rather than through the `attributed` binding.
///
/// **Why the binding isn't enough.** Assigning to the binding lands via
/// `setAttributedString`, which is not an undoable operation — and in the sticky
/// panel it deliberately clears the undo stack. An AI transform replaces the
/// user's whole note, so it is exactly the edit that most needs ⌘Z to work.
/// Routing it through `shouldChangeText`/`didChangeText` registers it as one
/// undo group, so a single ⌘Z puts the original back.
@MainActor
final class NoteEditorProxy: ObservableObject {
    fileprivate weak var textView: RichTextView?

    /// Is an editor currently attached? False while no note is open.
    var isAttached: Bool { textView != nil }

    /// The styling a floating capsule can apply. Named rather than passed as a
    /// selector so the call site can't reach an arbitrary action.
    enum Style { case bold, italic, underline, highlight }

    /// Apply `style` to the current selection.
    ///
    /// Goes through the text view's own actions — the same ones ⌘B/⌘I/⌘U and
    /// the right-click menu use — so all three routes share one implementation
    /// and one set of `shouldChangeText`/`didChangeText` calls, which is what
    /// keeps undo and the save debounce working.
    func apply(_ style: Style) {
        guard let textView else { return }
        switch style {
        case .bold:      textView.toggleBoldTrait(nil)
        case .italic:    textView.toggleItalicTrait(nil)
        case .underline: textView.toggleUnderlineTrait(nil)
        case .highlight: textView.toggleHighlight(nil)
        }
    }

    /// Replace the entire contents as **one** undoable edit. Returns false if
    /// there's no editor attached or the text system refused the change.
    @discardableResult
    func replaceAll(with replacement: NSAttributedString) -> Bool {
        guard let textView, let storage = textView.textStorage else { return false }
        let whole = NSRange(location: 0, length: storage.length)
        guard textView.shouldChangeText(in: whole, replacementString: replacement.string) else {
            return false
        }
        storage.replaceCharacters(in: whole, with: replacement)
        textView.didChangeText()
        return true
    }

    /// Append to the end as one undoable edit, separating from existing content
    /// with a blank line.
    ///
    /// **Reads the live text view rather than any captured copy.** Dictation
    /// runs for as long as the user talks, and they may well keep typing while
    /// it does — building the new value from the text as it was when recording
    /// started would silently throw those keystrokes away.
    @discardableResult
    func append(_ addition: NSAttributedString, attributes: [NSAttributedString.Key: Any]) -> Bool {
        guard let textView, let storage = textView.textStorage else { return false }
        let existing = storage.string
        let separator = existing.isEmpty ? "" : (existing.hasSuffix("\n") ? "" : "\n\n")
        let piece = NSMutableAttributedString(string: separator, attributes: attributes)
        piece.append(addition)

        let end = NSRange(location: storage.length, length: 0)
        guard textView.shouldChangeText(in: end, replacementString: piece.string) else { return false }
        storage.replaceCharacters(in: end, with: piece)
        textView.didChangeText()
        textView.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
        return true
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

    /// True while this editor holds a user edit that hasn't been persisted.
    /// The editor sets it on a real edit; the owner clears it once its
    /// debounced save lands, and store pushes are refused while it's set.
    ///
    /// **This, not focus, is what guards the two-editor case.** Focus was
    /// load-bearing for two unrelated questions — "did the user type?" and "may
    /// we overwrite what's on screen?" — so whenever focus misreported (and on
    /// a nonactivating sticky panel it did), edits silently failed to save
    /// *and* incoming changes could overwrite text mid-keystroke.
    @Binding var hasPendingEdit: Bool

    var font: NSFont = RichText.baseFont
    var insets: NSSize = NSSize(width: 12, height: 10)
    /// Extra scrollable space below the last line. Set it when something floats
    /// over the bottom of the editor (the Notes pane's stick capsule): without
    /// it the final lines sit permanently under the overlay, unreachable — a
    /// list can scroll its rows clear of a floating button, but the end of a
    /// document can't scroll past the end of itself.
    var bottomInset: CGFloat = 0
    /// Gains/loses focus. Only used for things that are harmless to get wrong:
    /// activating the app (so ⌘V works in a sticky) and flushing on blur.
    var onFocusChange: ((Bool) -> Void)?
    /// A genuine user edit landed — the owner schedules its debounced save from
    /// this. `NSTextView` distinguishes it from a programmatic
    /// `setAttributedString`, which is exactly the distinction that was missing.
    var onUserEdit: (() -> Void)?

    /// Drop the undo stack whenever content is pushed in programmatically.
    ///
    /// Set by the sticky panel, where **one editor is reused across tabs**: the
    /// undo stack would otherwise still hold the previous note's edits, so ⌘Z
    /// after switching tabs would replace *this* note's text with the other
    /// note's — corruption, not a papercut. Reusing the view (rather than
    /// rebuilding it per tab, which would also isolate the stack) is what keeps
    /// keyboard focus alive across a switch, so you can keep typing.
    ///
    /// Off elsewhere: in the Notes pane a programmatic push is an external edit
    /// arriving from a sticky, and there is no second document involved.
    var resetsUndoOnExternalChange: Bool = false

    /// Optional handle for edits that must be undoable — see `NoteEditorProxy`.
    var proxy: NoteEditorProxy? = nil

    /// Where the selection is on screen, in the editor's own coordinate space,
    /// or `nil` when nothing is selected. Drives the sticky panel's floating
    /// formatting capsule; unset everywhere else, so nothing is computed for
    /// the surfaces that don't want it.
    var onSelectionChange: ((CGRect?) -> Void)? = nil

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
        if bottomInset > 0 {
            scroll.automaticallyAdjustsContentInsets = false
            scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: bottomInset, right: 0)
        }

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
        // `defaultParagraphStyle` covers text that carries none (freshly loaded
        // plain text); `typingAttributes` covers what the user types next. Both
        // are needed for the line height to hold everywhere.
        let paragraph = RichText.paragraphStyle(for: font)
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ]
        textView.textStorage?.setAttributedString(attributed)
        textView.onFocusChange = { [weak coordinator = context.coordinator] focused in
            coordinator?.focusChanged(focused)
        }

        scroll.documentView = textView
        context.coordinator.textView = textView
        proxy?.textView = textView

        // Scrolling moves the text under a selection without changing it, so
        // without this the floating capsule would stay put while the words it
        // points at slid away. Only armed when someone is listening.
        if onSelectionChange != nil {
            scroll.contentView.postsBoundsChangedNotifications = true
            context.coordinator.observeScroll(of: scroll)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? RichTextView else { return }
        context.coordinator.parent = self

        // Never overwrite an edit that hasn't been saved yet: the binding lags
        // the view by the owner's save debounce, so pushing it back in would
        // fight the cursor — or drop the keystrokes outright.
        guard !hasPendingEdit else { return }
        // **Compare against what we last pushed, not against the text view.**
        // `NSTextStorage` *fixes* attributes on assignment — it substitutes the
        // font on runs the base face can't render — so for a note containing
        // emoji or CJK the stored string never compares equal to the one we
        // handed it, and `textView.attributedString() != attributed` is
        // permanently true. Any view update then re-pushes the text, which
        // collapses the selection and (for stickies) wipes the undo stack.
        // Recording what we pushed makes the second push a no-op regardless of
        // what fixing did to it. The text-view comparison stays as a cheap
        // second gate for the first push of a value.
        guard attributed != context.coordinator.lastPushed,
              textView.attributedString() != attributed else { return }
        // Flagged so the resulting text-storage change can't be mistaken for
        // the user typing (which would re-arm `hasPendingEdit` forever).
        context.coordinator.isApplyingProgrammaticChange = true
        textView.textStorage?.setAttributedString(attributed)
        context.coordinator.isApplyingProgrammaticChange = false
        context.coordinator.lastPushed = attributed
        if resetsUndoOnExternalChange { textView.undoManager?.removeAllActions() }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        weak var textView: RichTextView?

        init(_ parent: RichTextEditor) { self.parent = parent }

        /// Set while `updateNSView` is pushing store content in, so that write
        /// isn't counted as the user typing.
        var isApplyingProgrammaticChange = false

        /// The value `updateNSView` last pushed into the text view. Guards
        /// against re-pushing the same content — see the comment there for why
        /// comparing against the text view alone is not enough.
        var lastPushed: NSAttributedString?

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.attributed = textView.attributedString()
            guard !isApplyingProgrammaticChange else { return }
            parent.hasPendingEdit = true
            parent.onUserEdit?()
        }

        /// Report where a non-empty selection sits, so a floating control can
        /// be positioned over it. Fires for programmatic selection changes too,
        /// which is what clears the rect when a tab switch swaps the content.
        func textViewDidChangeSelection(_ notification: Notification) {
            guard parent.onSelectionChange != nil else { return }
            guard let textView = notification.object as? NSTextView else { return }
            reportSelection(in: textView)
        }

        /// Publish where the selection sits, or `nil` when there isn't one.
        ///
        /// **Only when it actually moved.** The callback drives `@Published`
        /// state, so re-publishing an unchanged value re-runs the owner's body
        /// for nothing — and this fires on every keystroke and every mouse-move
        /// of a drag-select.
        func reportSelection(in textView: NSTextView) {
            guard parent.onSelectionChange != nil else { return }
            let range = textView.selectedRange()
            guard range.length > 0, let layout = textView.layoutManager,
                  let container = textView.textContainer else {
                if lastReportedRect != nil {
                    lastReportedRect = nil
                    parent.onSelectionChange?(nil)
                }
                return
            }
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            // Into the enclosing scroll view's space, so the rect accounts for
            // how far the note is scrolled.
            if let scroll = textView.enclosingScrollView {
                rect = textView.convert(rect, to: scroll)
            }
            guard rect != lastReportedRect else { return }
            lastReportedRect = rect
            parent.onSelectionChange?(rect)
        }

        /// What was last handed to `onSelectionChange`, so an unchanged value
        /// isn't republished.
        private var lastReportedRect: CGRect?

        private var scrollObserver: NSObjectProtocol?

        /// Re-report the selection as the note scrolls.
        func observeScroll(of scroll: NSScrollView) {
            guard scrollObserver == nil else { return }
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let textView = self.textView else { return }
                    self.reportSelection(in: textView)
                }
            }
        }

        deinit {
            if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        }

        /// Focus gained/lost, from `RichTextView`'s first-responder overrides.
        /// Deliberately **not** used to decide whether to save or whether a
        /// store push is safe — `hasPendingEdit` answers both, and focus is
        /// unreliable on a nonactivating panel.
        func focusChanged(_ focused: Bool) {
            // Push the final value through before the owner flushes its save.
            if !focused, let textView { parent.attributed = textView.attributedString() }
            parent.onFocusChange?(focused)
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
