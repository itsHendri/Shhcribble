import SwiftUI
import AppKit

/// The Transcription Studio window. Shell per the locked redesign
/// ([docs/design/studio-wireframes.md](../../docs/design/studio-wireframes.md)):
/// a rail — **Today · Documents · Notes · Settings** — with the titlebar always
/// reading "Shhhcribble" (the rail's active state is the location indicator, so
/// the title never restates it).
///
/// Every pane is the redesign's own: Today is the day stream
/// ([TodayView](TodayView.swift)), Notes and Documents are master-detail, and
/// Settings is its own environment. Read the decision record before changing
/// any of it.
struct TranscriptionsView: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject var fileTranscriber: FileTranscriber
    @ObservedObject var engine: TranscriptionEngine
    var appDelegate: AppDelegate
    @ObservedObject var chrome: TranscriptionsChrome
    var onTranscribeFile: () -> Void
    var onQuit: () -> Void

    @State private var section: RailSection? = .today
    @State private var settingsPage: SettingsPage = .preferences
    /// The day the Today stream is showing. **Owned here, not by `TodayView`.**
    /// The detail `switch` is a `_ConditionalContent`, so leaving a branch
    /// destroys its `@State` — a day kept inside the pane would silently reset
    /// on every trip through another tab, and a jump *into* Today would have
    /// nowhere to land. `nil` until the stream picks its opening day.
    @State private var todayDay: Date?
    /// Documents keeps its own selection — it's a different list, and carrying
    /// Today's pick across would land on a row that isn't there.
    @State private var documentID: UUID?
    /// Owned here rather than inside `NotesView` so a search result can jump
    /// straight to a note, and so a tab round-trip doesn't lose the selection.
    @State private var noteID: UUID?
    @State private var searchText = ""
    @State private var documentSearchText = ""
    @State private var showingQuitConfirm = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    // Owned here (not inside FeedbackView) so a half-written report survives
    // switching to another rail tab and back — the detail `switch` rebuilds the
    // FeedbackView, but this window and its draft persist.
    @StateObject private var feedbackDraft = FeedbackDraft()

    /// The five rail destinations. Settings is one item that opens its own
    /// master-detail environment (see `SettingsPage`) — Styles, Dictionary and
    /// Feedback were demoted into it, since quick style *switching* lives in the
    /// menu-bar submenu and per-app auto; the page is for authoring.
    /// Declaration order **is** the rail order — `allCases` is what
    /// `StudioShellTests` pins. Documents sits above Notes (2026-08-10): now
    /// that Today is transcriptions only, Documents is the other half of the
    /// same material and belongs next to it, while Notes is the separate
    /// written environment.
    enum RailSection: String, CaseIterable, Identifiable {
        case today, documents, notes, settings
        var id: String { rawValue }
        var label: String {
            switch self {
            case .today:     return "Today"
            case .notes:     return "Notes"
            case .documents: return "Documents"
            case .settings:  return "Settings"
            }
        }
        var systemImage: String {
            switch self {
            case .today:     return "calendar"
            case .notes:     return "note.text"
            // A stack rather than a lined page: at rail size the ruled-document
            // glyph was nearly indistinguishable from the Notes one beside it.
            // Not `square.on.square` — that is now the copy glyph, and a rail
            // item sharing a shape with an action reads as a button.
            case .documents: return "rectangle.stack"
            case .settings:  return "gearshape"
            }
        }
    }

    /// Pages inside the Settings environment's subnav column.
    enum SettingsPage: String, CaseIterable, Identifiable {
        case preferences, styles, dictionary, feedback
        var id: String { rawValue }
        var label: String {
            switch self {
            case .preferences: return "Preferences"
            case .styles:      return "Styles"
            case .dictionary:  return "Dictionary"
            case .feedback:    return "Feedback"
            }
        }
        var systemImage: String {
            switch self {
            case .preferences: return "slider.horizontal.3"
            case .styles:      return "wand.and.stars"
            case .dictionary:  return "character.book.closed"
            case .feedback:    return "exclamationmark.bubble"
            }
        }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            rail
        } detail: {
            switch section ?? .today {
            case .today:     todayPane
            case .notes:     notesPane
            case .documents: documentsPane
            case .settings:  settingsPane
            }
        }
        // Explicit collapse control: the automatic sidebar toggle doesn't render
        // reliably with a custom (non-List) rail, so drive `columnVisibility`
        // ourselves. Quit stays reachable via the menu-bar right-click menu.
        // The sidebar toggle + branded title live in the window's titlebar bar
        // (TranscriptionsWindowController); the toggle flips `chrome.sidebarCollapsed`,
        // which we mirror onto the split view's column visibility here.
        .onChange(of: chrome.sidebarCollapsed) { _, collapsed in
            withAnimation(DesignSystem.motion(.easeInOut(duration: 0.2))) {
                columnVisibility = collapsed ? .detailOnly : .all
            }
        }
        // The progress banner + Cancel live in the Documents list, so a file job
        // starting while another tab is up would otherwise run with no visible
        // progress or way to cancel — jump to where they are.
        .onChange(of: fileTranscriber.status) { _, newStatus in
            if case .running = newStatus { section = .documents }
        }
        // Presented from `body`, not from the rail: the trigger moved into the
        // Settings subnav, and the rail is the one column that collapses.
        .alert("Quit Shhhcribble?", isPresented: $showingQuitConfirm) {
            Button("Quit", role: .destructive) { onQuit() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Shhhcribble will stop running and your hotkey won’t work until you open it again.")
        }
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 2) {
            railTab(.today)
            railTab(.documents)
            railTab(.notes)

            Spacer(minLength: 0)

            // Settings is the only bottom item now; Quit moved inside it (and
            // stays on the menu-bar right-click menu, which is what keeps the
            // "Quit must always be reachable" invariant true when the rail is
            // collapsed).
            railTab(.settings)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationSplitViewColumnWidth(min: 172, ideal: 196, max: 240)
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
                    RoundedRectangle(cornerRadius: DesignSystem.radiusControl, style: .continuous)
                        // Neutral, subtle — same family as the list-row selection,
                        // a touch lighter there so the two read as a hierarchy.
                        .fill(selected ? Color.primary.opacity(DesignSystem.fillActive) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Today & Documents (list + reader)

    /// Today — the chronological day stream. Not a master-detail: a dictation
    /// is read in place, and the things that *do* have readers (notes,
    /// documents) open in their own tab.
    private var todayPane: some View {
        TodayView(
            store: store,
            onOpenNote: { id in
                noteID = id
                section = .notes
            },
            onOpenTranscript: { id in
                documentID = id
                section = .documents
            },
            onUpload: onTranscribeFile,
            search: $searchText,
            day: $todayDay
        )
    }

    /// Documents — file imports, with the Transcript | Summary reader. Summaries
    /// are meant to live only here; the reader is shared with Today until phase
    /// 4 takes the reader out of the timeline.
    private var documentsPane: some View {
        TranscriptListPane(
            store: store,
            fileTranscriber: fileTranscriber,
            items: store.documents(matching: documentSearchText),
            selection: $documentID,
            search: $documentSearchText,
            searchPrompt: "Search documents",
            showsProgressBanner: true,
            emptyTitle: "No documents yet",
            emptyIcon: "doc.text",
            emptyMessage: "Audio files, videos and call recordings you transcribe end up here — with a summary a tap away.",
            onUpload: onTranscribeFile
        )
    }

    // MARK: - Notes pane

    // Full-width like the Today pane (it's the same master-detail template),
    // not the 620-capped Form panes.
    private var notesPane: some View {
        NotesView(store: store, appDelegate: appDelegate, selectedID: $noteID)
    }

    // MARK: - Settings environment

    /// One rail item, its own master-detail: a subnav column (Preferences /
    /// Styles / Dictionary / Feedback) with Check for updates + Quit anchored at
    /// its bottom, over the selected page.
    private var settingsPane: some View {
        HStack(spacing: 0) {
            settingsSubnav
                .frame(width: 180)
            Divider()
            settingsContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var settingsSubnav: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPage.allCases) { page in
                railRow(label: page.label, systemImage: page.systemImage,
                        selected: settingsPage == page) {
                    settingsPage = page
                }
            }

            Spacer(minLength: 0)

            // The two app-level actions, deliberately below the pages: neither
            // opens a page, both act immediately.
            if appDelegate.updaterAvailable {
                railRow(label: "Check for updates", systemImage: "arrow.triangle.2.circlepath",
                        selected: false) {
                    appDelegate.checkForUpdates()
                }
            }
            railRow(label: "Quit", systemImage: "power", selected: false) {
                showingQuitConfirm = true
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var settingsContent: some View {
        Group {
            switch settingsPage {
            case .preferences:
                SettingsView(transcriptionEngine: engine, appDelegate: appDelegate, transcriptStore: store)
            case .styles:
                StylesView(store: store)
            case .dictionary:
                DictionarySettingsView(store: store)
            case .feedback:
                FeedbackView(draft: feedbackDraft)
            }
        }
        .frame(maxWidth: 620, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

}

/// A searchable transcript list beside its reader — the master-detail shape
/// Today and Documents both wear.
///
/// It's a component rather than a pair of helper functions on the shell for one
/// reason: a `func` can't own state, so sharing it that way forces every list's
/// hover and toast state up into the window. Here, the genuinely transient state
/// (hover, the "Copied" toast) stays local, and only what has to survive a rail
/// round-trip — the selection and the query — is passed in.
private struct TranscriptListPane: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject var fileTranscriber: FileTranscriber
    let items: [Transcript]
    @Binding var selection: UUID?
    @Binding var search: String
    let searchPrompt: String
    /// Documents owns the file-job banner; Today would only show it in a column
    /// the user didn't start the job from.
    let showsProgressBanner: Bool
    let emptyTitle: String
    let emptyIcon: String
    let emptyMessage: String
    var onUpload: () -> Void

    @State private var hoveredID: UUID?
    @StateObject private var toast = ToastState()

    private var selected: Transcript? { store.transcripts.first { $0.id == selection } }

    var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)
            Divider()
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toast(toast)
        // Preselect the newest row the first time the list is shown; the `== nil`
        // guard means a later visit keeps whatever the user last picked.
        .onAppear {
            if selection == nil { selection = items.first?.id }
        }
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            SearchPill(text: $search, prompt: searchPrompt)
            // Custom row selection (tap → `selection`, subtle rounded fill)
            // instead of `List(selection:)` — the native focused selection turns
            // a prominent accent blue; a quiet, consistent highlight reads better
            // whether the row was auto-selected or clicked.
            List {
                if showsProgressBanner, case .running = fileTranscriber.status {
                    progressBanner
                        .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                }
                ForEach(Timeline.grouped(items, by: \.createdAt),
                        id: \.group) { bucket in
                    Section {
                        ForEach(bucket.items) { row($0) }
                    } header: {
                        Text(bucket.group.title).font(.sectionTitle)
                    }
                }
            }
            .overlay {
                if items.isEmpty && search.isEmpty {
                    ContentUnavailableView(
                        emptyTitle,
                        systemImage: emptyIcon,
                        description: Text(emptyMessage)
                    )
                } else if items.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            // Floating glass action hovering over the bottom of the list — one
            // primary verb per column.
            .overlay(alignment: .bottom) {
                Button(action: onUpload) {
                    Label("Upload Audio…", systemImage: "waveform.badge.plus")
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

    private func row(_ t: Transcript) -> some View {
        TranscriptRow(transcript: t,
                      hovered: hoveredID == t.id,
                      onCopy: { copy(t) })
            .contentShape(Rectangle())
            .onTapGesture { selection = t.id }
            .onHover { hoveredID = $0 ? t.id : (hoveredID == t.id ? nil : hoveredID) }
            .listRowSeparator(.hidden)
            .listRowBackground(
                RoundedRectangle(cornerRadius: DesignSystem.radiusControl, style: .continuous)
                    // Selected OR hovered rows get the same quiet grey (lighter
                    // than the rail-tab selection at 0.09) so hover and
                    // selection read as one affordance.
                    .fill(selection == t.id || hoveredID == t.id ? Color.primary.opacity(DesignSystem.fillHover) : Color.clear)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
            )
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let t = selected {
            TranscriptDetail(transcript: t, store: store, toast: toast)
                .id(t.id)
        } else {
            ContentUnavailableView(
                "Select a transcript",
                systemImage: "text.cursor",
                description: Text("Pick a transcript from the list to read it.")
            )
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

    /// Copy a row's text straight to the clipboard — the hover affordance so a
    /// transcript can be grabbed without selecting it first — and flash the same
    /// toast the detail pane uses.
    private func copy(_ t: Transcript) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(t.text, forType: .string)
        toast.flash("Copied")
    }

}


/// One row in the transcripts list — source icon, a title (up to two lines), and
/// a prominent trailing date. Hovering reveals copy in the *same fixed-width
/// slot* as the date, so the title never reflows on hover.
private struct TranscriptRow: View {
    let transcript: Transcript
    var hovered: Bool = false
    var onCopy: () -> Void = {}

    // Fixed trailing width keeps the title's truncation point constant whether the
    // slot shows the date or the hover actions; the fixed trailing HEIGHT keeps the
    // row from growing on hover (the buttons are taller than the date).
    private let trailingWidth: CGFloat = 72

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 5) {
                Text(transcript.menuTitle)
                    .font(.system(size: DesignSystem.ChromeText.body, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
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
            RowHoverButton("square.on.square", help: "Copy transcript", action: onCopy)
        } else {
            VStack(alignment: .trailing, spacing: 1) {
                Text(transcript.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let d = transcript.durationSec, d > 0 {
                    Text(Transcript.durationString(d))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

}

/// The detail pane: a tabbed reader (Transcript | Summary) with a pared
/// pin · copy · delete action row. Summary is generated on-device on demand.
private struct TranscriptDetail: View {
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
