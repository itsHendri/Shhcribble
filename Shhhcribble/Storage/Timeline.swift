import Foundation

/// One thing that happened, on the Today stream.
///
/// The redesign's core claim is "**one timeline, two weights**": notes and
/// documents *anchor* the day as bordered cards, while dictations *pass through*
/// as borderless lines. That's a rendering difference, not a data one — so the
/// timeline is a single ordered list and the weight is a property of the item.
enum TimelineItem: Identifiable, Equatable {
    case transcript(Transcript)
    case note(Note)

    var id: UUID {
        switch self {
        case .transcript(let t): return t.id
        case .note(let n):       return n.id
        }
    }

    /// When it landed — what the stream sorts by.
    var occurredAt: Date {
        switch self {
        case .transcript(let t): return t.createdAt
        case .note(let n):       return n.createdAt
        }
    }

    /// Anchored items get a card; passing items get a line. A quick dictation is
    /// the only passing weight — everything you deliberately kept anchors.
    var isAnchored: Bool {
        switch self {
        case .transcript(let t): return t.source.isDocument
        case .note:              return true
        }
    }

    /// The type pill on an anchored card. `nil` for passing items, which carry
    /// no pill (a dictation doesn't need to announce itself as a dictation).
    var typeLabel: String? {
        switch self {
        case .transcript(let t): return t.source.isDocument ? "Document" : nil
        case .note:              return "Note"
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

    /// Everything that happened on `day`, newest first.
    ///
    /// Newest-first matches the rest of the app (the lists, the menu's recents)
    /// and puts what you just dictated where you're already looking.
    static func items(on day: Date,
                      transcripts: [Transcript],
                      notes: [Note],
                      calendar: Calendar = .current) -> [TimelineItem] {
        let merged = transcripts.map(TimelineItem.transcript) + notes.map(TimelineItem.note)
        return merged
            .filter { calendar.isDate($0.occurredAt, inSameDayAs: day) }
            // Tie-break on id so equal timestamps can't reorder between renders
            // and churn `ForEach` identity — same reason as `pinnedNotes`.
            .sorted { ($0.occurredAt, $0.id.uuidString) > ($1.occurredAt, $1.id.uuidString) }
    }

    /// The days in `month` that have anything on them — the dots in the month
    /// popover, so stepping through empty days isn't the only way to find out
    /// where your work is.
    static func daysWithContent(inMonthOf month: Date,
                                transcripts: [Transcript],
                                notes: [Note],
                                calendar: Calendar = .current) -> Set<Int> {
        let stamps = transcripts.map(\.createdAt) + notes.map(\.createdAt)
        var days: Set<Int> = []
        for stamp in stamps where calendar.isDate(stamp, equalTo: month, toGranularity: .month) {
            days.insert(calendar.component(.day, from: stamp))
        }
        return days
    }

    /// The most recent day that has anything on it, at or before `day` — what
    /// the stream opens on so a first visit isn't a blank page on a quiet
    /// morning. `nil` when the library is empty (a genuine empty state) or when
    /// everything is in the future.
    static func mostRecentDayWithContent(atOrBefore day: Date,
                                         transcripts: [Transcript],
                                         notes: [Note],
                                         calendar: Calendar = .current) -> Date? {
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day))
            ?? day
        let stamps = (transcripts.map(\.createdAt) + notes.map(\.createdAt))
            .filter { $0 < endOfDay }
        guard let latest = stamps.max() else { return nil }
        return calendar.startOfDay(for: latest)
    }

    /// Step one day. Separate from the view so "what does the chevron do" is a
    /// tested question rather than an inline `date(byAdding:)`.
    static func day(_ day: Date, steppedBy days: Int, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: day))
            ?? day
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
