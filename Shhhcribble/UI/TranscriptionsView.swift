import SwiftUI
import AppKit

/// The Transcription Studio window: a three-pane environment (rail → searchable
/// list → tabbed detail) unifying dictation and file transcripts. This sprint
/// the detail is text-only; the Summary tab is scaffolded for Sprint 4b.
struct TranscriptionsView: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject var fileTranscriber: FileTranscriber
    @ObservedObject var engine: TranscriptionEngine
    var appDelegate: AppDelegate
    var onTranscribeFile: () -> Void
    var onQuit: () -> Void

    @State private var section: RailSection? = .transcriptions
    @State private var selectedID: UUID?
    @State private var searchText = ""
    @State private var showingQuitConfirm = false

    /// Left-nav tabs. Transcriptions is a master-detail (list + reader); the
    /// other two fill the pane. Settings + Personal Dictionary moved in here
    /// from the old separate settings window.
    enum RailSection: String, CaseIterable, Identifiable {
        case transcriptions, dictionary, settings
        var id: String { rawValue }
        var label: String {
            switch self {
            case .transcriptions: return "Transcriptions"
            case .dictionary:     return "Personal Dictionary"
            case .settings:       return "Settings"
            }
        }
        var systemImage: String {
            switch self {
            case .transcriptions: return "text.bubble"
            case .dictionary:     return "character.book.closed"
            case .settings:       return "gearshape"
            }
        }
    }

    private var filtered: [Transcript] { store.matching(searchText) }
    private var selected: Transcript? { store.transcripts.first { $0.id == selectedID } }

    var body: some View {
        NavigationSplitView {
            rail
        } detail: {
            switch section ?? .transcriptions {
            case .transcriptions: transcriptionsPane
            case .dictionary:     dictionaryPane
            case .settings:       settingsPane
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
        List(selection: $section) {
            Section {
                ForEach([RailSection.transcriptions, .dictionary]) { s in
                    Label(s.label, systemImage: s.systemImage).tag(s)
                }
            }
            Section {
                Label(RailSection.settings.label, systemImage: RailSection.settings.systemImage)
                    .tag(RailSection.settings)
            }
        }
        .navigationSplitViewColumnWidth(min: 172, ideal: 196, max: 240)
        // No sidebar-collapse toggle: the rail carries Quit, which must stay
        // reachable — an LSUIElement app has no app menu (no ⌘Q fallback).
        .toolbar(removing: .sidebarToggle)
        .safeAreaInset(edge: .bottom) {
            Button { showingQuitConfirm = true } label: {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(.borderless)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Quit Shhhcribble?", isPresented: $showingQuitConfirm) {
            Button("Quit", role: .destructive) { onQuit() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Shhhcribble will stop running and your hotkey won’t work until you open it again.")
        }
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
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            List(selection: $selectedID) {
                if case .running = fileTranscriber.status {
                    progressBanner
                        .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                }
                ForEach(filtered) { t in
                    TranscriptRow(transcript: t).tag(t.id)
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
            Divider()
            Button(action: onTranscribeFile) {
                Label("Transcribe File…", systemImage: "waveform.badge.plus")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 9)
            .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }

    // MARK: - Dictionary & Settings panes

    private var dictionaryPane: some View {
        DictionarySettingsView(store: store)
            .frame(maxWidth: 620, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var settingsPane: some View {
        SettingsView(transcriptionEngine: engine, appDelegate: appDelegate, transcriptStore: store)
            .frame(maxWidth: 560, alignment: .topLeading)
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
}

/// One row in the transcripts list — source icon, title, snippet, and a
/// date · duration footer.
private struct TranscriptRow: View {
    let transcript: Transcript

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: transcript.source == .file ? "waveform" : "mic")
                .font(.system(size: 13))
                .foregroundStyle(transcript.source == .file ? Color.accentColor : Color.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(transcript.menuTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Text(transcript.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(footer)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var footer: String {
        var parts = [transcript.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if let d = transcript.durationSec, d > 0 {
            parts.append(Self.durationString(d))
        }
        return parts.joined(separator: " · ")
    }

    static func durationString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The detail pane: a tabbed reader (Transcript | Summary) with Copy / Save /
/// Reveal actions. Summary is a scaffolded placeholder for Sprint 4b.
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
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "checkmark.circle")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 13))
                                Text(item)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
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
