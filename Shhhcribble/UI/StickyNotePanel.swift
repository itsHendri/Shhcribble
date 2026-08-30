import AppKit
import SwiftUI
import Combine
import os

/// A single floating sticky panel holding **every stuck note as a tab**
/// (borrowed from Wispr's Scratchpad, 2026-08-10), in Trace's chrome discipline
/// (2026-08-28): the tab strip is the only chrome, the text runs to the edges,
/// and formatting is summoned over a selection rather than sitting on screen.
///
/// **Tabs are presentation; stick/unstick is still the only lifecycle.** That
/// is what makes the window's behaviour fall out for free: closing a *tab*
/// unsticks that note, and the panel disappears on its own once the last tab
/// goes — so there is deliberately **no window close button** and no new
/// destructive semantics to design. It also means nothing about the Notes pane
/// or the schema had to change.
///
/// Same panel species as `CallOfferPanel` (`.borderless + .nonactivatingPanel`,
/// `canBecomeKey`, `FirstMouseHostingView`) so the first click lands on its
/// controls without stealing focus from the frontmost app. Typing works in a
/// nonactivating key panel, but ⌘V/⌘Z route through the main menu of the
/// *active* app — so the moment the text editor gains focus we activate
/// Shhhcribble (the installed Edit menu then carries the shortcuts; this is
/// also how Apple Stickies behaves).
///
/// **The shadow is the window's, not SwiftUI's.** A SwiftUI `.shadow` needs
/// transparent panel margins to draw into and clips as soon as the blur
/// exceeds them (the CallOfferPanel lesson). With `hasShadow` on, AppKit draws
/// the shadow around the card's opaque rounded shape and it can never clip.
///
/// **Two sizes, not free resize** (2026-08-28). `.resizable` and the per-pixel
/// persisted size are gone; one toggle in the tab strip swaps compact ⇄ expanded
/// via `StickyPanelGeometry`, holding the top-left corner so the tab you are
/// reading doesn't move.
///
/// **The frame lives in UserDefaults, not the note row.** With one panel for
/// all stickies the per-note `pinX/pinY/pinW/pinH` columns no longer describe
/// anything, so they stop being written — but they are **left in the schema and
/// still read once**, to place the panel where the user's most recent sticky
/// used to sit on first launch after upgrading. Same rollback discipline as the
/// legacy pref keys; no migration, no schema bump.
@MainActor
final class StickyNotePanel: NSPanel {

    private let model = StickyTabsModel()

    /// Debounce slot for persisting the dragged/resized frame.
    private var framePersist: DispatchWorkItem?
    private var frameObservers: [NSObjectProtocol] = []

    /// Callbacks into the manager (which owns the store writes).
    var onTextCommit: ((UUID, NSAttributedString) -> Void)?
    var onUnstick: ((UUID) -> Void)?
    var onFrameChange: ((CGRect) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var onNewTab: (() -> Void)?
    var onActiveTabChange: ((UUID?) -> Void)?
    var onModeChange: ((StickyPanelMode) -> Void)?

    /// Toggle dictation into the active sticky. A var (not an init parameter)
    /// because it's only ever *invoked*, through a closure captured at init that
    /// reads it at call time — the same shape as every other callback here.
    /// The observable `dictation` state, by contrast, has to arrive at init:
    /// SwiftUI has to be given the object to observe when the view is built.
    var onToggleDictation: ((@escaping (String) -> Void) -> Void)?

    private static let log = Logger(subsystem: "com.shhhcribble.app", category: "sticky")

    /// Bigger than the pre-tabs default (260×200) because a tab bar needs
    /// horizontal room before it starts scrolling.
    static let defaultSize = NSSize(width: StickyPanelMode.compact.size.width,
                                    height: StickyPanelMode.compact.size.height)

    /// Which of the two sizes the panel is at. Changing it re-frames the window.
    private(set) var mode: StickyPanelMode = .compact

    init(dictation: NoteDictationState? = nil) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )

        level              = .floating
        backgroundColor    = .clear
        isOpaque           = false
        // Window-drawn shadow around the card's opaque shape — see the class
        // doc for why this beats a SwiftUI .shadow here.
        hasShadow          = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // The tab bar's padding is the drag surface (the text editor claims
        // drags in its own area); background-drag makes the whole card
        // grabbable wherever SwiftUI doesn't swallow the mouse.
        isMovableByWindowBackground = true
        // The manager holds the only strong reference; NSPanel defaults
        // releasedWhenClosed to true, which under ARC risks an over-release if
        // anything ever close()s instead of orderOut()s.
        isReleasedWhenClosed = false

        model.onCommit = { [weak self] id, text in self?.onTextCommit?(id, text) }

        let content = FirstMouseHostingView(rootView: StickyView(
            model: model,
            onUnstick:   { [weak self] id in self?.onUnstick?(id) },
            onDelete:    { [weak self] id in self?.onDelete?(id) },
            onNewTab:    { [weak self] in self?.onNewTab?() },
            onActivate:  { [weak self] id in self?.onActiveTabChange?(id) },
            onToggleSize:{ [weak self] in self?.toggleMode() },
            dictation:   dictation ?? NoteDictationState(),
            onDictate:   { [weak self] sink in self?.onToggleDictation?(sink) }
        ))
        content.frame = NSRect(origin: .zero, size: Self.defaultSize)
        // Track the panel as it resizes so the SwiftUI card always fills it.
        content.autoresizingMask = [.width, .height]
        contentView = content

        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            frameObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: self, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.invalidateShadow()   // shadow shape follows the resize
                    self?.schedulePersistFrame()
                }
            })
        }
    }

    deinit {
        for observer in frameObservers { NotificationCenter.default.removeObserver(observer) }
        framePersist?.cancel()
    }

    override var canBecomeKey: Bool { true }

    /// Refresh the tab list from the store, and the active tab's content with
    /// it. Content is only pushed in while that editor has no unsaved edit: the
    /// store lags live typing by the save debounce, so overwriting mid-edit
    /// would eat keystrokes. See `StickyTabsModel.apply(items:)`.
    func update(items: [StickyItem], preferredActive: UUID?) {
        model.apply(items: items, preferredActive: preferredActive)
    }

    /// The tab currently on screen, so the manager can persist it — including
    /// when `apply(items:)` picked a new one after the active tab was unstuck
    /// from the Notes pane, which no user-initiated callback would cover.
    var activeTabID: UUID? { model.activeID }

    /// Commit any unsaved edit. Called before the panel is torn down, because
    /// `onDisappear` is not a reliable last word when a window is ordered out
    /// and released.
    func flushPendingEdit() { model.flushSave() }

    /// Show at the saved origin (clamped to a visible screen) in `mode`, or
    /// centred-ish on the main screen. The *size* comes from the mode now, never
    /// from what was saved.
    func present(at origin: CGPoint?, mode restoredMode: StickyPanelMode) {
        mode = restoredMode
        model.mode = restoredMode
        let size = mode.size

        var point: CGPoint
        if let origin {
            point = origin
        } else if let screen = NSScreen.main ?? NSScreen.screens.first {
            let f = screen.visibleFrame
            point = CGPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2)
        } else {
            point = .zero
        }
        // Clamp so a panel saved on a disconnected display comes back on-screen.
        if let screen = screenContaining(point) ?? NSScreen.main ?? NSScreen.screens.first {
            point = StickyPanelGeometry.clamp(origin: point, size: size,
                                              in: screen.visibleFrame)
        }
        setFrame(NSRect(origin: point, size: size), display: true)
        orderFront(nil)
    }

    /// Swap compact ⇄ expanded, holding the top-left corner. The resulting
    /// `didResizeNotification` persists the new origin through the existing
    /// debounce, so there is no separate save path.
    func toggleMode() {
        let screen = screenContaining(frame.origin) ?? self.screen
            ?? NSScreen.main ?? NSScreen.screens.first
        mode = mode.toggled
        model.mode = mode
        let visible = screen?.visibleFrame ?? frame
        let next = StickyPanelGeometry.frame(frame, at: mode, in: visible)
        setFrame(next, display: true, animate: false)
        onModeChange?(mode)
    }

    /// Bring a tab to the front and focus its editor — the quick-add and
    /// + button path. Goes through `selectTab`, so an unsaved edit in the tab
    /// being left is committed first.
    func focusTab(_ id: UUID) {
        model.selectTab(id)
        makeKey()
        model.focusRequest += 1
    }

    private func screenContaining(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.visibleFrame.contains(point) }
    }

    private func schedulePersistFrame() {
        framePersist?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onFrameChange?(self.frame)
        }
        framePersist = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }
}

// MARK: - Manager

/// Owns the single sticky panel. Observes the store and keeps the panel's tab
/// list in step with `stuckNotesInTabOrder`; the panel appears with the first
/// stuck note and is torn down with the last. All store writes funnel through
/// here so the panel stays a dumb view.
@MainActor
final class StickyPanelManager {

    /// Window state, not a user setting — see the pref table in CLAUDE.md.
    private enum Key {
        static let frame = "stickyPanelFrame"
        static let activeNote = "stickyActiveNoteID"
        static let mode = "stickyPanelMode"
    }

    private let store: TranscriptStore
    private let defaults: UserDefaults
    private var panel: StickyNotePanel?
    private var cancellables = Set<AnyCancellable>()

    /// The id of a note whose tab should be focused as soon as it appears
    /// (the menu-bar "New Note" and the panel's + button).
    private var pendingEditID: UUID?

    /// Dictation into the active sticky. Set by `AppDelegate` after
    /// construction (the manager is built before the delegate has finished
    /// wiring itself, and holding the delegate here would be a retain cycle).
    /// Nil leaves the microphone button out entirely.
    var dictation: NoteDictationState?
    var onToggleDictation: ((@escaping (String) -> Void) -> Void)?

    init(store: TranscriptStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        // `@Published` emits on willSet — hop a tick so `store.notes` is
        // current when we diff, rather than the pre-mutation array.
        store.$notes
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.sync() }
            }
            .store(in: &cancellables)
        // Documents can be on screen too (2026-08-30), so the panel has to
        // follow the transcripts array as well — without this, pinning a
        // document from the shelf would write `stuck` and nothing would appear.
        store.$transcripts
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.sync() }
            }
            .store(in: &cancellables)
        sync()
    }

    /// Create a fresh, empty stuck note and focus its tab. The cursor position is
    /// only used when there is no panel on screen yet; otherwise this just adds a
    /// tab to the panel you can already see, and moving it under the mouse would
    /// be startling.
    func createStickyAtCursor() {
        var note = Note(text: "")
        note.stuck = true
        if panel == nil && defaults.string(forKey: Key.frame) == nil {
            var origin = NSEvent.mouseLocation
            origin.x -= StickyNotePanel.defaultSize.width / 2
            origin.y -= StickyNotePanel.defaultSize.height + 24   // below the cursor/menu bar
            note.pinX = origin.x
            note.pinY = origin.y
        }
        pendingEditID = note.id
        defaults.set(note.id.uuidString, forKey: Key.activeNote)
        store.addNote(note)   // → sync() presents the panel and begins editing
    }

    private func sync() {
        let stuck = store.stuckItemsInTabOrder

        guard !stuck.isEmpty else {
            // Unsticking the last note from the Notes pane tears the panel down
            // from the outside, so commit before it goes — `onDisappear` does
            // not reliably fire for a window being ordered out and released.
            panel?.flushPendingEdit()
            panel?.orderOut(nil)
            panel = nil
            return
        }

        let panel = panel ?? makePanel()
        self.panel = panel
        panel.update(items: stuck, preferredActive: savedActiveID(among: stuck))
        // Covers the path no user-initiated callback does: the active tab was
        // unstuck elsewhere and `apply` fell to a neighbour.
        if let id = panel.activeTabID { defaults.set(id.uuidString, forKey: Key.activeNote) }

        // A freshly-created note must become the visible tab: `apply` leaves the
        // current tab alone when it survives, so without this the + button would
        // add a tab off to the side and focus the wrong editor.
        if let pendingEditID, stuck.contains(where: { $0.id == pendingEditID }) {
            self.pendingEditID = nil
            panel.focusTab(pendingEditID)
            defaults.set(pendingEditID.uuidString, forKey: Key.activeNote)
        }
    }

    /// The tab to open on, when the panel has just been created or its active
    /// tab has gone. Nil lets the panel keep its own choice.
    private func savedActiveID(among stuck: [StickyItem]) -> UUID? {
        guard let raw = defaults.string(forKey: Key.activeNote),
              let id = UUID(uuidString: raw),
              stuck.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private func makePanel() -> StickyNotePanel {
        let panel = StickyNotePanel(dictation: dictation)
        panel.onTextCommit = { [weak self] id, attributed in
            guard let self, var current = self.store.notes.first(where: { $0.id == id }) else { return }
            let plain = attributed.string
            let rich = RichText.data(from: attributed, font: StickyTabsModel.font)
            guard plain != current.text || rich != current.richText else { return }
            current.text = plain
            current.richText = rich
            self.store.updateNote(current)
        }
        // Closing a tab takes that item off the screen, whichever kind it is.
        // Dispatching on where the id is actually found (rather than passing the
        // kind through the panel) keeps the panel's callback a bare id, and a
        // deleted row simply matches neither and does nothing.
        panel.onUnstick = { [weak self] id in
            guard let self else { return }
            if self.store.notes.contains(where: { $0.id == id }) {
                self.store.setNoteStuck(id: id, stuck: false)
            } else {
                self.store.setTranscriptStuck(id: id, stuck: false)
            }
        }
        panel.onFrameChange = { [weak self] frame in
            self?.defaults.set(NSStringFromRect(frame), forKey: Key.frame)
        }
        panel.onDelete = { [weak self] id in
            // Only reachable through the confirmed "Discard" path for an empty
            // note — a tab with content is unstuck instead, keeping the note in
            // the Notes tab.
            self?.store.deleteNote(id: id)
        }
        panel.onNewTab = { [weak self] in
            self?.createStickyAtCursor()
        }
        panel.onActiveTabChange = { [weak self] id in
            guard let self else { return }
            if let id { self.defaults.set(id.uuidString, forKey: Key.activeNote) }
            else { self.defaults.removeObject(forKey: Key.activeNote) }
        }
        panel.onModeChange = { [weak self] mode in
            self?.defaults.set(mode.rawValue, forKey: Key.mode)
        }
        panel.onToggleDictation = { [weak self] sink in self?.onToggleDictation?(sink) }
        let mode = restoredMode()
        panel.present(at: restoredOrigin(mode: mode), mode: mode)
        return panel
    }

    private func restoredMode() -> StickyPanelMode {
        guard let raw = defaults.string(forKey: Key.mode),
              let mode = StickyPanelMode(rawValue: raw) else { return .compact }
        return mode
    }

    /// Where to put a freshly-created panel: the saved panel origin, else — for
    /// someone upgrading from one-panel-per-note — the origin of their most
    /// recently touched sticky, so the panel appears roughly where they left
    /// their stickies rather than jumping to the middle of the screen.
    ///
    /// Only the **origin** is restored. The saved frame's size (and the legacy
    /// `pinW`/`pinH`) described a freely-resized panel, which no longer exists;
    /// the size now comes from the mode. Both are still written/read for
    /// rollback, same discipline as the retired columns.
    private func restoredOrigin(mode: StickyPanelMode) -> CGPoint? {
        // The saved values are bottom-left origins for a panel of the *old*
        // size, so reusing them directly would hold the bottom edge and drop the
        // panel down the screen by the height difference — up to 380 pt on the
        // first launch after upgrading from a freely-resized sticky. Everything
        // else in this feature anchors top-left; so does this.
        func topAnchored(_ origin: CGPoint, _ oldHeight: CGFloat) -> CGPoint {
            CGPoint(x: origin.x, y: origin.y + oldHeight - mode.size.height)
        }
        if let raw = defaults.string(forKey: Key.frame) {
            let frame = NSRectFromString(raw)
            if frame.width > 0 && frame.height > 0 {
                return topAnchored(frame.origin, frame.height)
            }
        }
        guard let legacy = store.stuckNotes.first,
              let x = legacy.pinX, let y = legacy.pinY else { return nil }
        return topAnchored(CGPoint(x: x, y: y), legacy.pinH ?? mode.size.height)
    }
}

// MARK: - View model

/// The panel's tab list plus the active tab's live editor contents.
///
/// **The active tab's "what did we last read or write" pair lives here, not in
/// the panel**, because it has to be reset in lockstep with the active tab —
/// keeping it a level up made it trivially easy to compare a new tab's content
/// against the previous tab's bookkeeping.
@MainActor
final class StickyTabsModel: ObservableObject {
    static let font = RichText.baseFont

    /// Tab order — stable creation order, see `stuckItemsInTabOrder`.
    ///
    /// Holds **both kinds** since 2026-08-30: a note tab is editable, a document
    /// tab is a read-only card showing the document's summary. Everything below
    /// about saving, debouncing and pending edits applies only to notes — a
    /// document tab has nothing to commit, which is why `activeNote` (not
    /// `activeItem`) gates all of it.
    @Published private(set) var items: [StickyItem] = []

    /// The editable subset, for the paths that only make sense for notes.
    var notes: [Note] { items.compactMap { if case .note(let n) = $0 { return n } else { return nil } } }
    @Published private(set) var activeID: UUID?
    @Published var attributed = NSAttributedString(string: "")
    /// An edit lives here that the store doesn't have yet — blocks store→view
    /// pushes. See `RichTextEditor.hasPendingEdit` for why this replaced focus.
    @Published var hasPendingEdit: Bool = false
    /// Bumped to request editor focus (quick-add).
    @Published var focusRequest: Int = 0
    /// Closing a tab always confirms; this drives the in-card overlay (an
    /// NSAlert/sheet looks absurd on a small floating card).
    @Published var showingCloseConfirm: Bool = false
    /// Which of the two sizes the panel is at — the tab strip's toggle glyph
    /// reads this so it always names the size you'd get by clicking.
    @Published var mode: StickyPanelMode = .compact
    /// Where the selection sits, for the floating formatting capsule. Nil when
    /// nothing is selected, which is also what hides the capsule.
    @Published var selectionRect: CGRect?

    /// Reaches the live text view, so the capsule's buttons run the same
    /// styling actions ⌘B/⌘I/⌘U do.
    let editor = NoteEditorProxy()

    /// Set by the panel — this is how a write reaches the store.
    var onCommit: ((UUID, NSAttributedString) -> Void)?

    /// The stored values the *active* tab last read from (or wrote to) the
    /// store. Compared against the stored fields rather than the live
    /// `NSAttributedString`, because an attributed string round-tripped through
    /// archiving is not reliably `==` to its original.
    private var lastAppliedText: String?
    private var lastAppliedRich: Data?

    /// The 700 ms save debounce. **It lives here, not in the view**, because
    /// every path that changes tabs has to flush first, and several of them
    /// (the + button, the menu-bar quick-add) originate outside the view. When
    /// the view owned it, those paths silently skipped the flush.
    private var saveTask: Task<Void, Never>?

    var activeItem: StickyItem? { items.first { $0.id == activeID } }

    /// The active tab **if it is an editable note**. Nil for a document tab,
    /// which is what keeps every save path a no-op there.
    var activeNote: Note? {
        guard case .note(let n) = activeItem else { return nil }
        return n
    }

    var isActiveEmpty: Bool {
        attributed.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A user edit landed — (re)arm the debounce.
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            flushSave()
        }
    }

    /// Commit the active tab's contents.
    ///
    /// **Guarded on `hasPendingEdit`, and that guard matters more than it did
    /// with one panel per note.** Flushing now happens on every tab switch, and
    /// decoding a stored note then re-encoding it is not guaranteed to
    /// reproduce the original bytes — so an unconditional flush would write a
    /// cosmetically-identical note back and bump its `modifiedAt`. That is not
    /// harmless: `modifiedAt` orders the Notes list, including its "On your
    /// screen" group, so merely clicking between tabs would reshuffle it.
    func flushSave() {
        saveTask?.cancel()
        guard let id = activeID, hasPendingEdit else { return }
        hasPendingEdit = false
        let plain = attributed.string
        let rich = RichText.data(from: attributed, font: Self.font)
        // Record what we're about to write so the store's echo back through
        // `apply(items:)` isn't mistaken for an external edit.
        guard plain != lastAppliedText || rich != lastAppliedRich else { return }
        lastAppliedText = plain
        lastAppliedRich = rich
        onCommit?(id, attributed)
    }

    /// Throw away an unsaved edit — the discard-an-empty-note path, where the
    /// row is about to be deleted and writing to it first would be pointless.
    func discardPendingEdit() {
        saveTask?.cancel()
        hasPendingEdit = false
    }

    /// Switch tabs, committing the outgoing tab first.
    ///
    /// **This flush is the single most likely way for the feature to lose
    /// text.** One editor serves every tab, so without committing here
    /// everything typed since the last 700 ms tick is overwritten the moment
    /// the new tab's content is loaded. It is the same failure adversarial
    /// review already caught twice in this app (pin/stick not flushing, and the
    /// 2026-07-24 two-editor sync gap), which is why it is pinned by tests.
    func selectTab(_ id: UUID) {
        guard id != activeID else { return }
        flushSave()
        activate(id)
    }

    /// Load a tab's stored content into the editor.
    ///
    /// **Callers must have flushed the outgoing tab's pending edit first** —
    /// this clears `hasPendingEdit`, and anything still in the debounce at that
    /// point is lost. Prefer `selectTab`, which flushes for you.
    func activate(_ id: UUID?) {
        // A debounce still armed here belongs to the outgoing tab; `flushSave`
        // is a no-op once `hasPendingEdit` clears below, so drop it outright.
        saveTask?.cancel()
        // A confirmation left open belongs to the tab being left. Carrying it
        // over would leave "Close this sticky?" hanging over a *different*
        // note, and pressing Unstick would then unstick the wrong one.
        showingCloseConfirm = false
        activeID = id
        guard let note = activeNote else {
            attributed = NSAttributedString(string: "")
            lastAppliedText = nil
            lastAppliedRich = nil
            hasPendingEdit = false
            return
        }
        attributed = RichText.attributed(from: note.richText, plain: note.text, font: Self.font)
        lastAppliedText = note.text
        lastAppliedRich = note.richText
        hasPendingEdit = false
    }

    /// Refresh from the store.
    ///
    /// Three cases: the active tab survived (push in any *external* edit,
    /// unless this editor has one of its own pending); the active tab is gone
    /// (fall to the tab that slid into its place, browser-style); or there is
    /// no active tab yet (take the caller's preference, else the first).
    func apply(items incoming: [StickyItem], preferredActive: UUID? = nil) {
        let previousIndex = activeID.flatMap { id in items.firstIndex { $0.id == id } }
        items = incoming

        if let activeID, incoming.contains(where: { $0.id == activeID }) {
            // A document tab has no editor to push into; its card reads straight
            // from the item, so surviving the refresh is all it needs.
            guard !hasPendingEdit, let note = activeNote,
                  note.text != lastAppliedText || note.richText != lastAppliedRich else { return }
            lastAppliedText = note.text
            lastAppliedRich = note.richText
            attributed = RichText.attributed(from: note.richText, plain: note.text, font: Self.font)
            return
        }

        if activeID == nil, let preferredActive,
           incoming.contains(where: { $0.id == preferredActive }) {
            activate(preferredActive)
            return
        }
        // The active tab is going away — commit its unsaved edit before we load
        // another note over the top of it. This is the *other* half of the tab
        // switch flush: here the switch is forced on us from outside (the note
        // was unstuck or deleted from the Notes pane), so nothing has been
        // through `selectTab`. Without it, unsticking the note you are typing in
        // silently discards the last words. Harmless when the row was deleted —
        // the commit finds no row and does nothing.
        flushSave()
        // The tab that took its index, or the new last one if it was rightmost.
        let landing = previousIndex.map { min($0, incoming.count - 1) } ?? 0
        activate(incoming.indices.contains(landing) ? incoming[landing].id : incoming.first?.id)
    }

    /// Tab label: the first non-empty line, short. The **active** tab reads from
    /// the live editor rather than the stored row, so a title you are typing
    /// appears immediately instead of lagging by the save debounce.
    func label(for item: StickyItem) -> String {
        guard case .note(let note) = item else { return item.tabTitle }
        let source = (note.id == activeID) ? attributed.string : note.text
        let firstLine = source
            .split(whereSeparator: \.isNewline)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !firstLine.isEmpty else { return "New note" }
        return firstLine.count <= 18 ? firstLine : String(firstLine.prefix(17)) + "…"
    }
}

// MARK: - View

private struct StickyView: View {
    @ObservedObject var model: StickyTabsModel
    let onUnstick: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onNewTab: () -> Void
    let onActivate: (UUID?) -> Void
    let onToggleSize: () -> Void
    /// Live "am I recording" state for the microphone glyph. `AppDelegate`
    /// always supplies the real one; the default-constructed fallback exists
    /// only so the panel is constructible in isolation (tests, previews).
    @ObservedObject var dictation: NoteDictationState
    let onDictate: (@escaping (String) -> Void) -> Void

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            if let item = model.activeItem, item.isDocument {
                documentCard(item)
            } else {
                noteEditor
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.radiusCard, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.radiusCard, style: .continuous)
                .strokeBorder(.white.opacity(DesignSystem.strokeSubtle), lineWidth: 1)
        )
        .overlay { closeConfirmOverlay }
        // A swapped-in tab keeps the old tab's selection rect for an instant
        // otherwise, so the capsule flashes over the wrong note's text.
        .onChange(of: model.activeID) { _, _ in model.selectionRect = nil }
        .onDisappear { model.flushSave() }
    }

    /// A pinned document: **read-only, and showing its summary** rather than the
    /// transcript (ruled with Hendri 2026-08-30 — a 40-minute transcript is
    /// unreadable in a small card, and the summary is the part worth having in
    /// front of you). The header says which it is, so the fallback to the raw
    /// transcript never reads as a summary that came out wrong.
    ///
    /// No editor, no save path, no capsule: `activeNote` is nil for this tab, so
    /// every commit path upstream is already a no-op.
    private func documentCard(_ item: StickyItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: item.isShowingSummary ? "sparkles" : "text.alignleft")
                Text(item.isShowingSummary ? "Summary" : "Transcript")
                Spacer(minLength: 0)
            }
            .font(.system(size: DesignSystem.ChromeText.micro))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 9)
            .padding(.bottom, 4)

            ScrollView {
                Text(item.documentBody ?? "")
                    .font(.system(size: DesignSystem.ChromeText.body))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 9)
            }
        }
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var noteEditor: some View {
        RichTextEditor(
                attributed: $model.attributed,
                hasPendingEdit: $model.hasPendingEdit,
                font: StickyTabsModel.font,
                // Nearly to the edge, Trace-style — the words are the interface.
                // Not zero: a rounded card clips descenders into its corner
                // radius, and the caret needs somewhere to sit on line one.
                insets: NSSize(width: 5, height: 3),
                onFocusChange: { focused in
                    if focused {
                        // ⌘V/⌘Z/⌘B route through the active app's main menu; as
                        // an LSUIElement app ours only participates once
                        // activated (the Apple Stickies behaviour).
                        NSApp.activate(ignoringOtherApps: true)
                    } else {
                        model.flushSave()
                    }
                },
                onUserEdit: { model.scheduleSave() },
                // One editor is deliberately reused across tabs, so the undo
                // stack has to be dropped when a tab's content is swapped in —
                // otherwise ⌘Z would paste the previous note over this one.
                // Reusing it (rather than rebuilding per tab) is what keeps the
                // caret alive across a switch, so typing continues uninterrupted.
                resetsUndoOnExternalChange: true,
                proxy: model.editor,
                onSelectionChange: { rect in model.selectionRect = rect }
            )
        .padding(.bottom, 6)
        .overlay(alignment: .topLeading) { formattingCapsule }
        .overlay(alignment: .bottomTrailing) { dictateButton }
    }

    /// Dictate into the active sticky.
    ///
    /// **Permanent, and deliberately not in the formatting capsule**: that
    /// capsule only exists while there is a selection, and dictation has nothing
    /// to do with one — you reach for it with an empty note and no caret. It is
    /// the one control here that has to be visible when nothing is happening.
    private var dictateButton: some View {
        Button {
            // Commit first: dictation appends through the proxy, and a pending
            // edit not yet in the store would be re-pushed over the result.
            model.flushSave()
            onDictate { text in appendDictated(text) }
        } label: {
            Image(systemName: dictation.isActive ? "mic.fill" : "mic")
                .font(.system(size: DesignSystem.ChromeText.control))
                .foregroundStyle(dictation.isActive ? Color.red : Color.secondary)
                .frame(width: 24, height: 24)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.quaternary, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .padding(.trailing, 8)
        .padding(.bottom, 8)
        .help(dictation.isActive ? "Stop dictating" : "Dictate into this note")
        .accessibilityLabel(dictation.isActive ? "Stop dictating" : "Dictate into this note")
    }

    /// Append dictated words to the active sticky, as one undoable edit.
    ///
    /// Mirrors `NoteDetail.appendDictated`: through the proxy so ⌘Z takes it
    /// back out and the save debounce is armed by the editor's own change
    /// callback, and computed from the text as it is *now* — the user may have
    /// carried on typing while the words were being transcribed.
    private func appendDictated(_ text: String) {
        let font = StickyTabsModel.font
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: RichText.paragraphStyle(for: font),
        ]
        model.editor.append(NSAttributedString(string: text, attributes: attributes),
                            attributes: attributes)
    }

    /// Tabs, then the new-tab button. The row's padding doubles as the drag
    /// surface — `isMovableByWindowBackground` moves the panel from any
    /// background the SwiftUI hierarchy doesn't claim.
    private var tabBar: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.items) { note in
                        tab(for: note)
                    }
                }
            }
            Button(action: onNewTab) {
                Image(systemName: "plus")
                    .font(.system(size: DesignSystem.ChromeText.micro, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("New note")
            .accessibilityLabel("New note")

            // Trailing corner, away from the tabs: it acts on the window, not
            // on any one note. The glyph names the size you'd get by clicking.
            Button(action: onToggleSize) {
                Image(systemName: model.mode.toggleIcon)
                    .font(.system(size: DesignSystem.ChromeText.micro, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.mode.toggleHelp)
            .accessibilityLabel(model.mode.toggleHelp)
        }
        .padding(.horizontal, 8)
        .padding(.top, 7)
        .padding(.bottom, 5)
        .contentShape(Rectangle())
    }

    /// Formatting, **summoned over the selection** rather than resident (Trace's
    /// discipline): a small card has no room for a permanent toolbar, and a
    /// control you only need while styling shouldn't be on screen while you
    /// read.
    ///
    /// ⌘B/⌘I/⌘U and the right-click menu are untouched and remain the primary
    /// routes — this is a third way in, for the times your hands are on the
    /// mouse. All three call the same actions through `NoteEditorProxy`.
    /// Half the capsule's intrinsic width: 4 buttons at 22, 3 gaps at 2, and
    /// 8 of padding each side = 110.
    private static let capsuleWidth: CGFloat = 110

    @ViewBuilder
    private var formattingCapsule: some View {
        if let rect = model.selectionRect {
            // Needs the card's width to keep the capsule inside it — clamping
            // only the left edge let it run off the right on any selection in
            // the last tenth of a line, where the panel (borderless, exactly the
            // card) clipped the Highlight button out of reach.
            GeometryReader { geo in
                HStack(spacing: 2) {
                    // The step leads the capsule: "make this a heading" is the
                    // thing you reach for most, and it's the one action that had
                    // no discoverable route at all — ⌘1–⌘5 or a right-click.
                    stepMenu
                    Divider().frame(height: 12)
                    styleButton("bold", "Bold", .bold)
                    styleButton("italic", "Italic", .italic)
                    styleButton("underline", "Underline", .underline)
                    styleButton("highlighter", "Highlight", .highlight)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
                .shadow(color: .black.opacity(DesignSystem.shadowSoft), radius: 6, y: 2)
                .offset(x: capsuleX(for: rect, in: geo.size.width),
                        y: capsuleY(for: rect))
            }
            .allowsHitTesting(true)
            .transition(.opacity)
        }
    }

    /// Centred on the selection, then held inside the card.
    private func capsuleX(for rect: CGRect, in cardWidth: CGFloat) -> CGFloat {
        let centred = rect.midX - Self.capsuleWidth / 2
        let rightmost = max(cardWidth - Self.capsuleWidth - 6, 6)
        return min(max(centred, 6), rightmost)
    }

    /// Above the selection, so it doesn't cover what you just picked — and
    /// **below** it when there's no room above, rather than sitting on top of
    /// the first line.
    private func capsuleY(for rect: CGRect) -> CGFloat {
        let above = rect.minY - 34
        return above >= 4 ? above : rect.maxY + 6
    }

    /// The paragraph ramp, as a menu inside the capsule.
    ///
    /// A menu rather than five buttons: the capsule floats over a small card and
    /// five more glyphs would leave no room for the character formatting beside
    /// it. The current step is ticked, so the menu also answers "what is this
    /// line?" — the same reason the right-click submenu ticks it.
    private var stepMenu: some View {
        Menu {
            ForEach(NoteTextStyle.allCases) { step in
                Button {
                    model.editor.applyTextStyle(step)
                } label: {
                    if model.editor.currentTextStyle == step {
                        Label(step.label, systemImage: "checkmark")
                    } else {
                        Text(step.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(model.editor.currentTextStyle?.label ?? "Body")
                Image(systemName: "chevron.down").font(.system(size: 7))
            }
            .font(.system(size: DesignSystem.ChromeText.secondary))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Text style")
    }

    private func styleButton(_ icon: String, _ label: String,
                             _ style: NoteEditorProxy.Style) -> some View {
        Button {
            model.editor.apply(style)
        } label: {
            Image(systemName: icon)
                .font(.system(size: DesignSystem.ChromeText.secondary, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    /// One tab. The close control sits on the **active** tab only: a row of ✕s
    /// across a small card is noise, and putting it here keeps the confirmation
    /// unambiguous about which note it is about. Closing an inactive tab is
    /// therefore select-then-close, which is fine — unsticking in bulk belongs
    /// to the Notes pane.
    private func tab(for note: StickyItem) -> some View {
        let isActive = note.id == model.activeID
        return HStack(spacing: 3) {
            Text(model.label(for: note))
                .font(.system(size: DesignSystem.ChromeText.secondary))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
            if isActive {
                Button {
                    withAnimation(DesignSystem.motion(.easeOut(duration: 0.15))) {
                        model.showingCloseConfirm = true
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: DesignSystem.ChromeText.micro - 1, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(model.isActiveEmpty ? "Discard" : "Unstick (keeps the note)")
                .accessibilityLabel(model.isActiveEmpty ? "Discard note" : "Unstick note")
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, isActive ? 4 : 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.radiusControl, style: .continuous)
                .fill(.white.opacity(isActive ? DesignSystem.fillActive : 0))
        )
        .contentShape(Rectangle())
        .onTapGesture { selectTab(note.id) }
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    /// Switch tabs. `model.selectTab` commits the outgoing tab first — see its
    /// doc for why that flush is the feature's main data-loss risk.
    private func selectTab(_ id: UUID) {
        guard id != model.activeID else { return }
        model.selectTab(id)
        onActivate(id)
    }

    /// In-card confirmation for closing a tab, per the universal
    /// destructive-confirm convention. Empty note → Discard (deletes); note with
    /// content → Unstick (keeps it in the Notes tab).
    @ViewBuilder
    private var closeConfirmOverlay: some View {
        if model.showingCloseConfirm {
            VStack(spacing: 10) {
                Text(model.isActiveEmpty ? "Discard this empty note?" : "Close this sticky?")
                    .font(.system(size: 12, weight: .semibold))
                if !model.isActiveEmpty {
                    Text("The note stays in your Notes list.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                HStack(spacing: 8) {
                    Button("Cancel") {
                        withAnimation(DesignSystem.motion(.easeOut(duration: 0.15))) {
                            model.showingCloseConfirm = false
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if model.isActiveEmpty {
                        Button("Discard", role: .destructive) { closeActiveTab(discard: true) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    } else {
                        Button("Unstick") { closeActiveTab(discard: false) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.radiusCard, style: .continuous)
                    .fill(.regularMaterial)
            )
            .transition(.opacity)
        }
    }

    /// Unstick (or discard) the active tab. Flushes first for the same reason
    /// `selectTab` does — closing a tab you have just typed into must keep those
    /// words, and on the unstick path the note lives on in the Notes pane where
    /// their loss would be visible.
    private func closeActiveTab(discard: Bool) {
        guard let id = model.activeID else { return }
        model.showingCloseConfirm = false
        if discard {
            // The row is about to be deleted, so there is nothing worth writing.
            model.discardPendingEdit()
            onDelete(id)
        } else {
            // Unstick keeps the note, so the last words typed have to survive.
            model.flushSave()
            onUnstick(id)
        }
    }
}
