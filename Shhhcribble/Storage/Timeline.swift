import Foundation

extension Transcript {
    /// Anchored items get a card on the Today stream; passing items get a line.
    ///
    /// "**One timeline, two weights**" survives Today becoming
    /// transcriptions-only (2026-08-10) — it just now runs along the line the
    /// app already draws internally: a **document** is long-form material you
    /// keep, so it anchors, while a **dictation** passes through. That's a
    /// rendering difference, not a data one.
    var isAnchored: Bool { source.isDocument }

    /// The type pill on an anchored card. `nil` for a dictation, which doesn't
    /// need to announce itself as one.
    var typeLabel: String? { source.isDocument ? "Document" : nil }
}

/// How recently something happened, coarsened into the headings a list uses.
///
/// A list of fifty notes sorted by date reads as one undifferentiated column;
/// these headings are what turn it back into "this week" and "a while ago".
enum RecencyGroup: String, CaseIterable, Identifiable {
    case today, yesterday, earlierThisWeek, earlierThisMonth, older

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today:            return "Today"
        case .yesterday:        return "Yesterday"
        case .earlierThisWeek:  return "Earlier this week"
        case .earlierThisMonth: return "Earlier this month"
        case .older:            return "Older"
        }
    }
}

/// Pure day-bucketing for the Today stream. Kept out of the view so the parts
/// that are easy to get wrong — which day an item lands on, what order a day
/// reads in, which days are worth offering in the month popover — are testable
/// without a window.
///
/// Every date question goes through an injected `Calendar` so tests can pin a
/// timezone; the app passes `.current`, which is what makes "today" mean the
/// user's today rather than UTC's.
enum Timeline {

    /// Everything dictated on `day`, newest first.
    ///
    /// **Dictations only** (Hendri, 2026-08-28). Notes left the stream in
    /// 2026-08-10 — Today is the record of what you *said*, a note is something
    /// you *wrote* — and documents left it now, for the neighbouring reason:
    /// an import or a call is long-form material you *keep*, so it lives on the
    /// shelf with the notes rather than passing through the day. What's left is
    /// one honest thing, which is why the tab is called Dictations.
    ///
    /// This is the single predicate the whole pane hangs off: every day question
    /// below filters identically, so the month dots, the opening day and the
    /// stream can never disagree. A dot over a day that opens empty is exactly
    /// the bug the notes exclusion fixed; don't reintroduce it by filtering in
    /// only one of these.
    ///
    /// Newest-first matches the rest of the app (the lists, the menu's recents)
    /// and puts what you just dictated where you're already looking.
    static func items(on day: Date,
                      transcripts: [Transcript],
                      calendar: Calendar = .current) -> [Transcript] {
        streamable(transcripts)
            .filter { calendar.isDate($0.createdAt, inSameDayAs: day) }
            // Tie-break on id so equal timestamps can't reorder between renders
            // and churn `ForEach` identity.
            .sorted { ($0.createdAt, $0.id.uuidString) > ($1.createdAt, $1.id.uuidString) }
    }

    /// What the stream is made of — see `items(on:)`. Every day question here
    /// goes through this, so there is one place to change if documents ever
    /// come back.
    private static func streamable(_ transcripts: [Transcript]) -> [Transcript] {
        transcripts.filter { !$0.source.isDocument }
    }

    /// The days in `month` that have anything on them — the dots in the month
    /// popover, so stepping through empty days isn't the only way to find out
    /// where your work is.
    static func daysWithContent(inMonthOf month: Date,
                                transcripts: [Transcript],
                                calendar: Calendar = .current) -> Set<Int> {
        let stamps = streamable(transcripts).map(\.createdAt)
        var days: Set<Int> = []
        for stamp in stamps where calendar.isDate(stamp, equalTo: month, toGranularity: .month) {
            days.insert(calendar.component(.day, from: stamp))
        }
        return days
    }

    /// The day the stream should open on: the most recent day with anything on
    /// it, or — if everything in the library is somehow in the future (clock
    /// skew, an import stamped ahead) — the soonest day that does. `nil` only
    /// for a genuinely empty library, which is a real empty state.
    ///
    /// Without the future fallback, a library full of future-stamped items
    /// opens on an empty today and tells the user to start speaking.
    static func openingDay(around now: Date,
                           transcripts: [Transcript],
                           calendar: Calendar = .current) -> Date? {
        if let past = mostRecentDayWithContent(atOrBefore: now, transcripts: transcripts,
                                               calendar: calendar) {
            return past
        }
        let stamps = streamable(transcripts).map(\.createdAt)
        guard let soonest = stamps.min() else { return nil }
        return calendar.startOfDay(for: soonest)
    }

    /// The most recent day that has anything on it, at or before `day` — what
    /// the stream opens on so a first visit isn't a blank page on a quiet
    /// morning. `nil` when the library is empty (a genuine empty state) or when
    /// everything is in the future.
    static func mostRecentDayWithContent(atOrBefore day: Date,
                                         transcripts: [Transcript],
                                         calendar: Calendar = .current) -> Date? {
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
            ?? day
        let stamps = streamable(transcripts).map(\.createdAt).filter { $0 < endOfDay }
        guard let latest = stamps.max() else { return nil }
        return calendar.startOfDay(for: latest)
    }

    /// Which heading a date belongs under.
    ///
    /// "This week" means the calendar's own week, not the last seven days — on a
    /// Tuesday, something from six days ago is *last* week, and calling it "this
    /// week" is the kind of small lie that makes a list feel untrustworthy.
    static func recencyGroup(for date: Date, now: Date = Date(),
                             calendar: Calendar = .current) -> RecencyGroup {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        if calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        // Future dates sit with today rather than under "Older", which would be
        // plainly wrong for anything stamped ahead.
        if date > now { return .today }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return .earlierThisWeek }
        if calendar.isDate(date, equalTo: now, toGranularity: .month) { return .earlierThisMonth }
        return .older
    }

    /// Split `items` into their headings, newest group first, dropping the
    /// groups that would be empty. Generic over the item so the notes list and
    /// the documents list share one implementation and one set of tests.
    static func grouped<Item>(_ items: [Item],
                              by date: (Item) -> Date,
                              now: Date = Date(),
                              calendar: Calendar = .current) -> [(group: RecencyGroup, items: [Item])] {
        var buckets: [RecencyGroup: [Item]] = [:]
        for item in items {
            buckets[recencyGroup(for: date(item), now: now, calendar: calendar), default: []].append(item)
        }
        // `allCases` is declared newest-first, so this is the display order.
        return RecencyGroup.allCases.compactMap { group in
            guard let items = buckets[group], !items.isEmpty else { return nil }
            return (group, items)
        }
    }

    /// Step one day. Separate from the view so "what does the chevron do" is a
    /// tested question rather than an inline `date(byAdding:)`.
    static func day(_ day: Date, steppedBy days: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: day))
            ?? day
    }

    /// Whether the forward chevron has anywhere to go.
    ///
    /// You cannot dictate into the future, so a forward step from today can only
    /// ever land on an empty day — an enabled control whose only outcome is a
    /// blank page (Hendri, 2026-08-28). A day *ahead* of today also returns
    /// false: if clock skew or an import stamped ahead ever puts the stream
    /// there, the way out is backwards.
    static func canStepForward(from day: Date, now: Date = Date(),
                               calendar: Calendar = .current) -> Bool {
        calendar.startOfDay(for: day) < calendar.startOfDay(for: now)
    }

    /// Whether a day sits after today — the month popover greys these out for
    /// the same reason the chevron stops.
    static func isFutureDay(_ day: Date, now: Date = Date(),
                            calendar: Calendar = .current) -> Bool {
        calendar.startOfDay(for: day) > calendar.startOfDay(for: now)
    }

    /// Label for the day header: "Today" / "Yesterday" for the two days that
    /// have names, an explicit date otherwise. A stream scoped to one day has to
    /// say which day, and "Today" reads better than the date when it *is* today.
    static func dayLabel(for day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        if calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        // Year only when it isn't the current one — "Fri 24 Jul" beats
        // "Fri 24 Jul 2026" for the 99% case.
        formatter.setLocalizedDateFormatFromTemplate(
            calendar.isDate(day, equalTo: now, toGranularity: .year) ? "EEE d MMM" : "EEE d MMM y"
        )
        return formatter.string(from: day)
    }
}
