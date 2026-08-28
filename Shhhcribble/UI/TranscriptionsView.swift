import SwiftUI
import AppKit

/// The Transcription Studio window. Shell per the locked redesign
/// ([docs/design/studio-wireframes.md](../../docs/design/studio-wireframes.md)):
/// a rail of three — **Dictations · Notes · Settings** — with the titlebar
/// always reading "Shhhcribble" (the rail's active state is the location
/// indicator, so the title never restates it).
///
/// The app is two halves and the rail says so (2026-08-28): **Dictations** is
/// the day stream of what you said ([TodayView](TodayView.swift)), **Notes** is
/// the one shelf of what you keep — written notes and transcribed documents in
/// a single master-detail — and Settings is its own environment. Read the
/// decision record before changing any of it.
struct TranscriptionsView: View {
    @ObservedObject var store: TranscriptStore
    @ObservedObject var fileTranscriber: FileTranscriber
    @ObservedObject var engine: TranscriptionEngine
    var appDelegate: AppDelegate
    @ObservedObject var chrome: TranscriptionsChrome
    var onTranscribeFile: () -> Void
    var onQuit: () -> Void

    @State private var section: RailSection? = .dictations
    @State private var settingsPage: SettingsPage = .preferences
    /// The day the Today stream is showing. **Owned here, not by `TodayView`.**
    /// The detail `switch` is a `_ConditionalContent`, so leaving a branch
    /// destroys its `@State` — a day kept inside the pane would silently reset
    /// on every trip through another tab, and a jump *into* Today would have
    /// nowhere to land. `nil` until the stream picks its opening day.
    @State private var todayDay: Date?
    /// The Notes shelf's selection — a note *or* a document, so it has to name
    /// which. Owned here rather than inside `NotesView` so a search result can
    /// jump straight to either, and so a rail round-trip doesn't lose the pick;
    /// the detail `switch` below is a `_ConditionalContent`, which destroys the
    /// `@State` of whichever branch you leave.
    @State private var noteSelection: NoteListSelection?
    @State private var searchText = ""
    @State private var notesSearchText = ""
    @State private var showingQuitConfirm = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    // Owned here (not inside FeedbackView) so a half-written report survives
    // switching to another rail tab and back — the detail `switch` rebuilds the
    // FeedbackView, but this window and its draft persist.
    @StateObject private var feedbackDraft = FeedbackDraft()

    /// The three rail destinations. Settings is one item that opens its own
    /// master-detail environment (see `SettingsPage`) — Styles, Dictionary and
    /// Feedback were demoted into it, since quick style *switching* lives in the
    /// menu-bar submenu and per-app auto; the page is for authoring.
    /// Declaration order **is** the rail order — `allCases` is what
    /// `StudioShellTests` pins. Documents was folded into Notes on 2026-08-28:
    /// the two were the same master-detail with different nouns, and a note and
    /// a document are both simply things you keep.
    enum RailSection: String, CaseIterable, Identifiable {
        case dictations, notes, settings
        var id: String { rawValue }
        var label: String {
            switch self {
            case .dictations: return "Dictations"
            case .notes:      return "Notes"
            case .settings:   return "Settings"
            }
        }
        var systemImage: String {
            switch self {
            // A mic, not a calendar: the pane is the record of what you *said*,
            // and it matches `SearchCategory.dictations` so a result's icon and
            // its destination agree.
            case .dictations: return "mic"
            case .notes:      return "note.text"
            case .settings:   return "gearshape"
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
            switch section ?? .dictations {
            case .dictations: todayPane
            case .notes:      notesPane
            case .settings:   settingsPane
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
        // The progress banner + Cancel live in the Notes list, so a file job
        // starting while another tab is up would otherwise run with no visible
        // progress or way to cancel — jump to where they are. It's also where
        // the finished transcript lands, so this answers "where did my import
        // go" before it's asked.
        .onChange(of: fileTranscriber.status) { _, newStatus in
            if case .running = newStatus { section = .notes }
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
            railTab(.dictations)
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

    // MARK: - Panes

    /// Dictations — the chronological day stream. Not a master-detail: a
    /// dictation is read in place, and a search result that *has* a reader
    /// (a note, a document) opens on the Notes shelf.
    private var todayPane: some View {
        TodayView(
            store: store,
            onOpenNote: { id in
                noteSelection = .note(id)
                section = .notes
            },
            onOpenTranscript: { id in
                noteSelection = .document(id)
                section = .notes
            },
            onUpload: onTranscribeFile,
            search: $searchText,
            day: $todayDay
        )
    }

    /// Notes — the one shelf of things you keep: written notes and transcribed
    /// documents in a single list, each opening its own kind of detail.
    /// Full-width, not the 620-capped Form panes.
    private var notesPane: some View {
        NotesView(store: store,
                  fileTranscriber: fileTranscriber,
                  appDelegate: appDelegate,
                  selection: $noteSelection,
                  search: $notesSearchText,
                  onUpload: onTranscribeFile)
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
