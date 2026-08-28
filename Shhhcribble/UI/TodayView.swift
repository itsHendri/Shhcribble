import SwiftUI
import AppKit

/// The Dictations stream — the day-scoped record of what you said.
///
/// **Dictations only** (2026-08-28). Notes left in 2026-08-10 (this is what you
/// *said*; a note is what you *wrote*), and documents left now: an import or a
/// call is long-form material you *keep*, so it belongs on the shelf beside the
/// notes, not passing through a day. What's left is one honest thing — which is
/// why the tab says Dictations rather than Today, a name that never matched a
/// pane you can page backwards through.
///
/// A dictation is high-frequency and semi-throwaway: you keep it to recover a
/// paste that missed or to re-use an old prompt. It never needed a reader, and
/// it never needed a list row that hides four fifths of it behind an ellipsis —
/// so dictations render as **borderless lines, always fully expanded**. The
/// two-weights treatment survives only in search results, where a document match
/// still reads as the document it is.
///
/// The stream is scoped to one day. Chevrons step a day — **forward is dead on
/// today**, since you can't dictate into the future; the day label opens a month
/// popover with dots on the days that have anything, so finding older work
/// doesn't mean clicking backwards through empty days.
struct TodayView: View {
    @ObservedObject var store: TranscriptStore
    /// Opening an anchored card hands it back to the shell, which moves to
    /// Documents. Search can still surface a note, so opening one stays wired
    /// even though the stream itself never shows notes.
    var onOpenNote: (UUID) -> Void
    var onOpenTranscript: (UUID) -> Void
    var onUpload: () -> Void

    @Binding var search: String
    /// Owned by the shell — see `TranscriptionsView.todayDay`. `nil` until the
    /// stream picks its opening day, which is also what makes that pick happen
    /// once per window rather than once per visit.
    @Binding var day: Date?

    @State private var showingMonth = false
    @State private var hoveredID: UUID?
    @State private var deleting: Transcript?
    @StateObject private var toast = ToastState()

    /// Whether the stream is on today. Asked of the calendar, never of the
    /// day *label* — that's user-facing text and will be localised.
    private var isShowingToday: Bool { Calendar.current.isDateInToday(shownDay) }

    /// Whether the forward chevron has anywhere to go — see `Timeline`.
    private var canStepForward: Bool { Timeline.canStepForward(from: shownDay) }

    /// The day being shown, falling back to today until the opening pick lands.
    private var shownDay: Date { day ?? Calendar.current.startOfDay(for: Date()) }

    private var items: [Transcript] {
        Timeline.items(on: shownDay, transcripts: store.transcripts)
    }

    private var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearching: Bool { !query.isEmpty }

    var body: some View {
        // Computed once per pass and handed down. Searching the library is a
        // full pass over every note and transcript, so re-deriving it in the
        // header *and* the results view meant doing that twice per keystroke.
        let grouped = isSearching
            ? Search.results(for: query, transcripts: store.transcripts, notes: store.notes)
            : [:]
        return VStack(spacing: 0) {
            header(grouped)
            Divider()
            if isSearching {
                resultsView(grouped)
            } else if items.isEmpty {
                emptyState
            } else {
                stream
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Esc clears the search and puts the day back — the other half of the
        // ✕ in the pill, and what anyone who has used a search field expects.
        .onExitCommand { if isSearching { search = "" } }
        .toast(toast)
        .onAppear {
            // Open on the last day that actually has something — a blank page on
            // a quiet morning is a worse first impression than yesterday's work.
            // `day` is the shell's, so this runs once per window, not per visit.
            guard day == nil else { return }
            day = Timeline.openingDay(around: Date(), transcripts: store.transcripts)
                ?? Calendar.current.startOfDay(for: Date())
        }
        // Follow new work to the day it landed on. Without this, dictating while
        // the stream sits on an older day (which is the *default* opening state
        // after a quiet couple of days, and what any window left open past
        // midnight becomes) puts the text in your editor and nowhere visible
        // here — the most likely confusion in the whole redesign.
        .onChange(of: store.transcripts.first?.id) { _, _ in
            guard let newest = store.transcripts.first else { return }
            // A finishing import is not stream material, so it must not yank the
            // day — the shell moves you to Notes for that instead.
            guard !newest.source.isDocument else { return }
            let landed = Calendar.current.startOfDay(for: newest.createdAt)
            guard !Calendar.current.isDate(landed, inSameDayAs: shownDay) else { return }
            withAnimation(DesignSystem.motion(.easeOut(duration: DesignSystem.motionQuick))) {
                day = landed
                search = ""
            }
        }
        .alert("Delete this?", isPresented: Binding(
            get: { deleting != nil },
            set: { if !$0 { deleting = nil } }
        ), presenting: deleting) { item in
            Button("Delete", role: .destructive) { delete(item) }
            Button("Cancel", role: .cancel) { }
        } message: { item in
            Text(deleteMessage(for: item))
        }
    }

    // MARK: - Header

    private func header(_ grouped: [SearchCategory: [SearchResult]]) -> some View {
        HStack(spacing: 8) {
            SearchPill(text: $search, prompt: "Search everything",
                       trailing: resultCount(grouped))
            Spacer(minLength: 0)
            // The date navigator is meaningless against results that span every
            // day, so it steps aside until the search is cleared.
            if !isSearching {
                dateNav
                    .padding(.trailing, 12)
            }
        }
    }

    private func resultCount(_ grouped: [SearchCategory: [SearchResult]]) -> String? {
        guard isSearching else { return nil }
        let n = Search.total(grouped)
        return "\(n) result\(n == 1 ? "" : "s")"
    }

    private var dateNav: some View {
        HStack(spacing: 2) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.borderless)
                .help("Previous day")
                .accessibilityLabel("Previous day")

            Button { showingMonth = true } label: {
                Text(Timeline.dayLabel(for: shownDay))
                    .font(.system(size: DesignSystem.ChromeText.control, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 92)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Pick a day")
            .popover(isPresented: $showingMonth, arrowEdge: .bottom) {
                MonthPicker(month: shownDay, selected: shownDay, store: store) { picked in
                    day = picked
                    showingMonth = false
                }
                // Keyed on the day so reopening after stepping can't show a
                // month the button beside it disagrees with.
                .id(shownDay)
            }

            // Dead on today: there is no dictating into the future, so the only
            // thing a forward step could reach is a blank page.
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
                .disabled(!canStepForward)
                .help("Next day")
                .accessibilityLabel("Next day")
        }
    }

    private func step(_ days: Int) {
        withAnimation(DesignSystem.motion(.easeOut(duration: DesignSystem.motionQuick))) {
            day = Timeline.day(shownDay, steppedBy: days)
        }
    }

    // MARK: - Stream

    private var stream: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(items) { item in
                    row(item)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
        }
    }

    /// Width of the trailing slot — the time only, now that the actions live
    /// inline in the meta line.
    private let trailingWidth: CGFloat = 58

    private func row(_ item: Transcript) -> some View {
        HStack(alignment: .top, spacing: 10) {
            dictationLine(item)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Time far right, permanently. It puts every item's content on one
            // left edge — a left time gutter indented the content past the day
            // header and took the eye first, which was most of why the stream
            // read as inactive — and keeps the timestamp where an activity feed
            // puts it. Ruled with Hendri 2026-07-27.
            Text(item.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: DesignSystem.ChromeText.secondary))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: trailingWidth, alignment: .trailing)
                .padding(.top, 1)
        }
        // Delete is the one hover-revealed control left here, so the whole row
        // has to be the hover target: `onHover` hit-tests *drawn* content, and
        // a row whose right half is transparent dismisses itself as the pointer
        // crosses towards the button. This shape is what makes it reachable.
        .contentShape(Rectangle())
        .onHover { hoveredID = $0 ? item.id : (hoveredID == item.id ? nil : hoveredID) }
    }

    /// A dictation passes through: no border, no truncation, the whole thing.
    ///
    /// **Full-strength text, not secondary** (ruled 2026-07-27): a dictation is
    /// the record of what you said and the reason to open this screen. Rendering
    /// it in the dimmest colour in the app, under a timestamp that took the eye
    /// first, was what made the whole stream read as inactive. The border on the
    /// anchored cards is what carries the two-weights hierarchy — it doesn't
    /// need the passing items greyed out as well.
    private func dictationLine(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t.text)
                .font(.system(size: DesignSystem.ChromeText.body))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            metaLine(for: t) {
                Text(wordCount(t.text))
                if let style = t.styleName, !style.isEmpty {
                    TagCapsule(style)
                }
            }
        }
    }

    /// Still used by the search results, which keep the two weights — a
    /// document match reads as the document it is. The stream itself no longer
    /// has an anchored branch.
    private func card<Content: View>(open: @escaping () -> Void,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4, content: content)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.radiusControl, style: .continuous)
                    .fill(DesignSystem.boxFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.radiusControl, style: .continuous)
                    .stroke(DesignSystem.boxStroke, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: open)
    }

    /// The quiet line under an item — **copy first, then what the item has to
    /// say about itself, then delete out at the far right on hover** (Hendri,
    /// 2026-08-10).
    ///
    /// The asymmetry is the point. Copy is the reason this screen exists, so it
    /// leads the line and is always there. Delete is the one thing you'd hate to
    /// hit by accident, so it stays out of the reading path and out of sight
    /// until you're on the row — the opposite treatment, at the opposite end.
    private func metaLine<Leading: View>(for item: Transcript,
                                         @ViewBuilder leading: () -> Leading) -> some View {
        HStack(spacing: 6) {
            InlineAction("square.on.square", help: "Copy") { copy(item) }
            leading()
                .font(.system(size: DesignSystem.ChromeText.secondary))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if hoveredID == item.id {
                InlineAction("trash", help: "Delete") { deleting = item }
            }
        }
        // Reserve the height either way, so revealing delete can't nudge the
        // line it sits on.
        .frame(height: 18)
    }

    // MARK: - Search results

    /// Results replace the timeline, grouped by category and dated within each.
    /// Same two weights as the stream, so a result reads like the thing it is.
    @ViewBuilder
    private func resultsView(_ grouped: [SearchCategory: [SearchResult]]) -> some View {
        if Search.total(grouped) == 0 {
            ContentUnavailableView.search(text: query)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                    ForEach(SearchCategory.allCases) { category in
                        if let rows = grouped[category], !rows.isEmpty {
                            Section {
                                ForEach(rows) { resultRow($0) }
                            } header: {
                                Label("\(category.title) · \(rows.count)", systemImage: category.icon)
                                    .font(.sectionTitle)
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.background)
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
            }
        }
    }

    private func resultRow(_ result: SearchResult) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if result.isAnchored {
                    card(open: { open(result) }) {
                        highlighted(result.title)
                            .font(.system(size: DesignSystem.ChromeText.body, weight: .medium))
                            .lineLimit(1)
                        highlighted(result.body)
                            .font(.system(size: DesignSystem.ChromeText.secondary))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                } else {
                    // A dictation has no title of its own, so the body is the
                    // whole row — and here it *is* trimmed: the full-expansion
                    // rule belongs to the day stream, where it's the record of
                    // what you said, not to a list of matches.
                    highlighted(result.body)
                        .font(.system(size: DesignSystem.ChromeText.body))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { open(result) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Trailing, like the stream — one date edge across the whole pane.
            // A result's label carries its year when it isn't this one's.
            Text(Timeline.dayLabel(for: result.date))
                .font(.system(size: DesignSystem.ChromeText.secondary))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: trailingWidth, alignment: .trailing)
                .padding(.top, result.isAnchored ? 9 : 1)
        }
    }

    /// The match picked out with the accent — the only place accent is used on
    /// content, which is what makes it read as "this is why you're seeing this".
    private func highlighted(_ snippet: SearchSnippet) -> Text {
        Text(snippet.leading)
            + Text(snippet.match).foregroundColor(.accentColor).fontWeight(.semibold)
            + Text(snippet.trailing)
    }

    /// Jump to the result in its home surface. A dictation has no reader, so it
    /// goes back to the day it happened on — which is where it can be read in
    /// full, copied, or sent to a note.
    private func open(_ result: SearchResult) {
        switch result.category {
        case .notes:      onOpenNote(result.id)
        case .documents:  onOpenTranscript(result.id)
        case .dictations:
            day = Calendar.current.startOfDay(for: result.date)
            search = ""
        }
    }

    // MARK: - Empty state

    /// Teaches the hotkey rather than apologising for being empty — on a day
    /// with nothing on it, the useful thing to say is how to put something there.
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar")
                .font(.system(size: DesignSystem.ChromeText.icon))
                .foregroundStyle(.tertiary)
            Text(isShowingToday ? "Nothing captured yet" : "Nothing on this day")
                .font(.headline)
            HStack(spacing: 6) {
                Text("Hold")
                keycap(ModelManager.availableHotkeys
                    .first { $0.id == ModelManager.selectedHotkeyID }?.symbol ?? "⌥Space")
                // On a past day, "lands here" would be a lie — a dictation lands
                // on today, and the stream jumps there when it does.
                Text(isShowingToday
                     ? "and speak — your dictation pastes where you're typing and lands here."
                     : "and speak — your dictation lands on today.")
            }
            .font(.system(size: DesignSystem.ChromeText.control))
            .foregroundStyle(.secondary)

            // Back to **one** capsule (2026-08-10). The two-capsule carve-out
            // existed because an empty Today had no route to a note — which
            // stopped being Today's problem when notes left the stream. Upload
            // is the pane's one primary verb again; the hotkey line above covers
            // the other way to put something here.
            capsule("Upload Audio…", icon: "waveform.badge.plus", action: onUpload)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func capsule(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.callout).fontWeight(.medium)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(.quaternary, lineWidth: 0.5))
                .shadow(color: .black.opacity(DesignSystem.shadowSoft), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
    }

    private func keycap(_ symbol: String) -> some View {
        Text(symbol)
            .font(.system(size: DesignSystem.ChromeText.secondary, design: .monospaced))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.radiusBadge)
                    .stroke(Color.primary.opacity(DesignSystem.strokeStrong), lineWidth: 1)
            )
    }

    // MARK: - Actions

    private func wordCount(_ text: String) -> String {
        let n = text.split { $0.isWhitespace }.count
        return "\(n) word\(n == 1 ? "" : "s")"
    }

    private func copy(_ item: Transcript) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.text, forType: .string)
        toast.flash("Copied")
    }

    // Add-to-note was removed from the stream 2026-08-10: turning a
    // transcription into a note read as the wrong move here — Today is a log of
    // what you said, and notes are their own environment. `addNoteFromDictation`
    // stays on the store (still tested) so restoring the affordance is a view
    // change, but don't put it back without re-deciding what Today is *for*.

    private func delete(_ item: Transcript) {
        store.delete(item.id)
    }

    private func deleteMessage(for item: Transcript) -> String {
        item.source.isDocument
            ? "“\(item.menuTitle)” will be removed from Shhhcribble. A transcribed file's .txt sidecar isn't affected."
            : "This dictation will be removed from Shhhcribble. This can't be undone."
    }

}

// MARK: - Month popover

/// A month grid with a dot under every day that has something on it, so the way
/// to reach older work isn't clicking the back chevron until you find it.
private struct MonthPicker: View {
    let month: Date
    let selected: Date
    @ObservedObject var store: TranscriptStore
    var onPick: (Date) -> Void

    @State private var visibleMonth: Date

    private let calendar = Calendar.current

    init(month: Date, selected: Date, store: TranscriptStore, onPick: @escaping (Date) -> Void) {
        self.month = month
        self.selected = selected
        self.store = store
        self.onPick = onPick
        _visibleMonth = State(initialValue: month)
    }

    private var filled: Set<Int> {
        Timeline.daysWithContent(inMonthOf: visibleMonth,
                                 transcripts: store.transcripts,
                                 calendar: calendar)
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Previous month")
                Spacer()
                Text(monthTitle)
                    .font(.system(size: DesignSystem.ChromeText.control, weight: .medium))
                Spacer()
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Next month")
            }

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 2), count: 7), spacing: 2) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: DesignSystem.ChromeText.micro))
                        .foregroundStyle(.tertiary)
                }
                ForEach(Array(gridDays.enumerated()), id: \.offset) { _, date in
                    if let date { dayCell(date) } else { Color.clear.frame(height: 24) }
                }
            }

            Button("Jump to today") { onPick(calendar.startOfDay(for: Date())) }
                .buttonStyle(.borderless)
                .font(.system(size: DesignSystem.ChromeText.control))
        }
        .padding(12)
        .frame(width: 232)
    }

    private func dayCell(_ date: Date) -> some View {
        let dayNumber = calendar.component(.day, from: date)
        let isSelected = calendar.isDate(date, inSameDayAs: selected)
        let hasContent = filled.contains(dayNumber)
        // Inert for the same reason the forward chevron is dead on today: a
        // future day can only ever open empty.
        let isFuture = Timeline.isFutureDay(date, calendar: calendar)
        return Button { onPick(calendar.startOfDay(for: date)) } label: {
            VStack(spacing: 1) {
                Text("\(dayNumber)")
                    .font(.system(size: DesignSystem.ChromeText.secondary))
                    .foregroundStyle(isFuture ? Color.secondary.opacity(0.4)
                                     : (isSelected ? Color.primary : Color.secondary))
                Circle()
                    .fill(hasContent ? Color.secondary : Color.clear)
                    .frame(width: 3, height: 3)
            }
            .frame(width: 28, height: 24)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.radiusBadge, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(DesignSystem.fillActive) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
        .accessibilityLabel(accessibilityLabel(for: date, hasContent: hasContent))
    }

    private func accessibilityLabel(for date: Date, hasContent: Bool) -> String {
        let formatted = date.formatted(date: .long, time: .omitted)
        return hasContent ? "\(formatted), has entries" : formatted
    }

    private var monthTitle: String {
        let f = DateFormatter()
        f.calendar = calendar
        f.setLocalizedDateFormatFromTemplate("MMMM y")
        return f.string(from: visibleMonth)
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Leading blanks so the 1st sits under the right weekday, then the days.
    private var gridDays: [Date?] {
        guard let range = calendar.range(of: .day, in: .month, for: visibleMonth),
              let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: visibleMonth))
        else { return [] }
        let leading = (calendar.component(.weekday, from: firstOfMonth) - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading) + range.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: firstOfMonth)
        }
    }

    private func shiftMonth(_ months: Int) {
        if let shifted = calendar.date(byAdding: .month, value: months, to: visibleMonth) {
            visibleMonth = shifted
        }
    }
}
