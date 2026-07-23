import AppKit
import Combine

/// Pure decision logic for task reminders — extracted from the scheduler so
/// the fire/skip rules are unit-testable without timers or a store.
enum ReminderPlanner {

    /// Notes whose reminder should fire now: armed (a not-done task with a due
    /// time that hasn't fired for its current `dueAt`) and due at/before `now`.
    /// Earliest-due first. When several are overdue at once the banner ends up
    /// showing the last one presented (present replaces) — all are still marked
    /// fired; the banner is a best-effort surface and the menu-bar tint is the
    /// durable "something needs attention" signal.
    static func dueNotes(in notes: [Note], asOf now: Date) -> [Note] {
        notes
            .filter { $0.hasArmedReminder && ($0.dueAt ?? .distantFuture) <= now }
            .sorted { ($0.dueAt ?? .distantPast) < ($1.dueAt ?? .distantPast) }
    }

    /// The earliest strictly-future fire time among armed reminders, or nil
    /// when nothing is scheduled.
    static func nextFireDate(in notes: [Note], after now: Date) -> Date? {
        notes
            .compactMap { $0.hasArmedReminder ? $0.dueAt : nil }
            .filter { $0 > now }
            .min()
    }

    /// The Snooze button's re-arm interval.
    static let snoozeInterval: TimeInterval = 10 * 60

    static func snoozeDate(from now: Date = Date()) -> Date {
        now.addingTimeInterval(snoozeInterval)
    }
}

/// Fires task reminders while the app runs (which, for a menu-bar app, is
/// always). **Deliberately not `UNUserNotificationCenter`** — the OS
/// notification path silently fails on machines with a broken Notification
/// Center database (the reason `CallOfferPanel` exists) and adds a permission
/// prompt; an in-process timer + in-app banner needs neither.
///
/// One `Timer` armed for the earliest upcoming `dueAt`; re-armed whenever the
/// store's notes change and on wake from sleep (a timer sleeps with the
/// machine, so a reminder that came due mid-sleep fires on wake). Firing marks
/// the note (`reminderFiredAt`) *before* invoking `onFire`, so a relaunch or a
/// re-entrant rearm can't double-fire the same `dueAt`; Snooze clears the mark
/// with a fresh due time.
@MainActor
final class ReminderScheduler {

    private let store: TranscriptStore
    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var wakeObserver: NSObjectProtocol?

    /// Called once per firing reminder (already marked fired in the store).
    /// AppDelegate presents the banner + menu-bar tint here. Taken at init —
    /// `rearm()` runs before init returns (anything overdue at launch fires
    /// immediately), so a set-after-init property would drop those.
    private let onFire: (Note) -> Void

    init(store: TranscriptStore, onFire: @escaping (Note) -> Void) {
        self.store = store
        self.onFire = onFire

        // Re-arm on any notes change. `@Published` emits on willSet — the
        // store's array is not yet updated when the sink runs — so hop to the
        // next runloop tick before reading `store.notes`, or an overdue note
        // marked fired during this very rearm would be seen unmarked and fire
        // twice.
        store.$notes
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.rearm() }
            }
            .store(in: &cancellables)

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.rearm() }
        }

        // Anything already overdue at launch fires once, now.
        rearm()
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        timer?.invalidate()
    }

    /// Fire everything due, then arm one timer for the next upcoming due time.
    /// Idempotent — safe to call from any trigger (store change, wake, timer).
    func rearm() {
        timer?.invalidate()
        timer = nil

        let now = Date()
        for note in ReminderPlanner.dueNotes(in: store.notes, asOf: now) {
            store.markNoteReminderFired(id: note.id, at: now)
            onFire(note)
        }

        guard let next = ReminderPlanner.nextFireDate(in: store.notes, after: now) else { return }
        let t = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.rearm() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}
