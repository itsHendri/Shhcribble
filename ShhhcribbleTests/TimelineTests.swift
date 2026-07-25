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

    private func note(_ at: String, text: String = "a note") -> Note {
        Note(createdAt: date(at), modifiedAt: date(at), text: text)
    }

    // MARK: - Bucketing

    func testItemsOnlyIncludesThatDay() {
        let transcripts = [transcript("2026-07-24 09:00"),
                           transcript("2026-07-25 09:00"),
                           transcript("2026-07-26 09:00")]
        let items = Timeline.items(on: date("2026-07-25 13:00"),
                                   transcripts: transcripts, notes: [], calendar: calendar)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.occurredAt, date("2026-07-25 09:00"))
    }

    /// A dictation at 23:59 belongs to that day, not the next one — the classic
    /// off-by-one when a "day" is computed as a 24-hour offset from now.
    func testLateNightItemStaysOnItsOwnDay() {
        let late = transcript("2026-07-25 23:59")
        XCTAssertEqual(Timeline.items(on: date("2026-07-25 00:30"),
                                      transcripts: [late], notes: [], calendar: calendar).count, 1)
        XCTAssertTrue(Timeline.items(on: date("2026-07-26 12:00"),
                                     transcripts: [late], notes: [], calendar: calendar).isEmpty)
    }

    func testItemsMergesNotesAndTranscriptsNewestFirst() {
        let items = Timeline.items(
            on: date("2026-07-25 12:00"),
            transcripts: [transcript("2026-07-25 09:00", text: "early"),
                          transcript("2026-07-25 18:00", text: "late")],
            notes: [note("2026-07-25 14:00", text: "middle")],
            calendar: calendar)

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.map(\.occurredAt), [date("2026-07-25 18:00"),
                                                 date("2026-07-25 14:00"),
                                                 date("2026-07-25 09:00")])
    }

    /// Equal timestamps must produce a stable order, or `ForEach` identity
    /// churns between renders. Two items minted in the same second is ordinary.
    func testEqualTimestampsOrderStably() {
        let a = transcript("2026-07-25 10:00", text: "a")
        let b = transcript("2026-07-25 10:00", text: "b")
        let first = Timeline.items(on: date("2026-07-25 10:00"),
                                   transcripts: [a, b], notes: [], calendar: calendar)
        let second = Timeline.items(on: date("2026-07-25 10:00"),
                                    transcripts: [b, a], notes: [], calendar: calendar)
        XCTAssertEqual(first.map(\.id), second.map(\.id))
    }

    // MARK: - Weight

    /// The "two weights" claim, encoded: only a quick dictation passes through.
    func testOnlyDictationsAreUnanchored() {
        XCTAssertFalse(TimelineItem.transcript(transcript("2026-07-25 10:00", source: .dictation)).isAnchored)
        XCTAssertTrue(TimelineItem.transcript(transcript("2026-07-25 10:00", source: .file)).isAnchored)
        XCTAssertTrue(TimelineItem.transcript(transcript("2026-07-25 10:00", source: .call)).isAnchored)
        XCTAssertTrue(TimelineItem.note(note("2026-07-25 10:00")).isAnchored)
    }

    func testTypeLabelIsAbsentForDictations() {
        XCTAssertNil(TimelineItem.transcript(transcript("2026-07-25 10:00", source: .dictation)).typeLabel)
        XCTAssertEqual(TimelineItem.transcript(transcript("2026-07-25 10:00", source: .call)).typeLabel, "Document")
        XCTAssertEqual(TimelineItem.note(note("2026-07-25 10:00")).typeLabel, "Note")
    }

    // MARK: - Month dots

    func testDaysWithContentCoversBothKindsAndIgnoresOtherMonths() {
        let days = Timeline.daysWithContent(
            inMonthOf: date("2026-07-15 12:00"),
            transcripts: [transcript("2026-07-03 10:00"), transcript("2026-06-30 10:00")],
            notes: [note("2026-07-28 10:00"), note("2026-08-01 10:00")],
            calendar: calendar)
        XCTAssertEqual(days, [3, 28])
    }

    func testDaysWithContentIsEmptyForAQuietMonth() {
        XCTAssertTrue(Timeline.daysWithContent(inMonthOf: date("2026-02-10 12:00"),
                                               transcripts: [transcript("2026-07-03 10:00")],
                                               notes: [], calendar: calendar).isEmpty)
    }

    // MARK: - Opening day

    func testMostRecentDayWithContentSkipsQuietDays() {
        let day = Timeline.mostRecentDayWithContent(
            atOrBefore: date("2026-07-25 09:00"),
            transcripts: [transcript("2026-07-22 16:00")],
            notes: [note("2026-07-20 10:00")],
            calendar: calendar)
        XCTAssertEqual(day, calendar.startOfDay(for: date("2026-07-22 16:00")))
    }

    /// Something dated later today still counts as "at or before" — the cutoff
    /// is the end of the day, not the instant we asked.
    func testMostRecentDayIncludesLaterTheSameDay() {
        let day = Timeline.mostRecentDayWithContent(
            atOrBefore: date("2026-07-25 09:00"),
            transcripts: [transcript("2026-07-25 18:00")],
            notes: [], calendar: calendar)
        XCTAssertEqual(day, calendar.startOfDay(for: date("2026-07-25 00:00")))
    }

    func testMostRecentDayIgnoresFutureDays() {
        XCTAssertNil(Timeline.mostRecentDayWithContent(
            atOrBefore: date("2026-07-25 09:00"),
            transcripts: [transcript("2026-07-27 10:00")],
            notes: [], calendar: calendar))
    }

    func testMostRecentDayIsNilForAnEmptyLibrary() {
        XCTAssertNil(Timeline.mostRecentDayWithContent(
            atOrBefore: date("2026-07-25 09:00"),
            transcripts: [], notes: [], calendar: calendar))
    }

    /// A library stamped entirely in the future (clock skew, an import dated
    /// ahead) must not open on an empty today and tell the user to start
    /// speaking — it opens on the soonest day that has something.
    func testOpeningDayFallsForwardWhenEverythingIsInTheFuture() {
        let day = Timeline.openingDay(
            around: date("2026-07-25 09:00"),
            transcripts: [transcript("2026-07-30 10:00"), transcript("2026-07-27 10:00")],
            notes: [], calendar: calendar)
        XCTAssertEqual(day, calendar.startOfDay(for: date("2026-07-27 00:00")))
    }

    func testOpeningDayPrefersThePastWhenThereIsAny() {
        let day = Timeline.openingDay(
            around: date("2026-07-25 09:00"),
            transcripts: [transcript("2026-07-30 10:00"), transcript("2026-07-22 10:00")],
            notes: [], calendar: calendar)
        XCTAssertEqual(day, calendar.startOfDay(for: date("2026-07-22 00:00")))
    }

    func testOpeningDayIsNilOnlyForAnEmptyLibrary() {
        XCTAssertNil(Timeline.openingDay(around: date("2026-07-25 09:00"),
                                         transcripts: [], notes: [], calendar: calendar))
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
