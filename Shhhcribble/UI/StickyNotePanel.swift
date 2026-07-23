import AppKit
import SwiftUI
import Combine
import os

/// A floating, fully-editable sticky note — one per pinned `Note`.
///
/// Same panel species as `CallOfferPanel` (`.borderless + .nonactivatingPanel`,
/// `canBecomeKey`, `FirstMouseHostingView`) so the first click lands on its
/// controls without stealing focus from the frontmost app. Typing works in a
/// nonactivating key panel, but ⌘V/⌘Z route through the main menu of the
/// *active* app — so the moment the text editor gains focus we activate
/// Shhhcribble (the installed Edit menu then carries the shortcuts; this is
/// also how Apple Stickies behaves).
///
/// Visual language: the app's glass card (`.regularMaterial` + continuous
/// rounded rect + thin stroke), not yellow paper. Dragging the header persists
/// the position (`pinX`/`pinY`) via the manager; text edits save on a 700 ms
/// debounce (the transcript-Notes precedent) and flush when focus leaves.
@MainActor
final class StickyNotePanel: NSPanel {

    let noteID: UUID
    private let model = StickyModel()

    /// Debounce slot for persisting the dragged position.
    private var movePersist: DispatchWorkItem?
    private var moveObserver: NSObjectProtocol?

    /// Callbacks into the manager (which owns the store writes).
    var onTextCommit: ((UUID, String) -> Void)?
    var onToggleDone: ((UUID) -> Void)?
    var onUnpin: ((UUID) -> Void)?
    var onMove: ((UUID, CGPoint) -> Void)?
    var onDelete: ((UUID) -> Void)?

    private static let log = Logger(subsystem: "com.shhhcribble.app", category: "sticky")

    static let defaultSize = NSSize(width: 260, height: 200)

    init(note: Note) {
        self.noteID = note.id
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )

        level              = .floating
        backgroundColor    = .clear
        isOpaque           = false
        hasShadow          = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // The manager's dictionary holds the only strong reference; NSPanel
        // defaults releasedWhenClosed to true, which under ARC risks an
        // over-release if anything ever close()s instead of orderOut()s.
        isReleasedWhenClosed = false
        // The header row is the drag surface (the text editor claims drags in
        // its own area); background-drag makes the whole card grabbable
        // wherever SwiftUI doesn't swallow the mouse.
        isMovableByWindowBackground = true

        model.apply(note)

        let content = FirstMouseHostingView(rootView: StickyView(
            model: model,
            onCommitText: { [weak self] text in
                guard let self else { return }
                self.onTextCommit?(self.noteID, text)
            },
            onToggleDone: { [weak self] in
                guard let self else { return }
                self.onToggleDone?(self.noteID)
            },
            onUnpin: { [weak self] in
                guard let self else { return }
                self.onUnpin?(self.noteID)
            },
            onDelete: { [weak self] in
                guard let self else { return }
                self.onDelete?(self.noteID)
            }
        ))
        content.frame = NSRect(origin: .zero, size: Self.defaultSize)
        contentView = content

        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: self, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.schedulePersistPosition() }
        }
    }

    deinit {
        if let moveObserver { NotificationCenter.default.removeObserver(moveObserver) }
        movePersist?.cancel()
    }

    override var canBecomeKey: Bool { true }

    /// Refresh the panel from a changed store row. Text is only pushed in while
    /// the editor is *not* focused — the store lags live typing by the save
    /// debounce, so overwriting mid-edit would eat keystrokes.
    func update(with note: Note) {
        if !model.isEditing, model.text != note.text {
            model.text = note.text
        }
        model.isTask = note.isTask
        model.done = note.done
    }

    /// Show at the note's persisted origin (clamped to a visible screen), or at
    /// `preferredOrigin`, or centered-ish on the main screen.
    func present(at origin: CGPoint?) {
        let size = Self.defaultSize
        var point: CGPoint
        if let origin {
            point = origin
        } else if let screen = NSScreen.main ?? NSScreen.screens.first {
            let f = screen.visibleFrame
            point = CGPoint(x: f.midX - size.width / 2, y: f.midY - size.height / 2)
        } else {
            point = .zero
        }
        // Clamp so a sticky saved on a disconnected display comes back on-screen.
        if let screen = screenContaining(point) ?? NSScreen.main ?? NSScreen.screens.first {
            let f = screen.visibleFrame
            point.x = min(max(point.x, f.minX), f.maxX - size.width)
            point.y = min(max(point.y, f.minY), f.maxY - size.height)
        }
        setFrameOrigin(point)
        orderFront(nil)
    }

    /// Focus the text editor for immediate typing (menu-bar "New Note").
    func beginEditing() {
        makeKey()
        model.focusRequest += 1
    }

    private func screenContaining(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.visibleFrame.contains(point) }
    }

    private func schedulePersistPosition() {
        movePersist?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onMove?(self.noteID, self.frame.origin)
        }
        movePersist = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }
}

// MARK: - Manager

/// Owns one `StickyNotePanel` per pinned note. Observes the store and diffs:
/// newly-pinned notes get a panel, unpinned/deleted ones lose theirs, changed
/// rows refresh in place. All store writes funnel through here so the panels
/// stay dumb views.
@MainActor
final class StickyPanelManager {

    private let store: TranscriptStore
    private var panels: [UUID: StickyNotePanel] = [:]
    private var cancellables = Set<AnyCancellable>()

    /// The id of a note whose panel should begin editing as soon as it appears
    /// (the menu-bar "New Note" flow).
    private var pendingEditID: UUID?

    init(store: TranscriptStore) {
        self.store = store
        // `@Published` emits on willSet — hop a tick so `store.notes` is
        // current when we diff (same discipline as ReminderScheduler).
        store.$notes
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.sync() }
            }
            .store(in: &cancellables)
        sync()
    }

    /// Create a fresh, empty, pinned note near the mouse cursor and open its
    /// sticky ready for typing.
    func createStickyAtCursor() {
        var origin = NSEvent.mouseLocation
        origin.x -= StickyNotePanel.defaultSize.width / 2
        origin.y -= StickyNotePanel.defaultSize.height + 24   // just below the cursor/menu bar
        var note = Note(text: "")
        note.pinned = true
        note.pinX = origin.x
        note.pinY = origin.y
        pendingEditID = note.id
        store.addNote(note)   // → sync() presents the panel and begins editing
    }

    private func sync() {
        let pinned = store.notes.filter { $0.pinned }
        let pinnedIDs = Set(pinned.map { $0.id })

        for (id, panel) in panels where !pinnedIDs.contains(id) {
            panel.orderOut(nil)
            panels.removeValue(forKey: id)
        }

        for note in pinned {
            if let panel = panels[note.id] {
                panel.update(with: note)
            } else {
                let panel = makePanel(for: note)
                panels[note.id] = panel
                let origin: CGPoint? = (note.pinX != nil && note.pinY != nil)
                    ? CGPoint(x: note.pinX!, y: note.pinY!) : nil
                panel.present(at: origin)
                if pendingEditID == note.id {
                    pendingEditID = nil
                    panel.beginEditing()
                }
            }
        }
    }

    private func makePanel(for note: Note) -> StickyNotePanel {
        let panel = StickyNotePanel(note: note)
        panel.onTextCommit = { [weak self] id, text in
            guard let self, var current = self.store.notes.first(where: { $0.id == id }),
                  current.text != text else { return }
            current.text = text
            self.store.updateNote(current)
        }
        panel.onToggleDone = { [weak self] id in
            self?.store.toggleNoteDone(id: id)
        }
        panel.onUnpin = { [weak self] id in
            self?.store.setNotePinned(id: id, pinned: false)
        }
        panel.onMove = { [weak self] id, origin in
            self?.store.updateNotePinOrigin(id: id, origin: origin)
        }
        panel.onDelete = { [weak self] id in
            // An empty quick-add sticky closed without typing shouldn't leave a
            // blank row in the Notes tab — deleting from the sticky is scoped
            // to that case in the UI (the close button deletes only when empty,
            // otherwise it unpins).
            self?.store.deleteNote(id: id)
        }
        return panel
    }
}

// MARK: - View model + view

@MainActor
final class StickyModel: ObservableObject {
    @Published var text: String = ""
    @Published var isTask: Bool = false
    @Published var done: Bool = false
    /// True while the text editor has focus — blocks store→view text pushes.
    @Published var isEditing: Bool = false
    /// Bumped to request editor focus (quick-add).
    @Published var focusRequest: Int = 0

    func apply(_ note: Note) {
        text = note.text
        isTask = note.isTask
        done = note.done
    }
}

private struct StickyView: View {
    @ObservedObject var model: StickyModel
    let onCommitText: (String) -> Void
    let onToggleDone: () -> Void
    let onUnpin: () -> Void
    let onDelete: () -> Void

    @FocusState private var textFocused: Bool
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
            editor
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 5)
        .padding(6)   // transparent margin so the shadow doesn't clip
        .onChange(of: model.focusRequest) { _, _ in
            textFocused = true
        }
        .onChange(of: textFocused) { _, focused in
            model.isEditing = focused
            if focused {
                // ⌘V/⌘Z/⌘A route through the active app's main menu; as an
                // LSUIElement app ours only participates once activated (the
                // Apple Stickies behaviour).
                NSApp.activate(ignoringOtherApps: true)
            } else {
                flushSave()
            }
        }
        .onChange(of: model.text) { _, _ in
            guard model.isEditing else { return }   // store pushes don't re-save
            scheduleSave()
        }
        .onDisappear {
            saveTask?.cancel()
            flushSave()
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if model.isTask {
                Button(action: onToggleDone) {
                    Image(systemName: model.done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(model.done ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(model.done ? "Mark as not done" : "Mark as done")
            }
            Spacer(minLength: 0)
            Button(action: { model.text.isEmpty ? onDelete() : onUnpin() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(model.text.isEmpty ? "Discard" : "Unpin (keeps the note)")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        // The header is the reliable drag surface (isMovableByWindowBackground
        // covers it; the TextEditor below claims its own mouse events).
    }

    private var editor: some View {
        TextEditor(text: $model.text)
            .font(.system(size: 12.5))
            .scrollContentBackground(.hidden)
            .focused($textFocused)
            .strikethrough(model.isTask && model.done, color: .secondary)
            .foregroundStyle(model.isTask && model.done ? Color.secondary : Color.primary)
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let text = model.text
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            onCommitText(text)
        }
    }

    private func flushSave() {
        saveTask?.cancel()
        onCommitText(model.text)
    }
}
