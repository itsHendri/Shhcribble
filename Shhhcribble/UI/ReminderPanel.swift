import AppKit
import SwiftUI
import os

/// The task-reminder banner — a borderless, always-on-top **nonactivating**
/// floating NSPanel presented top-right when a task's due time arrives.
/// Direct descendant of `CallOfferPanel` (same lifecycle discipline, same
/// "our own banner, not a macOS notification" rationale — see that file).
///
/// Buttons: **Done** (completes the task) and **Snooze** (re-arms the reminder
/// 10 minutes out). The auto-dismiss timeout fires *neither* — the banner just
/// leaves; the menu-bar reminder tint stays as the durable signal until the
/// user acts somewhere.
@MainActor
final class ReminderPanel: NSPanel {

    private let model = ReminderModel()

    private var onDone: (() -> Void)?
    private var onSnooze: (() -> Void)?

    /// One cancellable slot for the deferred work — either the auto-dismiss
    /// timeout or the post-hide `orderOut` (see `CallOfferPanel.pendingWork`).
    private var pendingWork: DispatchWorkItem?

    private static let log = Logger(subsystem: "com.shhhcribble.app", category: "reminder")

    /// A bit longer than the call offer's 12 s — a reminder is the whole point
    /// of the moment, not an interruption of something else.
    private let autoDismissAfter: TimeInterval = 20

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 190),
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )

        level              = .floating
        backgroundColor    = .clear
        isOpaque           = false
        hasShadow          = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isMovableByWindowBackground = false
        alphaValue         = 1.0

        let content = FirstMouseHostingView(rootView: ReminderView(
            model: model,
            onDone:   { [weak self] in self?.done() },
            onSnooze: { [weak self] in self?.snooze() }
        ))
        content.frame = NSRect(x: 0, y: 0, width: 420, height: 190)
        contentView = content
    }

    override var canBecomeKey: Bool { true }

    // MARK: - Present / dismiss

    /// Present (or replace) the banner for a due task. `onDone` runs on the
    /// **Done** button, `onSnooze` on **Snooze**; the auto-dismiss timeout runs
    /// neither. At most one of them fires per presentation.
    func present(text: String, onDone: @escaping () -> Void, onSnooze: @escaping () -> Void) {
        pendingWork?.cancel()
        self.onDone   = onDone
        self.onSnooze = onSnooze

        positionAtTopTrailing()
        model.text      = text
        model.isVisible = false
        orderFront(nil)
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                self.model.isVisible = true
            }
        }
        scheduleAutoDismiss()
        Self.log.notice("Reminder banner shown")
    }

    /// Hide without firing either callback (e.g. the task got completed from
    /// another surface while the banner was up). Idempotent.
    func dismissSilently() {
        onDone = nil
        onSnooze = nil
        teardown()
    }

    // MARK: - Button / timeout paths

    private func done() {
        let cb = onDone
        onDone = nil; onSnooze = nil
        teardown()
        cb?()
    }

    private func snooze() {
        let cb = onSnooze
        onDone = nil; onSnooze = nil
        teardown()
        cb?()
    }

    private func timeoutDismiss() {
        onDone = nil; onSnooze = nil
        teardown()
    }

    private func scheduleAutoDismiss() {
        let item = DispatchWorkItem { [weak self] in self?.timeoutDismiss() }
        pendingWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + autoDismissAfter, execute: item)
    }

    private func teardown() {
        pendingWork?.cancel()

        withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
            model.isVisible = false
        }
        let item = DispatchWorkItem { [weak self] in
            self?.orderOut(nil)
            MainActor.assumeIsolated { self?.pendingWork = nil }
        }
        pendingWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    // MARK: - Positioning

    /// Top-right of the display under the pointer (matches `CallOfferPanel`).
    private func positionAtTopTrailing() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
                ?? NSScreen.main
                ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let panelWidth:  CGFloat = 420
        let panelHeight: CGFloat = 190
        let x = frame.maxX - panelWidth + 20
        let y = frame.maxY - panelHeight + 20
        setFrameOrigin(NSPoint(x: x, y: y))
        setContentSize(NSSize(width: panelWidth, height: panelHeight))
    }
}

// MARK: - View model + view

@MainActor
final class ReminderModel: ObservableObject {
    @Published var text: String = ""
    @Published var isVisible: Bool = false
}

private struct ReminderView: View {
    @ObservedObject var model: ReminderModel
    let onDone: () -> Void
    let onSnooze: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(Color.orange.opacity(0.18))
                    Image(systemName: "bell.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.orange)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Reminder")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(model.text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(action: onSnooze) {
                    Text("Snooze 10 min")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(width: 118)

                Button(action: onDone) {
                    Text("Done")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .frame(width: 88)
            }
        }
        .padding(14)
        .frame(width: 356, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 16, x: 0, y: 8)
        .scaleEffect(model.isVisible ? 1 : 0.92)
        .offset(y: model.isVisible ? 0 : -18)
        .opacity(model.isVisible ? 1 : 0)
        .padding(.top, 30)
        .frame(width: 420, height: 190, alignment: .top)
    }
}
