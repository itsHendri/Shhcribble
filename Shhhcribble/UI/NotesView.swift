import SwiftUI
import AppKit

/// The Notes shelf — **one master-detail over everything you keep**: written
/// notes and transcribed documents (imports, call captures) in a single list.
///
/// They were two rail items until 2026-08-28, and they were the same
/// master-detail with different nouns. A note and a document differ in how they
/// were made and how they're read, not in what they're *for* — so the list is
/// one, and only the detail forks: a note opens the rich-text editor, a document
/// opens the Transcript | Summary reader. That fork is why the selection is a
/// `NoteListSelection` rather than a bare id.
///
/// Notes are rich text: **⌘B/⌘I/⌘U** style the selection (handled by
/// `RichTextView` itself — see why there is no Format menu) and URLs become
/// clickable blue links. Tasks and reminders were cut 2026-07-23 — this is
/// plain note-taking for now.
struct NotesView: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject var fileTranscriber: FileTranscriber
    /// Needed for dictation into a note — the Studio shell already holds it.
    let appDelegate: AppDelegate
    /// Owned by the Studio shell, not by this view: a search result opens a
    /// note *or a document* by writing here and switching tabs, and a rail
    /// round-trip keeps the selection instead of snapping back to the newest.
    @Binding var selection: NoteListSelection?
    @Binding var search: String

    @State private var hoveredID: UUID?
    @StateObject private var toast = ToastState()

    /// The merged shelf, newest first — pure and tested in `NotesLibrary`.
    ///
    /// **Computed once per pass in `body` and handed down**, never read from
    /// several places: each read lowercases the title and text of *every*
    /// transcript (a library is mostly dictations, and none of them are shelf
    /// material) and re-sorts the notes. Reading it four times meant doing all
    /// of that four times per keystroke — the same defect review already caught
    /// in `TodayView`, which hoists `Search.results` for exactly this reason.
    private var rows: [NoteOrDocument] {
        NotesLibrary.merged(notes: store.notes(matching: search),
                            documents: store.documents(matching: search))
    }

    private var selectedNote: Note? {
        guard case .note(let id) = selection else { return nil }
        return store.notes.first { $0.id == id }
    }

    private var selectedDocument: Transcript? {
        guard case .document(let id) = selection else { return nil }
        return store.transcripts.first { $0.id == id }
    }

    var body: some View {
        let rows = self.rows
        let groups = NotesLibrary.partitioned(rows)
        return HStack(spacing: 0) {
            listColumn(rows: rows, groups: groups)
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
            Divider()
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toast(toast)
        // Preselect the newest item the first time the list is shown; the
        // `== nil` guard means a later visit keeps whatever the user last picked.
        .onAppear {
            if selection == nil { selection = rows.first?.id }
        }
        // Deleting the selected item leaves the selection pointing at a row that
        // no longer exists, and the detail pane stuck on its placeholder for the
        // life of the window — the `.onAppear` preselect can't help, because the
        // selection is non-nil and lives on the shell. Fall to the newest row
        // instead, which is where a fresh visit would have landed.
        .onChange(of: store.notes.count) { _, _ in dropDanglingSelection() }
        .onChange(of: store.transcripts.count) { _, _ in dropDanglingSelection() }
    }

    /// Clear a selection whose row has gone, so the detail pane recovers.
    /// Guarded on the row actually being absent, so an unrelated add or delete
    /// can't steal the user's current selection.
    private func dropDanglingSelection() {
        guard selection != nil, selectedNote == nil, selectedDocument == nil else { return }
        selection = rows.first?.id
    }

    // MARK: - List column

    private func listColumn(rows: [NoteOrDocument],
                            groups: (onScreen: [NoteOrDocument], rest: [NoteOrDocument])) -> some View {
        VStack(spacing: 0) {
            SearchPill(text: $search, prompt: "Search notes and documents")
            List {
                if case let .running(name, index, total, progress) = fileTranscriber.status {
                    progressBanner(name: name, index: index, total: total, progress: progress)
                        .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                        .listRowSeparator(.hidden)
                }
                // Always two sections, so sticking the first item doesn't
                // restructure the whole list and churn every row's identity.
                // An empty section draws nothing; the header appears only when
                // the group has rows, since an empty "Pinned" heading
                // would be a permanent reminder of a feature you aren't using.
                Section {
                    ForEach(groups.onScreen) { row($0) }
                } header: {
                    if !groups.onScreen.isEmpty {
                        Label("Pinned", systemImage: "pin")
                            .font(.sectionTitle)
                    }
                }
                // Then day groups, per the wireframe: fifty notes in one
                // undifferentiated column is a list you scroll past rather than
                // read.
                ForEach(Timeline.grouped(groups.rest, by: \.date), id: \.group) { bucket in
                    Section {
                        ForEach(bucket.items) { row($0) }
                    } header: {
                        Text(bucket.group.title).font(.sectionTitle)
                    }
                }
            }
            .overlay {
                // The shelf holds two kinds of thing, so the empty state has to
                // speak for both — otherwise it reads as "notes only" and the
                // Upload route looks like it belongs somewhere else.
                if rows.isEmpty && search.isEmpty {
                    ContentUnavailableView(
                        "Nothing kept yet",
                        systemImage: "note.text",
                        description: Text("This is the shelf for what you keep — notes you write, and the files and calls you transcribe.")
                    )
                } else if rows.isEmpty {
                    ContentUnavailableView.search(text: search)
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

    private func row(_ item: NoteOrDocument) -> some View {
        let rowID = item.id.id
        return LibraryRow(item: item,
                          hovered: hoveredID == rowID,
                          onTogglePin: { togglePin(item) })
            .contentShape(Rectangle())
            .onTapGesture { selection = item.id }
            .onHover { hoveredID = $0 ? rowID : (hoveredID == rowID ? nil : hoveredID) }
            .listRowSeparator(.hidden)
            .listRowBackground(
                RoundedRectangle(cornerRadius: DesignSystem.radiusControl, style: .continuous)
                    .fill(selection == item.id || hoveredID == rowID ? Color.primary.opacity(DesignSystem.fillHover) : Color.clear)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
            )
    }

    @ViewBuilder
    private func progressBanner(name: String, index: Int, total: Int, progress: Double) -> some View {
        HStack(spacing: 8) {
            ProgressView(value: progress > 0 ? progress : nil)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(total > 1 ? "Transcribing \(index) of \(total)" : "Transcribing…")
                    .font(.caption).fontWeight(.medium)
                Text(name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button("Cancel") { fileTranscriber.cancel() }
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    /// The fork the merged list exists to hide: same row, two readers.
    @ViewBuilder
    private var detailColumn: some View {
        if let note = selectedNote {
            NoteDetail(note: note, store: store, toast: toast, appDelegate: appDelegate,
                       noteDictation: appDelegate.noteDictation, onCopy: { copy(text: $0) })
                .id(note.id)
        } else if let document = selectedDocument {
            TranscriptDetail(transcript: document, store: store, toast: toast)
                .id(document.id)
        } else {
            ContentUnavailableView(
                "Select something to read",
                systemImage: "text.cursor",
                description: Text("Pick a note or a document from the list, or add a new note.")
            )
        }
    }

    // MARK: - Actions

    /// Create a fresh empty note and select it — the detail editor is where the
    /// typing happens (template: transcriptions never edit in the list).
    private func addNote() {
        let note = Note(text: "")
        store.addNote(note)
        search = ""
        selection = .note(note.id)
    }

    private func copyRow(_ item: NoteOrDocument) {
        switch item {
        case .note(let n):     copy(text: n.text)
        case .document(let t): copy(text: t.text)
        }
    }

    /// Put an item on screen, or take it down — the list's half of the same
    /// lifecycle the editor's capsule drives.
    ///
    /// **Safe against the mid-typing case without needing a flush**, which is
    /// worth spelling out because the editor's own capsule *does* call
    /// `saveNow()` first and the asymmetry looks like an oversight.
    ///
    /// Pinning the note you are currently typing in writes the store's copy —
    /// briefly stale — and re-publishes the row. The editor refuses that push
    /// while an edit is pending (`RichTextEditor.swift:811`), so nothing is
    /// clobbered on screen, and the 700 ms debounce then writes the live text
    /// over the stale row. The capsule flushes only because it sits *inside*
    /// the editor and can; from here there is no view to reach.
    private func togglePin(_ item: NoteOrDocument) {
        switch item {
        case .note(let n):
            store.setNoteStuck(id: n.id, stuck: !n.stuck)
            toast.flash(n.stuck ? "Unpinned" : "Pinned to screen")
        case .document(let t):
            store.setTranscriptStuck(id: t.id, stuck: !t.stuck)
            toast.flash(t.stuck ? "Unpinned" : "Pinned to screen")
        }
    }

    private func copy(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        toast.flash("Copied")
    }

    /// What the note says *after* its first line — the preview that goes under a
    /// title, so a card doesn't print the same line twice. Empty when the note
    /// is a single line, in which case the caller shows nothing rather than a
    /// duplicate.
    static func bodyPreview(_ text: String, limit: Int = 80) -> String {
        let rest = text.drop { !$0.isNewline }.drop { $0.isNewline }
        let flattened = rest.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !flattened.isEmpty else { return "" }
        let prefix = String(flattened.prefix(limit))
        return flattened.count > limit ? "\(prefix)…" : prefix
    }

    /// First line, capped, for row display and confirms. Takes the prefix rather
    /// than `split`ting — this runs per visible row, and a note holding a pasted
    /// transcript would otherwise allocate an array of every one of its lines
    /// just to read the first.
    static func preview(_ text: String) -> String {
        let firstLine = text.prefix { !$0.isNewline }
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "New note" }
        let prefix = String(trimmed.prefix(80))
        return trimmed.count > 80 ? "\(prefix)…" : prefix
    }
}

// MARK: - List row

/// One row of the merged shelf — a single-line title with a fixed-width trailing
/// slot that shows the date normally and copy on hover, so the title never
/// reflows.
///
/// A document is told apart by a **quiet leading glyph** and nothing else: the
/// list's whole argument is that these are the same kind of thing to you, so a
/// document row that shouted would undo it. The glyph is `source.icon`, the same
/// one its reader shows.
private struct LibraryRow: View {
    let item: NoteOrDocument
    var hovered: Bool = false
    var onTogglePin: () -> Void = {}

    private let trailingWidth: CGFloat = 72

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 5) {
                if case .document(let t) = item {
                    Image(systemName: t.source.icon)
                        .font(.system(size: DesignSystem.ChromeText.micro))
                        .foregroundStyle(.tertiary)
                }
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if item.isOnScreen {
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

    /// Hover reveals **pin only**. Copy used to live here and was removed on
    /// 2026-08-30 (Hendri's call): you select an item before copying it, because
    /// there is a lot of it — a one-click copy of something you haven't read is
    /// an action you can't verify. Pin is the opposite: its whole result is
    /// visible the instant you click it.
    @ViewBuilder
    private var trailing: some View {
        if hovered {
            RowHoverButton(item.isOnScreen ? "pin.slash" : "pin",
                           help: item.isOnScreen ? "Unpin from screen" : "Pin to screen",
                           action: onTogglePin)
        } else {
            VStack(alignment: .trailing, spacing: 1) {
                Text(item.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if case .document(let t) = item, let d = t.durationSec, d > 0 {
                    Text(Transcript.durationString(d))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

// MARK: - Detail

/// The detail pane: a rich-text note with the same header shape as
/// `TranscriptDetail` — icon + title + meta line on the left, Copy / Save /
/// Delete on the right — over an auto-saving editor (700 ms debounce, flush on
/// disappear and on focus loss).
///
/// A stuck note has **two live editors** (this pane and its sticky), so both
/// sides re-read the row when it changes elsewhere and neither writes while it
/// holds focus. See `syncFromStore` and `StickyNotePanel.update(with:)`.
private struct NoteDetail: View {
    let note: Note
    @ObservedObject var store: TranscriptStore
    /// The pane's toast, shared with the list so a pin from either side gets
    /// the same confirmation in the same place.
    @ObservedObject var toast: ToastState
    let appDelegate: AppDelegate
    /// Published flag so the microphone button reflects recording state.
    @ObservedObject var noteDictation: NoteDictationState
    var onCopy: (String) -> Void

    @State private var attributed = NSAttributedString(string: "")
    @State private var saveTask: Task<Void, Never>?
    @State private var showingDeleteConfirm = false
    /// An edit lives here that the store doesn't have yet. Guards store pushes
    /// and is cleared by `saveNow` — see `RichTextEditor.hasPendingEdit` for
    /// why this replaced focus.
    @State private var hasPendingEdit = false
    /// The stored values this pane last read from (or wrote to) the store —
    /// see the matching note on `StickyNotePanel`, which uses the same scheme
    /// to tell a real external edit from the store echoing our own write back.
    @State private var lastSyncedText: String?
    @State private var lastSyncedRich: Data?

    /// Handle onto the live text view, so a transform lands as one undoable
    /// edit instead of through the binding (which isn't undoable).
    @StateObject private var editorProxy = NoteEditorProxy()

    private static let editorFont = RichText.baseFont

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            RichTextEditor(
                attributed: $attributed,
                hasPendingEdit: $hasPendingEdit,
                font: Self.editorFont,
                // Room to scroll the last line clear of the stick capsule.
                bottomInset: 52,
                onFocusChange: { focused in if !focused { saveNow() } },
                onUserEdit: { scheduleSave() },
                proxy: editorProxy
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The column's single primary verb, as a floating capsule over the
            // editor — the twin of "Add Note" in the list. Its label *is* the
            // state, so there's no separate on-screen tag to keep in sync.
            .overlay(alignment: .bottom) { stickCapsule }
        }
        .onAppear { syncFromStore(note) }
        // Keep in step with the same note edited elsewhere — a floating sticky
        // is a second live editor for this row, so a styling change made there
        // has to land here too. Skipped while this editor has focus (the store
        // lags typing by the debounce).
        .onChange(of: note) { _, updated in
            guard !hasPendingEdit else { return }
            syncFromStore(updated)
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
                    if note.sourceTranscriptID != nil { TagCapsule("From transcript") }
                }
                Text(metaLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                dictateButton
                // Copies what's on screen: the store lags typing by the save
                // debounce, so a copy sourced from the stored row would hand
                // back the text as it was up to 700 ms ago.
                Button(action: { saveNow(); onCopy(attributed.string) }) { Image(systemName: "square.on.square") }
                    .buttonStyle(.borderless)
                    .help("Copy note")
                    .accessibilityLabel("Copy note")
                Button(role: .destructive) { showingDeleteConfirm = true } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .help("Delete note")
                    .accessibilityLabel("Delete note")
            }
        }
        .padding(12)
    }

    /// Speak into the note. Click to start, click again to stop.
    ///
    /// The hotkey would *mostly* work here already — Shhhcribble is frontmost
    /// and the paste path would find the note's text view — but only by
    /// accident: it would be shaped by whichever per-app style happened to
    /// resolve, it would go through the clipboard, and nothing would tell you it
    /// was possible. This makes it deliberate, and routes the text straight into
    /// the editor (see `AppDelegate.toggleNoteDictation`).
    private var dictateButton: some View {
        Button {
            saveNow()
            appDelegate.toggleNoteDictation { text in appendDictated(text) }
        } label: {
            Image(systemName: noteDictation.isActive ? "mic.fill" : "mic")
                .foregroundStyle(noteDictation.isActive ? Color.red : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help(noteDictation.isActive ? "Stop dictating" : "Dictate into this note")
        .accessibilityLabel(noteDictation.isActive ? "Stop dictating" : "Dictate into this note")
    }

    /// Append dictated text at the end of the note, as one undoable edit.
    ///
    /// **Appends rather than inserting at the caret**: clicking the microphone
    /// button takes focus off the text view, so there is no caret to speak of by
    /// the time the text arrives, and guessing at the last known position would
    /// be worse than a predictable rule.
    private func appendDictated(_ text: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.editorFont,
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: RichText.paragraphStyle(for: Self.editorFont),
        ]
        let addition = NSAttributedString(string: text, attributes: attributes)
        // Through the proxy so ⌘Z takes the dictation back out, so the editor's
        // own change callback schedules the save, and — the important part —
        // so the append is computed from the text as it is *now*, not as it was
        // when recording started. The user may have kept typing throughout.
        if editorProxy.append(addition, attributes: attributes) { return }

        // No live editor: the note was closed or another selected while we were
        // still transcribing. Write the words to the row rather than dropping
        // them, decoding and re-encoding so existing formatting survives.
        guard let current = store.notes.first(where: { $0.id == note.id }) else { return }
        let existing = RichText.attributed(from: current.richText, plain: current.text,
                                           font: Self.editorFont)
        let separator = current.text.isEmpty ? "" : (current.text.hasSuffix("\n") ? "" : "\n\n")
        let combined = NSMutableAttributedString(attributedString: existing)
        combined.append(NSAttributedString(string: separator, attributes: attributes))
        combined.append(addition)

        var updated = current
        updated.text = combined.string
        updated.richText = RichText.data(from: combined, font: Self.editorFont)
        store.updateNote(updated)
    }

    /// Stick: put the note on screen as a floating sticky — a note's only
    /// lifecycle. The label is the state ("Pin to screen" ↔ "Unpin"), which
    /// is why no tag is needed elsewhere.
    private var stickCapsule: some View {
        Button {
            saveNow()
            store.setNoteStuck(id: note.id, stuck: !note.stuck)
        } label: {
            // The additive glyph belongs to the additive verb.
            Label(note.stuck ? "Unpin" : "Pin to screen",
                  systemImage: note.stuck ? "pin.slash" : "pin")
                .font(.callout).fontWeight(.medium)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(.quaternary, lineWidth: 0.5))
                .shadow(color: .black.opacity(DesignSystem.shadowSoft), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 14)
        .help(note.stuck ? "Take this note off your screen (it stays here)"
                         : "Pin this note above your other windows")
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
        // Whatever happens below, this editor no longer holds anything the
        // store hasn't seen — so store pushes are safe again.
        defer { hasPendingEdit = false }
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
    /// with: no text, no styling, not stuck, and not linked to a transcript.
    private func discardIfUntouched() {
        guard let current = store.notes.first(where: { $0.id == note.id }),
              current.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              current.richText == nil,
              !current.stuck,
              current.sourceTranscriptID == nil else { return }
        store.deleteNote(id: current.id)
    }
}
