import SwiftUI
import AppKit

/// The Notes module — a master-detail environment deliberately templated on
/// the Transcriptions pane (same searchable list on the left, same
/// detail-with-actions on the right, same floating glass action button, same
/// toast and confirm conventions).
///
/// Notes are rich text: **⌘B/⌘I/⌘U** style the selection (handled by
/// `RichTextView` itself — see why there is no Format menu) and URLs become
/// clickable blue links. Tasks and reminders were cut 2026-07-23 — this is
/// plain note-taking for now.
struct NotesView: View {
    @ObservedObject var store: TranscriptStore

    @State private var selectedID: UUID?
    @State private var hoveredID: UUID?
    @State private var searchText = ""
    @State private var copiedToast = false
    @State private var copiedToastTask: Task<Void, Never>?

    /// Newest first, like the transcripts list.
    private var ordered: [Note] {
        store.notes.sorted { $0.createdAt > $1.createdAt }
    }

    private var filtered: [Note] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return ordered }
        return ordered.filter { $0.text.lowercased().contains(q) }
    }

    private var selected: Note? { store.notes.first { $0.id == selectedID } }

    var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
            Divider()
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { copiedToastView }
        // Preselect the newest note the first time the list is shown; the
        // `== nil` guard means a later visit keeps whatever the user last picked.
        .onAppear {
            if selectedID == nil { selectedID = filtered.first?.id }
        }
        .onDisappear { copiedToastTask?.cancel() }
    }

    // MARK: - List column

    private var listColumn: some View {
        VStack(spacing: 0) {
            searchField
            List {
                ForEach(filtered) { note in
                    NoteRow(note: note,
                            hovered: hoveredID == note.id,
                            onCopy: { copyNote(note) })
                        .contentShape(Rectangle())
                        .onTapGesture { selectedID = note.id }
                        .onHover { hoveredID = $0 ? note.id : (hoveredID == note.id ? nil : hoveredID) }
                        .listRowSeparator(.hidden)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: DesignSystem.radiusControl, style: .continuous)
                                .fill(selectedID == note.id || hoveredID == note.id ? Color.primary.opacity(DesignSystem.fillHover) : Color.clear)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                        )
                }
            }
            .overlay {
                if filtered.isEmpty && searchText.isEmpty {
                    ContentUnavailableView(
                        "No notes yet",
                        systemImage: "note.text",
                        description: Text("Add a note here, or send an action item over from a transcript's Summary tab.")
                    )
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            // Floating glass action hovering over the bottom of the list —
            // the Notes twin of the Transcriptions "Upload Audio…" button.
            .overlay(alignment: .bottom) {
                Button(action: addNote) {
                    Label("Add Note", systemImage: "square.and.pencil")
                        .font(.callout).fontWeight(.medium)
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().stroke(.quaternary, lineWidth: 0.5))
                        .shadow(color: .black.opacity(DesignSystem.shadowSoft), radius: 8, y: 2)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField("Search notes", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button { searchText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(Capsule().strokeBorder(Color.primary.opacity(DesignSystem.strokeStrong), lineWidth: 1))
        .padding(10)
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let note = selected {
            NoteDetail(note: note, store: store, onCopy: { copyNote(note) })
                .id(note.id)
        } else {
            ContentUnavailableView(
                "Select a note",
                systemImage: "text.cursor",
                description: Text("Pick a note from the list, or add a new one.")
            )
        }
    }

    @ViewBuilder
    private var copiedToastView: some View {
        if copiedToast {
            Label("Copied", systemImage: "checkmark.circle.fill")
                .font(.callout).fontWeight(.medium)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(.quaternary, lineWidth: 0.5))
                .shadow(color: .black.opacity(DesignSystem.shadowSoft), radius: 8, y: 2)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Actions

    /// Create a fresh empty note and select it — the detail editor is where the
    /// typing happens (template: transcriptions never edit in the list).
    private func addNote() {
        let note = Note(text: "")
        store.addNote(note)
        searchText = ""
        selectedID = note.id
    }

    private func copyNote(_ note: Note) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(note.text, forType: .string)
        copiedToastTask?.cancel()
        withAnimation(DesignSystem.motion(.spring(response: 0.3, dampingFraction: 0.8))) { copiedToast = true }
        copiedToastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(DesignSystem.motion(.easeOut(duration: 0.25))) { copiedToast = false }
        }
    }

    /// First line, capped, for row display and confirms.
    static func preview(_ text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "New note" }
        let prefix = String(trimmed.prefix(80))
        return trimmed.count > 80 ? "\(prefix)…" : prefix
    }
}

// MARK: - List row

/// One row in the notes list — mirrors `TranscriptRow`: a single-line title
/// with a fixed-width trailing slot that shows the date normally and a copy
/// button on hover, so the title never reflows.
private struct NoteRow: View {
    let note: Note
    var hovered: Bool = false
    var onCopy: () -> Void = {}

    private let trailingWidth: CGFloat = 72

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 5) {
                Text(NotesView.preview(note.text))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if note.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: DesignSystem.ChromeText.micro))
                        .foregroundStyle(.tertiary)
                        .help("Pinned to your screen")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
                .frame(width: trailingWidth, height: 24, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder
    private var trailing: some View {
        if hovered {
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("Copy note")
            .accessibilityLabel("Copy note")
        } else {
            Text(note.createdAt.formatted(date: .abbreviated, time: .omitted))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Detail

/// The detail pane: a rich-text note with the same header shape as
/// `TranscriptDetail` — icon + title + meta line on the left, Copy / Save /
/// Delete on the right — over an auto-saving editor (700 ms debounce, flush on
/// disappear and on focus loss).
///
/// A pinned note has **two live editors** (this pane and its sticky), so both
/// sides re-read the row when it changes elsewhere and neither writes while it
/// holds focus. See `syncFromStore` and `StickyNotePanel.update(with:)`.
private struct NoteDetail: View {
    let note: Note
    @ObservedObject var store: TranscriptStore
    var onCopy: () -> Void

    @State private var attributed = NSAttributedString(string: "")
    @State private var saveTask: Task<Void, Never>?
    @State private var showingDeleteConfirm = false
    @State private var isEditing = false
    /// The stored values this pane last read from (or wrote to) the store —
    /// see the matching note on `StickyNotePanel`, which uses the same scheme
    /// to tell a real external edit from the store echoing our own write back.
    @State private var lastSyncedText: String?
    @State private var lastSyncedRich: Data?

    private static let editorFont = RichText.baseFont

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            RichTextEditor(
                attributed: $attributed,
                font: Self.editorFont,
                onFocusChange: { focused in
                    isEditing = focused
                    if !focused { saveNow() }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { syncFromStore(note) }
        // Keep in step with the same note edited elsewhere — a floating sticky
        // is a second live editor for this row, so a styling change made there
        // has to land here too. Skipped while this editor has focus (the store
        // lags typing by the debounce).
        .onChange(of: note) { _, updated in
            guard !isEditing else { return }
            syncFromStore(updated)
        }
        // Only the user's own typing schedules a save; a sync-in must not echo
        // straight back out as a write.
        .onChange(of: attributed) { _, _ in
            guard isEditing else { return }
            scheduleSave()
        }
        .onDisappear {
            saveTask?.cancel()
            saveNow()
            discardIfUntouched()
        }
        .alert("Delete this note?", isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) { store.deleteNote(id: note.id) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("“\(NotesView.preview(note.text))” will be removed. This can't be undone.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "note.text")
                        .foregroundStyle(.secondary)
                    Text(NotesView.preview(attributed.string)).font(.headline).lineLimit(1)
                    if note.pinned { tag("Pinned") }
                    if note.sourceTranscriptID != nil { tag("From transcript") }
                }
                Text(metaLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                pinButton
                Button(action: { saveNow(); onCopy() }) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("Copy note")
                    .accessibilityLabel("Copy note")
                Button(action: saveTxt) { Image(systemName: "square.and.arrow.down") }
                    .buttonStyle(.borderless)
                    .help("Save as .txt")
                    .accessibilityLabel("Save note as plain text file")
                Button(role: .destructive) { showingDeleteConfirm = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete note")
                    .accessibilityLabel("Delete note")
            }
        }
        .padding(12)
    }

    /// The pin control names the action it performs, never the current state —
    /// a button that still reads "Pin to Screen" once pinned (and only turns
    /// blue) leaves you guessing what clicking it does. Current state is shown
    /// by the "Pinned" tag beside the title and the list row's pin glyph.
    private var pinButton: some View {
        Button {
            store.setNotePinned(id: note.id, pinned: !note.pinned)
        } label: {
            Label(note.pinned ? "Unpin" : "Pin to Screen",
                  systemImage: note.pinned ? "pin.slash" : "pin")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(note.pinned ? "Remove the floating sticky (the note stays here)"
                          : "Show this note as a floating sticky")
    }

    /// Small neutral capsule, same shape as the transcript style tag.
    private func tag(_ label: String) -> some View {
        Text(label)
            .font(.caption2).fontWeight(.semibold)
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(DesignSystem.strokeSubtle)))
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var metaLine: String {
        var parts = [note.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if note.modifiedAt.timeIntervalSince(note.createdAt) > 1 {
            parts.append("Edited \(note.modifiedAt.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Saving

    /// Load the editor from a store row, unless it already shows exactly that.
    private func syncFromStore(_ source: Note) {
        guard source.text != lastSyncedText || source.richText != lastSyncedRich else { return }
        lastSyncedText = source.text
        lastSyncedRich = source.richText
        attributed = RichText.attributed(from: source.richText, plain: source.text,
                                         font: Self.editorFont)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    /// Persist the rich body plus its plain-text mirror. No-ops when nothing
    /// changed, which is what stops the store's republish from looping back.
    private func saveNow() {
        guard var current = store.notes.first(where: { $0.id == note.id }) else { return }
        let plain = attributed.string
        let rich = RichText.data(from: attributed, font: Self.editorFont)
        // Compare against what we last read/wrote, **not** against the store.
        // If we changed nothing, we have nothing to contribute — and writing
        // anyway would stamp our (possibly stale) copy over an edit the sticky
        // made in the meantime. `.onDisappear` flushes unconditionally, so this
        // is what stops switching notes from clobbering the other editor.
        guard plain != lastSyncedText || rich != lastSyncedRich else { return }
        current.text = plain
        current.richText = rich
        lastSyncedText = plain
        lastSyncedRich = rich
        store.updateNote(current)
    }

    /// Drop a note that was created and then left completely untouched, so a
    /// stray "Add Note" click doesn't leave a permanent blank row in the list.
    /// The sticky path asks "Discard this empty note?" for the same case; here
    /// there's nothing to ask about, because there is nothing to lose.
    ///
    /// Deliberately narrow — it must never reach a note the user did something
    /// with: no text, no styling, not pinned, and not linked to a transcript.
    private func discardIfUntouched() {
        guard let current = store.notes.first(where: { $0.id == note.id }),
              current.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              current.richText == nil,
              !current.pinned,
              current.sourceTranscriptID == nil else { return }
        store.deleteNote(id: current.id)
    }

    private func saveTxt() {
        saveNow()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(NotesView.preview(attributed.string)).txt"
        if panel.runModal() == .OK, let url = panel.url {
            try? attributed.string.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
