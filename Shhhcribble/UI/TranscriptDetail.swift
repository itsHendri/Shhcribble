import SwiftUI
import AppKit

/// The reader for a **document** — an import or a call capture: a tabbed
/// Transcript | Summary pane with a copy · delete action row. The summary is
/// generated on-device, on demand.
///
/// Lives on the Notes shelf, which is the one list of things you keep
/// (2026-08-28). Summaries exist only here — a quick dictation is read in the
/// day stream and let go.
struct TranscriptDetail: View {
    let transcript: Transcript
    @ObservedObject var store: TranscriptStore
    /// The pane's toast, shared with the list so a pin from either side gets
    /// the same confirmation in the same place.
    @ObservedObject var toast: ToastState

    @State private var tab: Tab = .transcript
    @State private var showingDeleteConfirm = false
    @State private var isSummarizing = false
    @State private var summaryError: String?
    @State private var didPrewarm = false
    /// Notes became their own module 2026-07-23 — a transcript is a record of
    /// what was said, not a place to keep your own writing.
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
            // Neutral (adaptive gray) selected segment instead of the accent blue,
            // which read too heavy against the quiet neutral list/rail highlights.
            .tint(Color(nsColor: .secondaryLabelColor))
            // Full width. Inside a leading-aligned stack a segmented picker
            // takes its *ideal* width, so it sat stubby against a wide reader
            // and read as a stray control rather than the pane's own switch.
            .frame(maxWidth: .infinity)
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
            Text("This permanently removes it from Shhhcribble. A transcribed file's .txt sidecar isn't affected.")
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    // Neutral for every source. The accent was doing no work
                    // here — the meta line underneath already names the source,
                    // and colouring an identity glyph made it read as a status
                    // (human's call, 2026-07-27).
                    Image(systemName: transcript.source.icon)
                        .foregroundStyle(.secondary)
                    Text(transcript.menuTitle).font(.headline).lineLimit(1)
                    if let style = currentStyleName, !style.isEmpty {
                        // Shows the transform style a dictation was shaped with;
                        // Default clean-up / Off / file transcripts leave it nil.
                        TagCapsule(style)
                    }
                }
                Text(metaLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            // Copy · delete only. Save-as-.txt and reveal-in-Finder were
            // dropped in the redesign: a .txt sidecar is already written beside
            // the source at transcription time, and the source itself is often
            // ephemeral (a WhatsApp file, a since-deleted upload) — the
            // transcript is the durable artifact.
            HStack(spacing: 6) {
                Button(action: copy) { Image(systemName: "square.on.square") }
                    .help("Copy transcript")
                    .accessibilityLabel("Copy transcript")
                Button(role: .destructive) { showingDeleteConfirm = true } label: { Image(systemName: "trash") }
                    .help("Delete transcript")
                    .accessibilityLabel("Delete transcript")
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
                        Label("Copy summary", systemImage: "square.on.square")
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

    /// One action item, with a one-click send into the Notes module. Already
    /// sent → a quiet "In Notes" marker instead of the button (the link holds
    /// through later edits of the note — see `noteForActionItem`).
    @ViewBuilder
    private func actionItemRow(_ item: ActionItem) -> some View {
        let existing = store.noteForActionItem(transcriptID: transcript.id, item: item.text)
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 8) {
                if existing != nil {
                    Image(systemName: "note.text")
                        .foregroundStyle(Color.accentColor)
                        .font(.system(size: 13))
                } else {
                    Button { store.promoteActionItem(transcriptID: transcript.id, item: item.text) } label: {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.borderless)
                    .help("Add to Notes")
                    .accessibilityLabel("Add action item to Notes")
                }
                Text(item.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let label = item.owner.label {
                    TagCapsule(label)
                }
                if existing != nil {
                    Text("In Notes")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            // The sentence this came from. It's the same string SummaryGuard
            // verified against the transcript, so showing it is what makes the
            // item auditable rather than something the user has to take on
            // trust — an item that couldn't cite the transcript never got here.
            if !item.quote.isEmpty {
                Text("“\(item.quote)”")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .padding(.leading, 21)
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

    private var metaLine: String {
        var parts: [String] = [transcript.source.label]
        parts.append(transcript.createdAt.formatted(date: .abbreviated, time: .shortened))
        if let d = transcript.durationSec, d > 0 { parts.append(Transcript.durationString(d)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(transcript.text, forType: .string)
        toast.flash("Copied")
    }


    private func copySummary() {
        guard let summary = transcript.summary else { return }
        var out = summary
        if !transcript.actionItems.isEmpty {
            out += "\n\nAction Items:\n" + transcript.actionItems.map { item in
                if let label = item.owner.label { return "• \(item.text) (\(label))" }
                return "• \(item.text)"
            }.joined(separator: "\n")
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(out, forType: .string)
        toast.flash("Copied")
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
