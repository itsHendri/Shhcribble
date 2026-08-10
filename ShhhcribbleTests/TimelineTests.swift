import XCTest
@testable import Shhhcribble

/// Tests for the Today stream's pure day logic. Every case pins a fixed
/// timezone and calendar, because the whole point of this type is answering
/// "which day did that land on" — a question that is wrong by an hour twice a
/// year if you let the machine's zone decide.
final class TimelineTests: XCTestCase {

    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        c.firstWeekday = 2   // Monday, so the grid maths is deterministic
        return c
    }()

    private func date(_ iso: String) -> Date {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: iso)!
    }

    private func transcript(_ at: String, source: TranscriptSource = .dictation,
                            text: String = "body") -> Transcript {
        Transcript(id: UUID(), createdAt: date(at), source: source,
                   title: text, text: text, rawText: text)
    }

    // MARK: - Bucketing

    func testItemsOnlyIncludesThatDay() {
        let transcripts = [transcript("2026-07-24 09:00"),
                           transcript("2026-07-25 09:00"),
                           transcript("2026-07-26 09:00")]
        let items = Timeline.items(on: date("2026-07-25 13:00"),
                                   transcripts: transcripts, calendar: calendar)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.createdAt, date("2026-07-25 09:00"))
    }

    /// A dictation at 23:59 belongs to that day, not the next one — the classic
    /// off-by-one when a "day" is computed as a 24-hour offset from now.
    func testLateNightItemStaysOnItsOwnDay() {
        let late = transcript("2026-07-25 23:59")
        XCTAssertEqual(Timeline.items(on: date("2026-07-25 00:30"),
                                      transcripts: [late], calendar: calendar).count, 1)
        XCTAssertTrue(Timeline.items(on: date("2026-07-26 12:00"),
                                     transcripts: [late], calendar: calendar).isEmpty)
    }

    /// Dictations and documents share one stream, newest first. **Notes do
    /// not appear at all** — Today is transcriptions only (2026-08-10), and
    /// this is the test that fails if they are ever merged back in by accident.
    func testItemsMergesDictationsAndDocumentsNewestFirstAndExcludesNotes() {
        let items = Timeline.items(
            on: date("2026-07-25 12:00"),
            transcripts: [transcript("2026-07-25 09:00", text: "early"),
                          transcript("2026-07-25 14:00", source: .file, text: "middle"),
                          transcript("2026-07-25 18:00", text: "late")],
            calendar: calendar)

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.map { $0.createdAt }, [date("2026-07-25 18:00"),
                                                    date("2026-07-25 14:00"),
                                                    date("2026-07-25 09:00")])
        XCTAssertEqual(items.map { $0.text }, ["late", "middle", "early"])
    }

    /// Equal timestamps must produce a stable order, or `ForEach` identity
    /// churns between renders. Two items minted in the same second is ordinary.
    func testEqualTimestampsOrderStably() {
        let a = transcript("2026-07-25 10:00", text: "a")
        let b = transcript("2026-07-25 10:00", text: "b")
        let first = Timeline.items(on: date("2026-07-25 10:00"),
                                   transcripts: [a, b], calendar: calendar)
        let second = Timeline.items(on: date("2026-07-25 10:00"),
                                    transcripts: [b, a], calendar: calendar)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    // MARK: - Weight

    /// The "two weights" claim, encoded: only a quick dictation passes through.
    func testOnlyDictationsAreUnanchored() {
        XCTAssertFalse(transcript("2026-07-25 10:00", source: .dictation).isAnchored)
        XCTAssertTrue(transcript("2026-07-25 10:00", source: .file).isAnchored)
        XCTAssertTrue(transcript("2026-07-25 10:00", source: .call).isAnchored)
    }

    func testTypeLabelIsAbsentForDictations() {
        XCTAssertNil(transcript("2026-07-25 10:00", source: .dictation).typeLabel)
        XCTAssertEqual(transcript("2026-07-25 10:00", source: .call).typeLabel, "Document")
        XCTAssertEqual(transcript("2026-07-25 10:00", source: .file).typeLabel, "Document")
    }

    // MARK: - Month dots

    /// The dots have to agree with the stream: a day is "filled" only when a
    /// *transcript* landed on it. A note-only day used to light a dot and then
    /// open on an empty page.
    func testDaysWithContentIgnoresOtherMonths() {
        let days = Timeline.daysWithContent(
            inMonthOf: date("2026-07-15 12:00"),
            transcripts: [transcript("2026-07-03 10:00"), transcript("2026-06-30 10:00"),
                          transcript("2026-07-28 10:00"), transcript("2026-08-01 10:00")],
            calendar: calendar)
        XCTAssertEqual(days, [3, 28])
    }

    func testDaysWithContentIsEmptyForAQuietMonth() {
        XCTAssertTrue(Timeline.daysWithContent(inMonthOf: date("2026-02-10 12:00"),
                                               transcripts: [transcript("2026-07-03 10:00")],
                                                calendar: calendar).isEmpty)
    }

    // MARK: - Opening day

    func testMostRecentDayWithContentSkipsQuietDays() {
        let day = Timeline.mostRecentDayWithContent(
            atOrBefore: date("2026-07-25 09:00"),
            transcripts: [transcript("2026-07-22 16:00"), transcript("2026-07-20 10:00")],
            calendar: calendar)
        XCTAssertEqual(day, calendar.startOfDay(for: date("2026-07-22 16:00")))
    }

    /// Something dated later today still counts as "at or before" — the cutoff
    /// is the end of the day, not the instant we asked.
    func testMostRecentDayIncludesLaterTheSameDay() {
        let day = Timeline.mostRecentDayWithContent(
            atOrBefore: date("2026-07-25 09:00"),
            transcripts: [transcript("2026-07-25 18:00")],
             calendar: calendar)
        XCTAssertEqual(day, calendar.startOfDay(for: date("2026-07-25 00:00")))
    }

    func testMostRecentDayIgnoresFutureDays() {
        XCTAssertNil(Timeline.mostRecentDayWithContent(
            atOrBefore: date("2026-07-25 09:00"),
            transcripts: [transcript("2026-07-27 10:00")],
             calendar: calendar))
    }

    func testMostRecentDayIsNilForAnEmptyLibrary() {
        XCTAssertNil(Timeline.mostRecentDayWithContent(
            atOrBefore: date("2026-07-25 09:00"),
            transcripts: [], calendar: calendar))
    }

    /// A library stamped entirely in the future (clock skew, an import dated
    /// ahead) must not open on an empty today and tell the user to start
    /// speaking — it opens on the soonest day that has something.
    func testOpeningDayFallsForwardWhenEverythingIsInTheFuture() {
        let day = Timeline.openingDay(
            around: date("2026-07-25 09:00"),
            transcripts: [transcript("2026-07-30 10:00"), transcript("2026-07-27 10:00")],
             calendar: calendar)
        XCTAssertEqual(day, calendar.startOfDay(for: date("2026-07-27 00:00")))
    }

    func testOpeningDayPrefersThePastWhenThereIsAny() {
        let day = Timeline.openingDay(
            around: date("2026-07-25 09:00"),
            transcripts: [transcript("2026-07-30 10:00"), transcript("2026-07-22 10:00")],
             calendar: calendar)
        XCTAssertEqual(day, calendar.startOfDay(for: date("2026-07-22 00:00")))
    }

    func testOpeningDayIsNilOnlyForAnEmptyLibrary() {
        XCTAssertNil(Timeline.openingDay(around: date("2026-07-25 09:00"),
                                         transcripts: [], calendar: calendar))
    }

    // MARK: - Recency groups (the list headings)

    /// "This week" is the calendar's week, not the last seven days — on a
    /// Wednesday, something from six days ago is *last* week, and filing it
    /// under "Earlier this week" is the kind of small lie that makes a list feel
    /// untrustworthy. 2026-07-25 is a Saturday; the week started Monday the 20th.
    func testRecencyGroupUsesTheCalendarWeekNotSevenDays() {
        let now = date("2026-07-25 12:00")
        XCTAssertEqual(Timeline.recencyGroup(for: date("2026-07-20 09:00"), now: now, calendar: calendar),
                       .earlierThisWeek)
        XCTAssertEqual(Timeline.recencyGroup(for: date("2026-07-19 09:00"), now: now, calendar: calendar),
                       .earlierThisMonth, "the 19th is last week, six days back or not")
    }

    func testRecencyGroupCoversEveryStep() {
        let now = date("2026-07-25 12:00")
        XCTAssertEqual(Timeline.recencyGroup(for: date("2026-07-25 08:00"), now: now, calendar: calendar), .today)
        XCTAssertEqual(Timeline.recencyGroup(for: date("2026-07-24 08:00"), now: now, calendar: calendar), .yesterday)
        XCTAssertEqual(Timeline.recencyGroup(for: date("2026-07-22 08:00"), now: now, calendar: calendar), .earlierThisWeek)
        XCTAssertEqual(Timeline.recencyGroup(for: date("2026-07-06 08:00"), now: now, calendar: calendar), .earlierThisMonth)
        XCTAssertEqual(Timeline.recencyGroup(for: date("2026-05-06 08:00"), now: now, calendar: calendar), .older)
    }

    /// A future-stamped item under "Older" would be plainly wrong.
    func testFutureDatesGroupWithToday() {
        XCTAssertEqual(Timeline.recencyGroup(for: date("2026-08-30 08:00"),
                                             now: date("2026-07-25 12:00"), calendar: calendar), .today)
    }

    func testGroupedDropsEmptyGroupsAndKeepsNewestFirst() {
        let now = date("2026-07-25 12:00")
        let dates = [date("2026-07-25 09:00"), date("2026-07-22 09:00"), date("2026-01-02 09:00")]
        let groups = Timeline.grouped(dates, by: { $0 }, now: now, calendar: calendar)

        XCTAssertEqual(groups.map(\.group), [.today, .earlierThisWeek, .older])
        XCTAssertEqual(groups.map(\.items.count), [1, 1, 1])
    }

    func testGroupedPreservesTheOrderItWasGiven() {
        let now = date("2026-07-25 12:00")
        let first = date("2026-07-25 18:00")
        let second = date("2026-07-25 09:00")
        let groups = Timeline.grouped([first, second], by: { $0 }, now: now, calendar: calendar)
        XCTAssertEqual(groups.first?.items, [first, second], "grouping must not re-sort")
    }

    func testGroupedIsEmptyForNoItems() {
        XCTAssertTrue(Timeline.grouped([Date](), by: { $0 }, now: date("2026-07-25 12:00"),
                                       calendar: calendar).isEmpty)
    }

    // MARK: - Stepping and labelling

    func testSteppingMovesWholeDaysFromTheStartOfTheDay() {
        let stepped = Timeline.day(date("2026-07-25 17:30"), steppedBy: -1, calendar: calendar)
        XCTAssertEqual(stepped, calendar.startOfDay(for: date("2026-07-24 00:00")))
    }

    /// Stepping across a DST boundary must still land on the neighbouring day.
    /// The UK springs forward on 2026-03-29, so a naive 86_400-second offset
    /// would land back on the 29th.
    func testSteppingAcrossDaylightSavingLandsOnTheNextDay() {
        let stepped = Timeline.day(date("2026-03-29 12:00"), steppedBy: 1, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: stepped), 30)
    }

    func testDayLabelNamesTodayAndYesterday() {
        let now = date("2026-07-25 12:00")
        XCTAssertEqual(Timeline.dayLabel(for: date("2026-07-25 08:00"), now: now, calendar: calendar), "Today")
        XCTAssertEqual(Timeline.dayLabel(for: date("2026-07-24 08:00"), now: now, calendar: calendar), "Yesterday")
    }

    func testDayLabelFallsBackToADateForOlderDays() {
        let label = Timeline.dayLabel(for: date("2026-07-20 08:00"),
                                      now: date("2026-07-25 12:00"), calendar: calendar)
        XCTAssertNotEqual(label, "Today")
        XCTAssertNotEqual(label, "Yesterday")
        XCTAssertTrue(label.contains("20"), "expected the day number in \(label)")
    }
}
