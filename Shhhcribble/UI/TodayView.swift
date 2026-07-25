import SwiftUI
import AppKit

/// The Today stream — **one timeline, two weights**, and the thing that replaced
/// the transcripts master-detail (redesign phase 4).
///
/// A dictation is high-frequency and semi-throwaway: you keep it to recover a
/// paste that missed or to re-use an old prompt. It never needed a reader, and
/// it never needed a list row that hides four fifths of it behind an ellipsis —
/// so dictations render as **borderless lines, always fully expanded**. Notes
/// and documents are things you deliberately kept, so they **anchor** the day as
/// bordered cards you can click through to.
///
/// The stream is scoped to one day. Chevrons step a day; the day label opens a
/// month popover with dots on the days that have anything, so finding older work
/// doesn't mean clicking backwards through empty days.
struct TodayView: View {
    @ObservedObject var store: TranscriptStore
    /// Opening an anchored card hands it back to the shell, which knows which
    /// tab that kind of item lives in.
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
    @State private var deleting: TimelineItem?
    @State private var copiedToast = false
    @State private var copiedToastTask: Task<Void, Never>?

    /// Whether the stream is on today. Asked of the calendar, never of the
    /// day *label* — that's user-facing text and will be localised.
    private var isShowingToday: Bool { Calendar.current.isDateInToday(shownDay) }

    /// The day being shown, falling back to today until the opening pick lands.
    private var shownDay: Date { day ?? Calendar.current.startOfDay(for: Date()) }

    private var items: [TimelineItem] {
        Timeline.items(on: shownDay, transcripts: store.transcripts, notes: store.notes)
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
        .overlay(alignment: .bottom) { copiedToastView }
        .onAppear {
            // Open on the last day that actually has something — a blank page on
            // a quiet morning is a worse first impression than yesterday's work.
            // `day` is the shell's, so this runs once per window, not per visit.
            guard day == nil else { return }
            day = Timeline.openingDay(around: Date(),
                                      transcripts: store.transcripts, notes: store.notes)
                ?? Calendar.current.startOfDay(for: Date())
        }
        // Follow new work to the day it landed on. Without this, dictating while
        // the stream sits on an older day (which is the *default* opening state
        // after a quiet couple of days, and what any window left open past
        // midnight becomes) puts the text in your editor and nowhere visible
        // here — the most likely confusion in the whole redesign.
        .onChange(of: store.transcripts.first?.id) { _, _ in
            guard let newest = store.transcripts.first else { return }
            let landed = Calendar.current.startOfDay(for: newest.createdAt)
            guard !Calendar.current.isDate(landed, inSameDayAs: shownDay) else { return }
            withAnimation(DesignSystem.motion(.easeOut(duration: DesignSystem.motionQuick))) {
                day = landed
                search = ""
            }
        }
        .onDisappear { copiedToastTask?.cancel() }
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

            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.borderless)
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

    private func row(_ item: TimelineItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            // Fixed width with a hard line limit: a 12-hour locale's "10:42 PM"
            // (and worse, "10:42 p. m.") wraps to two lines otherwise and ragged
            // the whole gutter.
            Text(item.occurredAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: DesignSystem.ChromeText.secondary))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 58, alignment: .trailing)
                .padding(.top, item.isAnchored ? 10 : 1)

            Group {
                switch item {
                case .transcript(let t) where !t.source.isDocument: dictationLine(t)
                case .transcript(let t):                            documentCard(t)
                case .note(let n):                                  noteCard(n)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onHover { hoveredID = $0 ? item.id : (hoveredID == item.id ? nil : hoveredID) }
    }

    /// A dictation passes through: no border, no truncation, the whole thing.
    private func dictationLine(_ t: Transcript) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t.text)
                .font(.system(size: DesignSystem.ChromeText.body))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            metaRow(for: .transcript(t)) {
                Text(wordCount(t.text))
                if let style = t.styleName, !style.isEmpty {
                    TagCapsule(style)
                }
            }
        }
    }

    /// A document anchors: bordered card, click to read it.
    private func documentCard(_ t: Transcript) -> some View {
        card(open: { onOpenTranscript(t.id) }) {
            HStack(spacing: 6) {
                Text(t.menuTitle)
                    .font(.system(size: DesignSystem.ChromeText.body, weight: .medium))
                    .lineLimit(1)
                TagCapsule("Document")
                if t.pinned { pinGlyph }
            }
            metaRow(for: .transcript(t)) {
                Text(documentSubtitle(t))
            }
        }
    }

    private func noteCard(_ n: Note) -> some View {
        card(open: { onOpenNote(n.id) }) {
            HStack(spacing: 6) {
                Text(NotesView.preview(n.text))
                    .font(.system(size: DesignSystem.ChromeText.body, weight: .medium))
                    .lineLimit(1)
                TagCapsule("Note")
                if n.stuck {
                    Image(systemName: "macwindow")
                        .font(.system(size: DesignSystem.ChromeText.micro))
                        .foregroundStyle(.tertiary)
                        .help("On your screen")
                } else if n.pinned {
                    pinGlyph
                }
            }
            metaRow(for: .note(n)) {
                Text(noteSubtitle(n))
                    .lineLimit(1)
            }
        }
    }

    private var pinGlyph: some View {
        Image(systemName: "pin.fill")
            .font(.system(size: DesignSystem.ChromeText.micro))
            .foregroundStyle(.tertiary)
            .help("Pinned")
    }

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

    /// The quiet line under an item: whatever it has to say about itself on the
    /// left, and the per-item actions on hover at the right.
    private func metaRow<Leading: View>(for item: TimelineItem,
                                        @ViewBuilder leading: () -> Leading) -> some View {
        HStack(spacing: 8) {
            leading()
                .font(.system(size: DesignSystem.ChromeText.secondary))
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            if hoveredID == item.id {
                actions(for: item)
            }
        }
        // Reserve the row's height so revealing the actions doesn't nudge the
        // stream — the same reason `TranscriptRow` fixes its trailing slot.
        .frame(height: 18)
    }

    @ViewBuilder
    private func actions(for item: TimelineItem) -> some View {
        HStack(spacing: 10) {
            Button { copy(item) } label: {
                Image(systemName: "doc.on.doc").foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)
            .help("Copy")
            .accessibilityLabel("Copy")

            // Only a dictation can be sent into a note — a note is already one,
            // and a document keeps its own reader.
            if case .transcript(let t) = item, !t.source.isDocument {
                Button { addToNote(t) } label: {
                    Image(systemName: "note.text.badge.plus").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Add to a new note")
                .accessibilityLabel("Add to a new note")
            }

            Button { deleting = item } label: {
                Image(systemName: "trash").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Delete")
            .accessibilityLabel("Delete")
        }
        .font(.system(size: DesignSystem.ChromeText.control))
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
            // Same reason, plus a previous year's label carries its year.
            Text(Timeline.dayLabel(for: result.date))
                .font(.system(size: DesignSystem.ChromeText.secondary))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 78, alignment: .trailing)
                .padding(.top, result.isAnchored ? 9 : 1)

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

            Button(action: onUpload) {
                Label("Upload Audio…", systemImage: "waveform.badge.plus")
                    .font(.callout).fontWeight(.medium)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.quaternary, lineWidth: 0.5))
                    .shadow(color: .black.opacity(DesignSystem.shadowSoft), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
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

    private func documentSubtitle(_ t: Transcript) -> String {
        var parts: [String] = [t.source.label]
        if let d = t.durationSec, d > 0 { parts.append(Transcript.durationString(d)) }
        if t.summary != nil { parts.append("summary ready") }
        return parts.joined(separator: " · ")
    }

    /// The line *under* a note card's title — what the note says next, not the
    /// title again.
    private func noteSubtitle(_ n: Note) -> String {
        let body = NotesView.bodyPreview(n.text)
        if !body.isEmpty { return body }
        return n.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Empty note" : "Note"
    }

    private func copy(_ item: TimelineItem) {
        let text: String
        switch item {
        case .transcript(let t): text = t.text
        case .note(let n):       text = n.text
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        copiedToastTask?.cancel()
        withAnimation(DesignSystem.motion(.spring(response: 0.3, dampingFraction: 0.8))) { copiedToast = true }
        copiedToastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            withAnimation(DesignSystem.motion(.easeOut(duration: DesignSystem.motionStandard))) { copiedToast = false }
        }
    }

    /// Send a dictation into a fresh note as an embedded block, and open it.
    /// Deliberately a *new* note: appending to "the current note" would mean
    /// guessing which one, and a wrong guess edits something the user didn't ask
    /// to touch.
    private func addToNote(_ t: Transcript) {
        let note = store.addNoteFromDictation(t)
        onOpenNote(note.id)
    }

    private func delete(_ item: TimelineItem) {
        switch item {
        case .transcript(let t): store.delete(t.id)
        case .note(let n):       store.deleteNote(id: n.id)
        }
    }

    private func deleteMessage(for item: TimelineItem) -> String {
        switch item {
        case .transcript(let t) where t.source.isDocument:
            return "“\(t.menuTitle)” will be removed from Shhhcribble. A transcribed file's .txt sidecar isn't affected."
        case .transcript:
            return "This dictation will be removed from Shhhcribble. This can't be undone."
        case .note(let n):
            return "“\(NotesView.preview(n.text))” will be removed. This can't be undone."
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
                .shadow(color: .black.opacity(DesignSystem.shadowSoft), radius: 8, y: 2)
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
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
                                 notes: store.notes,
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
        return Button { onPick(calendar.startOfDay(for: date)) } label: {
            VStack(spacing: 1) {
                Text("\(dayNumber)")
                    .font(.system(size: DesignSystem.ChromeText.secondary))
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
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
