import SwiftUI
import AppKit

/// The Transcription Studio window: a three-pane environment (rail → searchable
/// list → tabbed detail) unifying dictation and file transcripts. This sprint
/// the detail is text-only; the Summary tab is scaffolded for Sprint 4b.
struct TranscriptionsView: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject var fileTranscriber: FileTranscriber
    @ObservedObject var engine: TranscriptionEngine
    var onTranscribeFile: () -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    @State private var section: RailSection? = .transcriptions
    @State private var selectedID: UUID?
    @State private var searchText = ""

    enum RailSection: String, CaseIterable, Identifiable {
        case home, transcriptions
        var id: String { rawValue }
        var label: String { self == .home ? "Home" : "Transcriptions" }
        var systemImage: String { self == .home ? "house" : "text.bubble" }
    }

    private var filtered: [Transcript] { store.matching(searchText) }
    private var selected: Transcript? { store.transcripts.first { $0.id == selectedID } }

    var body: some View {
        NavigationSplitView {
            rail
        } content: {
            switch section ?? .transcriptions {
            case .home:            homeColumn
            case .transcriptions:  listColumn
            }
        } detail: {
            detailColumn
        }
        .frame(minWidth: 860, minHeight: 500)
    }

    // MARK: - Rail

    private var rail: some View {
        List(selection: $section) {
            ForEach(RailSection.allCases) { s in
                Label(s.label, systemImage: s.systemImage).tag(s)
            }
        }
        .navigationSplitViewColumnWidth(min: 150, ideal: 172, max: 210)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Button(action: onTranscribeFile) {
                    Label("Transcribe File…", systemImage: "waveform.badge.plus")
                }
                Button(action: onOpenSettings) {
                    Label("Settings…", systemImage: "gearshape")
                }
                Button(action: onQuit) {
                    Label("Quit Shhhcribble", systemImage: "power")
                }
            }
            .buttonStyle(.borderless)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Home

    private var homeColumn: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Transcription Studio")
                .font(.title2).fontWeight(.medium)
            Text("Hold \(ModelManager.selectedHotkey.symbol) and speak to dictate, or transcribe an audio or video file.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onTranscribeFile) {
                Label("Transcribe File…", systemImage: "waveform.badge.plus")
            }
            .controlSize(.large)

            Label(engine.statusText, systemImage: engine.isReady ? "checkmark.circle" : "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private var listColumn: some View {
        List(selection: $selectedID) {
            if case .running = fileTranscriber.status {
                progressBanner
                    .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
            }
            ForEach(filtered) { t in
                TranscriptRow(transcript: t).tag(t.id)
            }
        }
        .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search transcripts")
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
    enum Tab: Hashable { case transcript, summary }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Picker("View", selection: $tab) {
                Text("Transcript").tag(Tab.transcript)
                Text("Summary").tag(Tab.summary)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Divider()
            Group {
                switch tab {
                case .transcript: transcriptBody
                case .summary:    summaryBody
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
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
        .onAppear { TranscriptSummarizer.prewarm() }
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
