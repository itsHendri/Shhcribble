import XCTest
@testable import Shhhcribble

/// Pure-logic tests for the reminder fire/skip rules (`ReminderPlanner`) —
/// the decision core of `ReminderScheduler`, tested without timers or a store.
final class ReminderPlannerTests: XCTestCase {

    private func task(text: String = "t",
                      due: TimeInterval?,
                      done: Bool = false,
                      fired: TimeInterval? = nil,
                      isTask: Bool = true) -> Note {
        var n = Note(text: text)
        n.isTask = isTask
        n.done = done
        n.dueAt = due.map { Date(timeIntervalSince1970: $0) }
        n.reminderFiredAt = fired.map { Date(timeIntervalSince1970: $0) }
        return n
    }

    private let now = Date(timeIntervalSince1970: 1_000)

    // MARK: - dueNotes

    func testDueNotesIncludesOverdueArmedTasks() {
        let notes = [task(due: 900), task(due: 1_000)]   // past and exactly-now
        XCTAssertEqual(ReminderPlanner.dueNotes(in: notes, asOf: now).count, 2)
    }

    func testDueNotesSkipsFutureDoneFiredAndNonTasks() {
        let notes = [
            task(due: 1_100),                 // future — not yet
            task(due: 900, done: true),       // completed
            task(due: 900, fired: 950),       // already fired for this dueAt
            task(due: 900, isTask: false),    // a plain note can't remind
            task(due: nil),                   // no due time
        ]
        XCTAssertTrue(ReminderPlanner.dueNotes(in: notes, asOf: now).isEmpty)
    }

    func testDueNotesOrdersEarliestFirst() {
        let notes = [task(text: "b", due: 950), task(text: "a", due: 900)]
        XCTAssertEqual(ReminderPlanner.dueNotes(in: notes, asOf: now).map { $0.text }, ["a", "b"])
    }

    // MARK: - nextFireDate

    func testNextFireDatePicksEarliestFuture() {
        let notes = [task(due: 2_000), task(due: 1_500), task(due: 900)]   // 900 is past
        XCTAssertEqual(ReminderPlanner.nextFireDate(in: notes, after: now),
                       Date(timeIntervalSince1970: 1_500))
    }

    func testNextFireDateIgnoresDoneAndFired() {
        let notes = [
            task(due: 1_500, done: true),
            task(due: 1_600, fired: 800),   // fired for its current dueAt
            task(due: 1_700),
        ]
        XCTAssertEqual(ReminderPlanner.nextFireDate(in: notes, after: now),
                       Date(timeIntervalSince1970: 1_700))
    }

    func testNextFireDateNilWhenNothingScheduled() {
        XCTAssertNil(ReminderPlanner.nextFireDate(in: [task(due: 900)], after: now))   // only past
        XCTAssertNil(ReminderPlanner.nextFireDate(in: [], after: now))
    }

    // MARK: - Snooze

    func testSnoozeDateIsTenMinutesOut() {
        XCTAssertEqual(ReminderPlanner.snoozeDate(from: now),
                       now.addingTimeInterval(10 * 60))
    }

    // MARK: - Armed-reminder invariant (drives both queries)

    func testHasArmedReminder() {
        XCTAssertTrue(task(due: 900).hasArmedReminder)
        XCTAssertFalse(task(due: nil).hasArmedReminder)
        XCTAssertFalse(task(due: 900, done: true).hasArmedReminder)
        XCTAssertFalse(task(due: 900, fired: 950).hasArmedReminder)
        XCTAssertFalse(task(due: 900, isTask: false).hasArmedReminder)
    }
}
