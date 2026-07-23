import SwiftUI
import AppKit

/// The Notes tab — a master-detail environment deliberately templated on the
/// Transcriptions pane (same searchable list on the left, same detail-with-
/// actions on the right, same floating glass action button, same toast and
/// confirm conventions). One converged list over the store's `Note` entity: a
/// **task** is a note with a checkbox (optional due-time reminder), a
/// **sticky** is a note pinned to the screen as a floating panel.
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
                            onToggleDone: { store.toggleNoteDone(id: note.id) },
                            onCopy: { copyNote(note) })
                        .contentShape(Rectangle())
                        .onTapGesture { selectedID = note.id }
                        .onHover { hoveredID = $0 ? note.id : (hoveredID == note.id ? nil : hoveredID) }
                        .listRowSeparator(.hidden)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selectedID == note.id || hoveredID == note.id ? Color.primary.opacity(0.04) : Color.clear)
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
                        description: Text("Add a note here, or promote an action item from a transcript's Summary tab.")
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
                        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
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
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
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
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Actions

    /// Create a fresh empty note and select it — the detail editor is where
    /// the typing happens (template: transcriptions never edit in the list).
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
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { copiedToast = true }
        copiedToastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { copiedToast = false }
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
/// button on hover, so the title never reflows. Tasks add a leading checkbox;
/// pinned/reminder state shows as small trailing glyphs in the title line.
private struct NoteRow: View {
    let note: Note
    var hovered: Bool = false
    var onToggleDone: () -> Void = {}
    var onCopy: () -> Void = {}

    private let trailingWidth: CGFloat = 72

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if note.isTask {
                Button(action: onToggleDone) {
                    Image(systemName: note.done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14))
                        .foregroundStyle(note.done ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(note.done ? "Mark as not done" : "Mark as done")
            }
            HStack(spacing: 5) {
                Text(NotesView.preview(note.text))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .strikethrough(note.done, color: .secondary)
                    .foregroundStyle(note.done ? Color.secondary : Color.primary)
                if note.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                if note.hasArmedReminder {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
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
        } else {
            Text(note.createdAt.formatted(date: .abbreviated, time: .omitted))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Detail

/// The detail pane: an editable note with the same header shape as
/// `TranscriptDetail` — icon + title + meta line on the left, Copy / Save /
/// Delete on the right — plus a compact controls row (task, reminder, pin)
/// and an auto-saving editor (700 ms debounce, flush on disappear).
private struct NoteDetail: View {
    let note: Note
    @ObservedObject var store: TranscriptStore
    var onCopy: () -> Void

    @State private var text = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var showingDeleteConfirm = false
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            controls
            Divider()
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($editorFocused)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        // Seed once; the view is keyed by note id, so a different note builds a
        // fresh instance. `saveNow` guards on `text != note.text`, which also
        // breaks the feedback loop when the store re-publishes the row.
        .onAppear {
            text = note.text
            // A freshly-added empty note goes straight to typing.
            if note.text.isEmpty { editorFocused = true }
        }
        .onChange(of: text) { _, _ in scheduleSave() }
        .onDisappear {
            saveTask?.cancel()
            saveNow()
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
                    Image(systemName: note.isTask ? "checkmark.circle" : "note.text")
                        .foregroundStyle(note.isTask ? Color.accentColor : Color.secondary)
                    Text(NotesView.preview(note.text)).font(.headline).lineLimit(1)
                    if note.sourceTranscriptID != nil {
                        sourceTag
                    }
                }
                Text(metaLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Button(action: { saveNow(); onCopy() }) { Image(systemName: "doc.on.doc") }
                    .help("Copy note")
                Button(action: saveTxt) { Image(systemName: "square.and.arrow.down") }
                    .help("Save as .txt")
                Button(role: .destructive) { showingDeleteConfirm = true } label: { Image(systemName: "trash") }
                    .help("Delete note")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
    }

    /// Small capsule marking a task promoted from a transcript's action items
    /// (same shape as the transcript style tag).
    private var sourceTag: some View {
        Text("from transcript")
            .font(.caption2).fontWeight(.semibold)
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var metaLine: String {
        var parts = [note.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if note.isTask, let due = note.dueAt {
            let overdue = !note.done && due < Date()
            parts.append("\(overdue ? "Overdue — was due" : "Due") \(due.formatted(date: .abbreviated, time: .shortened))")
        }
        if note.done, let at = note.completedAt {
            parts.append("Completed \(at.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " · ")
    }

    /// Task / reminder / pin controls — write straight to the store; the row
    /// republish keeps every surface (list, stickies, Summary tab) in sync.
    private var controls: some View {
        HStack(spacing: 16) {
            Toggle("Task", isOn: Binding(
                get: { note.isTask },
                set: { isTask in
                    var updated = note
                    updated.isTask = isTask
                    if !isTask {
                        updated.done = false
                        updated.completedAt = nil
                        updated.dueAt = nil
                        updated.reminderFiredAt = nil
                    }
                    store.updateNote(updated)
                }
            ))
            .toggleStyle(.checkbox)

            if note.isTask {
                Toggle("Done", isOn: Binding(
                    get: { note.done },
                    set: { _ in store.toggleNoteDone(id: note.id) }
                ))
                .toggleStyle(.checkbox)

                Toggle("Remind", isOn: Binding(
                    get: { note.dueAt != nil },
                    set: { remind in
                        var updated = note
                        updated.dueAt = remind ? Self.defaultDueDate() : nil
                        updated.reminderFiredAt = nil
                        store.updateNote(updated)
                    }
                ))
                .toggleStyle(.checkbox)

                if let due = note.dueAt {
                    DatePicker("When", selection: Binding(
                        get: { due },
                        set: { newDue in
                            var updated = note
                            updated.dueAt = newDue
                            updated.reminderFiredAt = nil   // a new time re-arms
                            store.updateNote(updated)
                        }
                    ), displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.compact)
                    .labelsHidden()
                }
            }

            Spacer()

            Toggle(isOn: Binding(
                get: { note.pinned },
                set: { store.setNotePinned(id: note.id, pinned: $0) }
            )) {
                Label("Pin to screen", systemImage: note.pinned ? "pin.fill" : "pin")
            }
            .toggleStyle(.button)
            .help(note.pinned ? "Unpin the floating sticky" : "Show as a floating sticky")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Next round hour — a sane default when "Remind" is first switched on.
    private static func defaultDueDate() -> Date {
        Calendar.current.nextDate(after: Date(), matching: DateComponents(minute: 0),
                                  matchingPolicy: .nextTime) ?? Date().addingTimeInterval(3600)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        guard text != note.text,
              var current = store.notes.first(where: { $0.id == note.id }) else { return }
        current.text = text
        store.updateNote(current)
    }

    private func saveTxt() {
        saveNow()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(NotesView.preview(text)).txt"
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
