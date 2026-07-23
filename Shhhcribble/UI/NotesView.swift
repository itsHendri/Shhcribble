import SwiftUI
import AppKit

/// The Notes tab — its own left-nav tab in the Studio shell. One converged
/// list over the store's `Note` entity: a **task** is a note with a checkbox
/// (optional due-time reminder), a **sticky** is a note pinned to the screen
/// as a floating panel. Mirrors `StylesView` (grouped `Form`, sheet editor,
/// destructive-confirm).
struct NotesView: View {
    @ObservedObject var store: TranscriptStore

    @State private var showingAddSheet = false
    @State private var editingNote: Note? = nil
    @State private var deletingNote: Note? = nil

    private var tasks: [Note] { store.notes.filter { $0.isTask } }
    private var plainNotes: [Note] { store.notes.filter { !$0.isTask } }

    var body: some View {
        Form {
            // MARK: Tasks
            Section {
                if tasks.isEmpty {
                    Text("No tasks yet — add one, or promote an action item from a transcript's Summary tab.")
                        .font(.caption).foregroundColor(.secondary)
                }
                // Open tasks first; completed sink to the bottom of the section.
                ForEach(tasks.filter { !$0.done }) { note in
                    noteRow(note)
                }
                ForEach(tasks.filter { $0.done }) { note in
                    noteRow(note)
                }
            } header: {
                Text("Tasks").font(.sectionTitle)
            } footer: {
                Text("Tasks with a reminder show a banner at their due time while Shhhcribble is running — no notification permission involved.")
                    .font(.caption).foregroundColor(.secondary)
            }

            // MARK: Notes
            Section {
                if plainNotes.isEmpty {
                    Text("No notes yet.")
                        .font(.caption).foregroundColor(.secondary)
                }
                ForEach(plainNotes) { note in
                    noteRow(note)
                }
                Button("Add…") { showingAddSheet = true }
            } header: {
                Text("Notes").font(.sectionTitle)
            } footer: {
                Text("Pin any note or task to keep it floating on your screen as a sticky. Stickies are editable in place and stay put across launches.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .alert("Delete this note?", isPresented: Binding(
            get: { deletingNote != nil },
            set: { if !$0 { deletingNote = nil } }
        ), presenting: deletingNote) { note in
            Button("Delete", role: .destructive) { store.deleteNote(id: note.id) }
            Button("Cancel", role: .cancel) { }
        } message: { note in
            Text("“\(Self.preview(note.text))” will be removed. This can't be undone.")
        }
        .sheet(isPresented: $showingAddSheet) {
            NoteEditor(title: "Add Note") { text, isTask, dueAt, pinned in
                var note = Note(text: text)
                note.isTask = isTask
                note.dueAt = isTask ? dueAt : nil
                note.pinned = pinned
                store.addNote(note)
            }
        }
        .sheet(item: $editingNote) { note in
            NoteEditor(
                title: "Edit Note",
                text: note.text,
                isTask: note.isTask,
                dueAt: note.dueAt,
                pinned: note.pinned
            ) { text, isTask, dueAt, pinned in
                var updated = note
                updated.text = text
                updated.isTask = isTask
                updated.pinned = pinned
                let newDue = isTask ? dueAt : nil
                if newDue != updated.dueAt {
                    // A changed due time re-arms the reminder; a cleared one
                    // disarms it. Either way the old fired-state is stale.
                    updated.dueAt = newDue
                    updated.reminderFiredAt = nil
                }
                if !isTask { updated.done = false; updated.completedAt = nil }
                store.updateNote(updated)
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func noteRow(_ note: Note) -> some View {
        HStack(spacing: 8) {
            if note.isTask {
                Button { store.toggleNoteDone(id: note.id) } label: {
                    Image(systemName: note.done ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(note.done ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(note.done ? "Mark as not done" : "Mark as done")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(Self.preview(note.text))
                    .lineLimit(2).truncationMode(.tail)
                    .strikethrough(note.done, color: .secondary)
                    .foregroundStyle(note.done ? Color.secondary : Color.primary)
                HStack(spacing: 6) {
                    if let due = note.dueAt, note.isTask {
                        dueChip(due, done: note.done)
                    }
                    if note.sourceTranscriptID != nil {
                        Text("from transcript")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            }

            Spacer(minLength: 8)

            Button { store.setNotePinned(id: note.id, pinned: !note.pinned) } label: {
                Image(systemName: note.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(note.pinned ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(note.pinned ? "Unpin from screen" : "Pin to screen")

            Button { editingNote = note } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")

            Button { deletingNote = note } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
    }

    @ViewBuilder
    private func dueChip(_ due: Date, done: Bool) -> some View {
        let overdue = !done && due < Date()
        Label(due.formatted(date: .abbreviated, time: .shortened), systemImage: "bell")
            .font(.caption2)
            .foregroundStyle(overdue ? Color.orange : Color.secondary)
    }

    /// First line, capped, for row display and the delete confirm.
    static func preview(_ text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        let prefix = String(trimmed.prefix(80))
        return trimmed.count > 80 ? "\(prefix)…" : prefix
    }
}

// MARK: - Note editor

/// Sheet used for Add / Edit. Save is disabled until the text has
/// non-whitespace content. The due-time picker only shows for tasks with
/// "Remind me" on; turning "Task" off clears the reminder on save.
private struct NoteEditor: View {
    let title: String
    @State private var text: String
    @State private var isTask: Bool
    @State private var remind: Bool
    @State private var dueAt: Date
    @State private var pinned: Bool
    let onSave: (_ text: String, _ isTask: Bool, _ dueAt: Date?, _ pinned: Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    init(title: String,
         text: String = "",
         isTask: Bool = false,
         dueAt: Date? = nil,
         pinned: Bool = false,
         onSave: @escaping (_ text: String, _ isTask: Bool, _ dueAt: Date?, _ pinned: Bool) -> Void) {
        self.title = title
        _text = State(initialValue: text)
        _isTask = State(initialValue: isTask)
        _remind = State(initialValue: dueAt != nil)
        // Default a fresh reminder to the next round hour so the picker doesn't
        // start on an already-past minute.
        _dueAt = State(initialValue: dueAt ?? Calendar.current.nextDate(
            after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? Date())
        _pinned = State(initialValue: pinned)
        self.onSave = onSave
    }

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)

            TextEditor(text: $text)
                .font(.body)
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            Toggle("Task (checkable)", isOn: $isTask)

            if isTask {
                Toggle("Remind me", isOn: $remind)
                if remind {
                    DatePicker("When", selection: $dueAt, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.compact)
                }
            }

            Toggle("Pin to screen", isOn: $pinned)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(trimmedText, isTask, (isTask && remind) ? dueAt : nil, pinned)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedText.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
