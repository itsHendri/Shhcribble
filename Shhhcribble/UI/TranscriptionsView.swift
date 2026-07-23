import SwiftUI
import AppKit

/// The Transcription Studio window: a three-pane environment (rail → searchable
/// list → tabbed detail) unifying dictation and file transcripts. The detail is a
/// tabbed reader — Transcript, on-device AI Summary, and editable Notes.
struct TranscriptionsView: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject var fileTranscriber: FileTranscriber
    @ObservedObject var engine: TranscriptionEngine
    var appDelegate: AppDelegate
    @ObservedObject var chrome: TranscriptionsChrome
    var onTranscribeFile: () -> Void
    var onQuit: () -> Void

    @State private var section: RailSection? = .transcriptions
    @State private var selectedID: UUID?
    @State private var hoveredID: UUID?
    @State private var searchText = ""
    @State private var showingQuitConfirm = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var copiedToast = false
    @State private var copiedToastTask: Task<Void, Never>?
    // Owned here (not inside FeedbackView) so a half-written report survives
    // switching to another rail tab and back — the detail `switch` rebuilds the
    // FeedbackView, but this window and its draft persist.
    @StateObject private var feedbackDraft = FeedbackDraft()

    /// Left-nav tabs. Transcriptions is a master-detail (list + reader); the
    /// other two fill the pane. Settings + Dictionary moved in here from the
    /// old separate settings window.
    enum RailSection: String, CaseIterable, Identifiable {
        case transcriptions, notes, dictionary, styles, feedback, settings
        var id: String { rawValue }
        var label: String {
            switch self {
            case .transcriptions: return "Transcriptions"
            case .notes:          return "Notes"
            case .dictionary:     return "Dictionary"
            case .styles:         return "Styles"
            case .feedback:       return "Feedback"
            case .settings:       return "Settings"
            }
        }
        var systemImage: String {
            switch self {
            case .transcriptions: return "text.bubble"
            case .notes:          return "note.text"
            case .dictionary:     return "character.book.closed"
            case .styles:         return "wand.and.stars"
            case .feedback:       return "exclamationmark.bubble"
            case .settings:       return "gearshape"
            }
        }
    }

    private var filtered: [Transcript] { store.matching(searchText) }
    private var selected: Transcript? { store.transcripts.first { $0.id == selectedID } }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            rail
        } detail: {
            switch section ?? .transcriptions {
            case .transcriptions: transcriptionsPane
            case .notes:          notesPane
            case .dictionary:     dictionaryPane
            case .styles:         stylesPane
            case .feedback:       feedbackPane
            case .settings:       settingsPane
            }
        }
        // Explicit collapse control: the automatic sidebar toggle doesn't render
        // reliably with a custom (non-List) rail, so drive `columnVisibility`
        // ourselves. Quit stays reachable via the menu-bar right-click menu.
        // The sidebar toggle + branded title live in the window's titlebar bar
        // (TranscriptionsWindowController); the toggle flips `chrome.sidebarCollapsed`,
        // which we mirror onto the split view's column visibility here.
        .onChange(of: chrome.sidebarCollapsed) { _, collapsed in
            withAnimation(.easeInOut(duration: 0.2)) {
                columnVisibility = collapsed ? .detailOnly : .all
            }
        }
        // The progress banner + Cancel live in the Transcriptions list, so a
        // file job starting while another tab is up would otherwise run with no
        // visible progress or way to cancel — jump to where they are.
        .onChange(of: fileTranscriber.status) { _, newStatus in
            if case .running = newStatus { section = .transcriptions }
        }
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            railTab(.transcriptions)
            railTab(.notes)
            railTab(.dictionary)
            railTab(.styles)

            Spacer(minLength: 0)

            // Feedback + Settings sit at the bottom, just above Quit — the two
            // utility tabs grouped together. Quit reuses the exact same row styling
            // as the tabs (same icon/text weight and colour) and only differs by
            // asking for confirmation instead of switching panes.
            railTab(.feedback)
            railTab(.settings)
            railRow(label: "Quit", systemImage: "power", selected: false) {
                showingQuitConfirm = true
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationSplitViewColumnWidth(min: 172, ideal: 196, max: 240)
        // The native sidebar-collapse toggle stays available now: Quit is also
        // reachable from the menu-bar icon's right-click menu (Upload Audio +
        // Quit), so collapsing the rail no longer strands the only quit path.
        .alert("Quit Shhhcribble?", isPresented: $showingQuitConfirm) {
            Button("Quit", role: .destructive) { onQuit() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Shhhcribble will stop running and your hotkey won’t work until you open it again.")
        }
    }

    private func railTab(_ s: RailSection) -> some View {
        railRow(label: s.label, systemImage: s.systemImage, selected: section == s) {
            section = s
        }
    }

    /// One rail row — used by every nav tab *and* Quit so they share identical
    /// icon/text weight and colour; only the selected fill differs.
    private func railRow(label: String, systemImage: String, selected: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.body)
                .fontWeight(selected ? .medium : .regular)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        // Neutral, subtle — same family as the list-row selection,
                        // a touch lighter there so the two read as a hierarchy.
                        .fill(selected ? Color.primary.opacity(0.09) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Transcriptions pane (list + reader)

    private var transcriptionsPane: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
            Divider()
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { copiedToastView }
        // Preselect the newest transcript the first time the list is shown; the
        // `== nil` guard means a later visit keeps whatever the user last picked.
        .onAppear {
            if selectedID == nil { selectedID = filtered.first?.id }
        }
        .onDisappear { copiedToastTask?.cancel() }
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            searchField
            // Custom row selection (tap → `selectedID`, subtle rounded fill)
            // instead of `List(selection:)` — the native focused selection turns
            // a prominent accent blue; a quiet, consistent highlight reads better
            // whether the row was auto-selected or clicked.
            List {
                if case .running = fileTranscriber.status {
                    progressBanner
                        .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                }
                ForEach(filtered) { t in
                    TranscriptRow(transcript: t, hovered: hoveredID == t.id, onCopy: { copyTranscript(t) })
                        .contentShape(Rectangle())
                        .onTapGesture { selectedID = t.id }
                        .onHover { hoveredID = $0 ? t.id : (hoveredID == t.id ? nil : hoveredID) }
                        .listRowSeparator(.hidden)
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                // Selected OR hovered rows get the same quiet grey
                                // (lighter than the rail-tab selection at 0.09) so
                                // hover and selection read as one affordance.
                                .fill(selectedID == t.id || hoveredID == t.id ? Color.primary.opacity(0.04) : Color.clear)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                        )
                }
            }
            .overlay {
                if filtered.isEmpty && searchText.isEmpty {
                    ContentUnavailableView(
                        "No transcripts yet",
                        systemImage: "text.bubble",
                        description: Text("Dictate with your hotkey or transcribe a file to get started.")
                    )
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            // Floating glass action hovering over the bottom of the list.
            .overlay(alignment: .bottom) {
                Button(action: onTranscribeFile) {
                    Label("Upload Audio…", systemImage: "waveform.badge.plus")
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

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField("Search transcripts", text: $searchText)
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
        // Outlined pill (no fill) so the search reads as a distinct affordance
        // rather than sharing the neutral grey of the selection highlights.
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
        .padding(10)
    }

    // MARK: - Dictionary & Settings panes

    // Full-width like the Transcriptions pane (it's the same master-detail
    // template), not the 620-capped Form panes.
    private var notesPane: some View {
        NotesView(store: store)
    }

    private var dictionaryPane: some View {
        DictionarySettingsView(store: store)
            .frame(maxWidth: 620, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var stylesPane: some View {
        StylesView(store: store)
            .frame(maxWidth: 620, alignment: .topLeading)   // match the Dictionary pane width
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var settingsPane: some View {
        SettingsView(transcriptionEngine: engine, appDelegate: appDelegate, transcriptStore: store)
            .frame(maxWidth: 620, alignment: .topLeading)   // match the Dictionary pane width
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var feedbackPane: some View {
        FeedbackView(draft: feedbackDraft)
            .frame(maxWidth: 620, alignment: .topLeading)   // match the Settings pane width
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var progressBanner: some View {
        if case let .running(name, index, total, progress) = fileTranscriber.status {
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
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailColumn: some View {
        if let t = selected {
            TranscriptDetail(transcript: t, store: store)
                .id(t.id)
        } else {
            ContentUnavailableView(
                "Select a transcript",
                systemImage: "text.cursor",
                description: Text("Pick a transcript from the list to read it.")
            )
        }
    }

    /// Copy a row's text straight to the clipboard — the hover affordance so a
    /// transcript can be grabbed without selecting it first — and flash the same
    /// "Copied" toast the detail pane uses.
    private func copyTranscript(_ t: Transcript) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(t.text, forType: .string)
        copiedToastTask?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { copiedToast = true }
        copiedToastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { copiedToast = false }
        }
    }
}

/// One row in the transcripts list — source icon, a title (up to two lines), and
/// a prominent trailing date. Hovering reveals a copy button in the *same
/// fixed-width slot* as the date, so the title never reflows on hover.
private struct TranscriptRow: View {
    let transcript: Transcript
    var hovered: Bool = false
    var onCopy: () -> Void = {}

    // Fixed trailing width keeps the title's truncation point constant whether the
    // slot shows the date or the copy button; the fixed trailing HEIGHT keeps the
    // row from growing on hover (the copy button is taller than the date).
    private let trailingWidth: CGFloat = 72

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(transcript.menuTitle)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
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
            .help("Copy transcript")
        } else {
            VStack(alignment: .trailing, spacing: 1) {
                Text(transcript.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let d = transcript.durationSec, d > 0 {
                    Text(Self.durationString(d))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    static func durationString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The detail pane: a tabbed reader (Transcript | Summary | Notes) with Copy /
/// Save / Reveal actions. Summary is generated on-device on demand; Notes
/// auto-save.
private struct TranscriptDetail: View {
    let transcript: Transcript
    @ObservedObject var store: TranscriptStore

    @State private var tab: Tab = .transcript
    @State private var showingDeleteConfirm = false
    @State private var isSummarizing = false
    @State private var summaryError: String?
    @State private var didPrewarm = false
    @State private var notesText = ""
    @State private var noteSaveTask: Task<Void, Never>?
    @State private var copiedToast = false
    @State private var copiedToastTask: Task<Void, Never>?
    enum Tab: Hashable { case transcript, summary, notes }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Picker("View", selection: $tab) {
                Text("Transcript").tag(Tab.transcript)
                Text("Summary").tag(Tab.summary)
                Text("Notes").tag(Tab.notes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Neutral (adaptive gray) selected segment instead of the accent blue,
            // which read too heavy against the quiet neutral list/rail highlights.
            .tint(Color(nsColor: .secondaryLabelColor))
            .padding(12)
            Divider()
            Group {
                switch tab {
                case .transcript: transcriptBody
                case .summary:    summaryBody
                case .notes:      notesBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .overlay(alignment: .bottom) {
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
        // Tidy up the pending auto-dismiss when switching transcripts (the view
        // is identity-keyed, so a stray task would write into dead state).
        .onDisappear { copiedToastTask?.cancel() }
        .alert("Delete this transcript?", isPresented: $showingDeleteConfirm) {
            Button("Delete", role: .destructive) { store.delete(transcript.id) }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This permanently removes it from Shhhcribble. Any .txt file you saved isn't affected.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: transcript.source == .file ? "waveform" : "mic")
                        .foregroundStyle(transcript.source == .file ? Color.accentColor : Color.secondary)
                    Text(transcript.menuTitle).font(.headline).lineLimit(1)
                    if let style = currentStyleName, !style.isEmpty {
                        styleTag(style)
                    }
                }
                Text(metaLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Button(action: copy) { Image(systemName: "doc.on.doc") }
                    .help("Copy transcript")
                Button(action: saveTxt) { Image(systemName: "square.and.arrow.down") }
                    .help("Save as .txt")
                if transcript.sourcePath != nil {
                    Button(action: reveal) { Image(systemName: "folder") }
                        .help("Reveal source in Finder")
                }
                Button(role: .destructive) { showingDeleteConfirm = true } label: { Image(systemName: "trash") }
                    .help("Delete transcript")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
    }

    /// The style label to show on this transcript: the style's *current* name
    /// (looked up live by id, so a rename propagates to old tags), falling back to
    /// the snapshot name if the style was since deleted.
    private var currentStyleName: String? {
        if let id = transcript.styleID, let s = store.styles.first(where: { $0.id.uuidString == id }) {
            return s.name
        }
        return transcript.styleName
    }

    /// Small capsule showing the transform style a dictation was shaped with.
    /// Only rendered for real styles (Default clean-up / Off / file leave it nil).
    private func styleTag(_ name: String) -> some View {
        Text(name)
            .font(.caption2).fontWeight(.semibold)
            .lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var transcriptBody: some View {
        ScrollView {
            Text(transcript.text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
    }

    @ViewBuilder
    private var summaryBody: some View {
        if case .unavailable(let reason) = TranscriptSummarizer.availability {
            VStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("On-device summaries unavailable")
                    .font(.headline)
                InlineWarning(message: reason)
                    .frame(maxWidth: 360)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        } else if isSummarizing {
            VStack(spacing: 12) {
                ProgressView()
                Text("Summarizing…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let summary = transcript.summary {
            summaryContent(summary)
        } else {
            summaryEmptyState
        }
    }

    private func summaryContent(_ summary: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = summaryError {
                    InlineWarning(message: error)
                }
                Text(summary)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !transcript.actionItems.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Action Items")
                            .font(.subheadline).fontWeight(.semibold)
                        ForEach(Array(transcript.actionItems.enumerated()), id: \.offset) { _, item in
                            actionItemRow(item)
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button(action: generateSummary) {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                    Button(action: copySummary) {
                        Label("Copy summary", systemImage: "doc.on.doc")
                    }
                    Spacer()
                    if let at = transcript.summaryGeneratedAt {
                        Text("Generated \(at.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 4)
            }
            .padding(16)
        }
    }

    /// One action item, live: unpromoted → a plus button turns it into a task
    /// note (linked back to this transcript); promoted → a real checkbox bound
    /// to the note's done state, so check-off syncs with the Notes tab (it *is*
    /// the same note).
    @ViewBuilder
    private func actionItemRow(_ item: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if let note = store.noteForActionItem(transcriptID: transcript.id, item: item) {
                Button { store.toggleNoteDone(id: note.id) } label: {
                    Image(systemName: note.done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(note.done ? Color.accentColor : Color.secondary)
                        .font(.system(size: 13))
                }
                .buttonStyle(.borderless)
                .help(note.done ? "Mark as not done" : "Mark as done")
                Text(item)
                    .textSelection(.enabled)
                    .strikethrough(note.done, color: .secondary)
                    .foregroundStyle(note.done ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("in Notes")
                    .font(.caption2).foregroundStyle(.tertiary)
            } else {
                Button { store.promoteActionItem(transcriptID: transcript.id, item: item) } label: {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                }
                .buttonStyle(.borderless)
                .help("Add as task")
                Text(item)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var summaryEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Summarize this transcript")
                .font(.headline)
            Text("Generate an on-device summary and action items. Nothing leaves your Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if let error = summaryError {
                InlineWarning(message: error).frame(maxWidth: 340)
            }
            Button(action: generateSummary) {
                Label("Generate summary", systemImage: "sparkles")
            }
            .controlSize(.large)
            .disabled(transcript.text.isEmpty)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .onAppear {
            // Warm the model once per opened transcript, not on every tab toggle
            // (each prewarm allocates a fresh LanguageModelSession).
            guard !didPrewarm else { return }
            didPrewarm = true
            TranscriptSummarizer.prewarm()
        }
    }

    private var notesBody: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $notesText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(12)
            if notesText.isEmpty {
                // TextEditor has no native placeholder — overlay one, non-hittable
                // so taps fall through to the editor.
                Text("Add notes for this transcript…")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 20)
                    .allowsHitTesting(false)
            }
        }
        .onAppear { notesText = transcript.notes }
        .onChange(of: notesText) { _, _ in debounceNotesSave() }
        .onDisappear {
            noteSaveTask?.cancel()
            saveNotesNow()
        }
    }

    private var metaLine: String {
        var parts: [String] = [transcript.source == .file ? "Imported" : "Dictated"]
        parts.append(transcript.createdAt.formatted(date: .abbreviated, time: .shortened))
        if let d = transcript.durationSec, d > 0 { parts.append(TranscriptRow.durationString(d)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(transcript.text, forType: .string)
        flashCopied()
    }

    /// Briefly show the "Copied" toast, auto-dismissing after ~1.4 s. Cancels any
    /// in-flight dismissal so rapid re-copies keep the toast up rather than
    /// flickering.
    private func flashCopied() {
        copiedToastTask?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { copiedToast = true }
        copiedToastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { copiedToast = false }
        }
    }

    private func saveTxt() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        let base = transcript.fileName.map { ($0 as NSString).deletingPathExtension } ?? transcript.menuTitle
        panel.nameFieldStringValue = "\(base).txt"
        if panel.runModal() == .OK, let url = panel.url {
            try? transcript.text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func reveal() {
        guard let path = transcript.sourcePath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func copySummary() {
        guard let summary = transcript.summary else { return }
        var out = summary
        if !transcript.actionItems.isEmpty {
            out += "\n\nAction Items:\n" + transcript.actionItems.map { "• \($0)" }.joined(separator: "\n")
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(out, forType: .string)
        flashCopied()
    }

    /// Debounce writes while typing — reschedule a save 700 ms after the last
    /// keystroke. `.onDisappear` cancels this and flushes, so leaving the tab /
    /// switching transcripts / closing the window never loses the last edit.
    private func debounceNotesSave() {
        noteSaveTask?.cancel()
        // @MainActor so the deferred `store.updateNotes` (a @MainActor @Published
        // mutation) always lands on the main thread — a bare Task wouldn't
        // guarantee that isolation under the Swift 5 language mode.
        noteSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            saveNotesNow()
        }
    }

    private func saveNotesNow() {
        // No-op when unchanged — also stops a redundant write after the store
        // re-publishes the row (which feeds a new `transcript` value back in).
        guard notesText != transcript.notes else { return }
        store.updateNotes(id: transcript.id, notes: notesText)
    }

    private func generateSummary() {
        let text = transcript.text
        guard !text.isEmpty, !isSummarizing else { return }
        let id = transcript.id
        isSummarizing = true
        summaryError = nil
        Task {
            defer { isSummarizing = false }
            if let result = await TranscriptSummarizer.summarize(text) {
                store.updateSummary(id: id, summary: result.summary, actionItems: result.actionItems)
            } else {
                summaryError = "Couldn’t generate a summary. Please try again."
            }
        }
    }
}
