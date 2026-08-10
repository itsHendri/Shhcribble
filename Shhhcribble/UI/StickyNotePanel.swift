import AppKit
import SwiftUI
import Combine
import os

/// A single floating, resizable sticky panel holding **every stuck note as a
/// tab** (borrowed from Wispr's Scratchpad, 2026-08-10).
///
/// **Tabs are presentation; stick/unstick is still the only lifecycle.** That
/// is what makes the window's behaviour fall out for free: closing a *tab*
/// unsticks that note, and the panel disappears on its own once the last tab
/// goes — so there is deliberately **no window close button** and no new
/// destructive semantics to design. It also means nothing about the Notes pane,
/// the Pinned board, or the schema had to change.
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
/// exceeds them (the CallOfferPanel lesson) — and margins fight resizing,
/// because the resize edge would sit in transparent space. With `hasShadow`
/// on, AppKit draws the shadow around the card's opaque rounded shape, it can
/// never clip, and the panel edge == the visible card edge, which is exactly
/// where `.resizable` puts the resize cursors.
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

    private static let log = Logger(subsystem: "com.shhhcribble.app", category: "sticky")

    /// Bigger than the pre-tabs default (260×200) because a tab bar needs
    /// horizontal room before it starts scrolling.
    static let defaultSize = NSSize(width: 320, height: 260)
    static let minStickySize = NSSize(width: 240, height: 170)
    static let maxStickySize = NSSize(width: 640, height: 640)

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask:   [.borderless, .nonactivatingPanel, .resizable],
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
        minSize = Self.minStickySize
        maxSize = Self.maxStickySize
        // The manager holds the only strong reference; NSPanel defaults
        // releasedWhenClosed to true, which under ARC risks an over-release if
        // anything ever close()s instead of orderOut()s.
        isReleasedWhenClosed = false

        model.onCommit = { [weak self] id, text in self?.onTextCommit?(id, text) }

        let content = FirstMouseHostingView(rootView: StickyView(
            model: model,
            onUnstick:  { [weak self] id in self?.onUnstick?(id) },
            onDelete:   { [weak self] id in self?.onDelete?(id) },
            onNewTab:   { [weak self] in self?.onNewTab?() },
            onActivate: { [weak self] id in self?.onActiveTabChange?(id) }
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
    /// would eat keystrokes. See `StickyTabsModel.apply(notes:)`.
    func update(notes: [Note], preferredActive: UUID?) {
        model.apply(notes: notes, preferredActive: preferredActive)
    }

    /// The tab currently on screen, so the manager can persist it — including
    /// when `apply(notes:)` picked a new one after the active tab was unstuck
    /// from the Notes pane, which no user-initiated callback would cover.
    var activeTabID: UUID? { model.activeID }

    /// Show at the saved frame (clamped to a visible screen), or at
    /// `preferredOrigin`, or centred-ish on the main screen.
    func present(at origin: CGPoint?, size restoredSize: CGSize?) {
        var size = restoredSize ?? Self.defaultSize
        size.width = min(max(size.width, minSize.width), maxSize.width)
        size.height = min(max(size.height, minSize.height), maxSize.height)

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
            let f = screen.visibleFrame
            point.x = min(max(point.x, f.minX), f.maxX - size.width)
            point.y = min(max(point.y, f.minY), f.maxY - size.height)
        }
        setFrame(NSRect(origin: point, size: size), display: true)
        orderFront(nil)
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
    }

    private let store: TranscriptStore
    private let defaults: UserDefaults
    private var panel: StickyNotePanel?
    private var cancellables = Set<AnyCancellable>()

    /// The id of a note whose tab should be focused as soon as it appears
    /// (the menu-bar "New Note" and the panel's + button).
    private var pendingEditID: UUID?

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
        sync()
    }

    /// Create a fresh, empty stuck note and focus its tab. Stuck implies pinned
    /// — see `Note`. The cursor position is only used when there is no panel on
    /// screen yet; otherwise this just adds a tab to the panel you can already
    /// see, and moving it under the mouse would be startling.
    func createStickyAtCursor() {
        var note = Note(text: "")
        note.stuck = true
        note.pinned = true   // sticking auto-pins
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
        let stuck = store.stuckNotesInTabOrder

        guard !stuck.isEmpty else {
            panel?.orderOut(nil)
            panel = nil
            return
        }

        let panel = panel ?? makePanel(placedFor: stuck)
        self.panel = panel
        panel.update(notes: stuck, preferredActive: savedActiveID(among: stuck))
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
    private func savedActiveID(among stuck: [Note]) -> UUID? {
        guard let raw = defaults.string(forKey: Key.activeNote),
              let id = UUID(uuidString: raw),
              stuck.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private func makePanel(placedFor stuck: [Note]) -> StickyNotePanel {
        let panel = StickyNotePanel()
        panel.onTextCommit = { [weak self] id, attributed in
            guard let self, var current = self.store.notes.first(where: { $0.id == id }) else { return }
            let plain = attributed.string
            let rich = RichText.data(from: attributed, font: StickyTabsModel.font)
            guard plain != current.text || rich != current.richText else { return }
            current.text = plain
            current.richText = rich
            self.store.updateNote(current)
        }
        panel.onUnstick = { [weak self] id in
            self?.store.setNoteStuck(id: id, stuck: false)
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
        let (origin, size) = restoredPlacement(for: stuck)
        panel.present(at: origin, size: size)
        return panel
    }

    /// Where to put a freshly-created panel: the saved panel frame, else — for
    /// someone upgrading from one-panel-per-note — the frame of their most
    /// recently touched sticky, so the panel appears roughly where they left
    /// their stickies rather than jumping to the middle of the screen.
    private func restoredPlacement(for stuck: [Note]) -> (CGPoint?, CGSize?) {
        if let raw = defaults.string(forKey: Key.frame) {
            let frame = NSRectFromString(raw)
            if frame.width > 0 && frame.height > 0 { return (frame.origin, frame.size) }
        }
        guard let legacy = store.stuckNotes.first, let x = legacy.pinX, let y = legacy.pinY else {
            return (nil, nil)
        }
        let size: CGSize? = (legacy.pinW != nil && legacy.pinH != nil)
            ? CGSize(width: legacy.pinW!, height: legacy.pinH!) : nil
        return (CGPoint(x: x, y: y), size)
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

    /// Tab order — stable creation order, see `stuckNotesInTabOrder`.
    @Published private(set) var notes: [Note] = []
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

    var activeNote: Note? { notes.first { $0.id == activeID } }

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
    /// harmless: `modifiedAt` orders the Notes list and the Pinned board's
    /// on-screen strip, so merely clicking between tabs would reshuffle both.
    func flushSave() {
        saveTask?.cancel()
        guard let id = activeID, hasPendingEdit else { return }
        hasPendingEdit = false
        let plain = attributed.string
        let rich = RichText.data(from: attributed, font: Self.font)
        // Record what we're about to write so the store's echo back through
        // `apply(notes:)` isn't mistaken for an external edit.
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
    func apply(notes incoming: [Note], preferredActive: UUID? = nil) {
        let previousIndex = activeID.flatMap { id in notes.firstIndex { $0.id == id } }
        notes = incoming

        if let activeID, incoming.contains(where: { $0.id == activeID }) {
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
        // The tab that took its index, or the new last one if it was rightmost.
        let landing = previousIndex.map { min($0, incoming.count - 1) } ?? 0
        activate(incoming.indices.contains(landing) ? incoming[landing].id : incoming.first?.id)
    }

    /// Tab label: the first non-empty line, short. The **active** tab reads from
    /// the live editor rather than the stored row, so a title you are typing
    /// appears immediately instead of lagging by the save debounce.
    func label(for note: Note) -> String {
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

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            RichTextEditor(
                attributed: $model.attributed,
                hasPendingEdit: $model.hasPendingEdit,
                font: StickyTabsModel.font,
                insets: NSSize(width: 8, height: 4),
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
                resetsUndoOnExternalChange: true
            )
            .padding(.bottom, 6)
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
        .onDisappear { model.flushSave() }
    }

    /// Tabs, then the new-tab button. The row's padding doubles as the drag
    /// surface — `isMovableByWindowBackground` moves the panel from any
    /// background the SwiftUI hierarchy doesn't claim.
    private var tabBar: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.notes) { note in
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
        }
        .padding(.horizontal, 8)
        .padding(.top, 7)
        .padding(.bottom, 5)
        .contentShape(Rectangle())
    }

    /// One tab. The close control sits on the **active** tab only: a row of ✕s
    /// across a small card is noise, and putting it here keeps the confirmation
    /// unambiguous about which note it is about. Closing an inactive tab is
    /// therefore select-then-close, which is fine — unsticking in bulk belongs
    /// to the Notes pane.
    private func tab(for note: Note) -> some View {
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
