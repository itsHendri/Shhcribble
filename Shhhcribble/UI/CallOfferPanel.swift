import AppKit
import SwiftUI
import os

/// A borderless, always-on-top **nonactivating** floating NSPanel that offers to
/// transcribe a detected call. Presented top-right — where a macOS notification
/// banner would appear.
///
/// **Why our own panel instead of `UNUserNotificationCenter`:** the OS
/// notification path is unreliable on some machines (a broken Notification
/// Center database silently drops every third-party registration, so the banner
/// never shows and no permission is ever requested) and it adds a TCC permission
/// prompt. An in-app banner works everywhere, needs no permission, and keeps the
/// offer entirely under our control. A `.nonactivatingPanel` still receives its
/// buttons' clicks without stealing focus from the call app — exactly what an
/// unobtrusive offer wants.
///
/// The panel is oversized (380×132) relative to the visible ~356×108 content so
/// the spring entry/exit can overshoot without clipping; the extra space is
/// transparent. Mirrors the lifecycle discipline of `SoundwavePanel`.
@MainActor
final class CallOfferPanel: NSPanel {

    private let model = CallOfferModel()

    private var onAccept: (() -> Void)?
    private var onDismiss: (() -> Void)?

    /// One cancellable slot for the *deferred* work — either the auto-dismiss
    /// timeout or the post-hide `orderOut`. A fresh `present()` cancels whatever
    /// is pending so a stale `orderOut` can't yank a just-shown banner off screen
    /// (same failure `SoundwavePanel.pendingHide` guards against).
    private var pendingWork: DispatchWorkItem?

    /// App name of the offer currently on screen, or nil when nothing is showing.
    /// Read by the menu bar to build the "Transcribe <App> Call" fallback item.
    private(set) var pendingAppName: String?

    private static let log = Logger(subsystem: "com.shhhcribble.app", category: "call")

    /// Long enough to notice and act on; short enough not to linger after the
    /// moment has passed. The menu-bar item remains a persistent way to accept.
    private let autoDismissAfter: TimeInterval = 12

    init() {
        super.init(
            // Oversized vs. the visible ~356-wide card so the card's drop shadow
            // and the spring-entry overshoot have transparent room on every side
            // (otherwise the shadow clips against the panel edge).
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

        // A `FirstMouseHostingView` so the Transcribe/Dismiss buttons fire on the
        // FIRST click even though the app is a background agent and this panel is
        // nonactivating — otherwise the initial click would only bring the window
        // forward and the user would have to click twice.
        let content = FirstMouseHostingView(rootView: CallOfferView(
            model: model,
            onAccept:  { [weak self] in self?.accept() },
            onDismiss: { [weak self] in self?.userDismiss() }
        ))
        content.frame = NSRect(x: 0, y: 0, width: 420, height: 190)
        contentView = content
    }

    /// A nonactivating panel must opt in to becoming key so its buttons receive
    /// clicks without activating the app.
    override var canBecomeKey: Bool { true }

    // MARK: - Present / dismiss

    /// Present (or replace) the offer for `appName`. `onAccept` runs when the
    /// user clicks **Transcribe**; `onDismiss` runs on the **Dismiss** button or
    /// the auto-dismiss timeout. Exactly one of them fires per presentation.
    func present(appName: String,
                 onAccept: @escaping () -> Void,
                 onDismiss: @escaping () -> Void) {
        pendingWork?.cancel()
        self.onAccept  = onAccept
        self.onDismiss = onDismiss
        pendingAppName = appName

        positionAtTopTrailing()
        model.appName   = appName
        model.isVisible = false
        orderFront(nil)
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                self.model.isVisible = true
            }
        }
        scheduleAutoDismiss()
        Self.log.notice("Call offer shown for \(appName, privacy: .public)")
    }

    /// Dismiss the current offer **without** firing either callback — used when
    /// the offer is honoured or cancelled through another surface (the menu-bar
    /// item accepted it, or the app got busy). Idempotent.
    func dismissSilently() {
        onAccept  = nil
        onDismiss = nil
        teardown()
    }

    // MARK: - Button / timeout paths

    private func accept() {
        let cb = onAccept
        onAccept = nil; onDismiss = nil
        teardown()
        cb?()
    }

    private func userDismiss() {
        let cb = onDismiss
        onAccept = nil; onDismiss = nil
        teardown()
        cb?()
    }

    private func timeoutDismiss() {
        let cb = onDismiss
        onAccept = nil; onDismiss = nil
        teardown()
        cb?()
    }

    private func scheduleAutoDismiss() {
        let item = DispatchWorkItem { [weak self] in self?.timeoutDismiss() }
        pendingWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + autoDismissAfter, execute: item)
    }

    /// Spring the banner out, then remove the window once it settles. The
    /// `orderOut` lives in `pendingWork` so a re-`present()` within the 0.3 s
    /// window cancels it.
    private func teardown() {
        pendingWork?.cancel()
        pendingAppName = nil

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

    /// Top-right of the display under the pointer (where a macOS banner shows).
    private func positionAtTopTrailing() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
                ?? NSScreen.main
                ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let panelWidth:  CGFloat = 420
        let panelHeight: CGFloat = 190
        // The visible card is centered in the wider panel (32pt transparent
        // margin each side) and sits 30pt below the panel top; the +20 offsets
        // land the apparent banner ~12pt from the right edge and ~10pt below the
        // top of the visible area.
        let x = frame.maxX - panelWidth + 20
        let y = frame.maxY - panelHeight + 20
        setFrameOrigin(NSPoint(x: x, y: y))
        setContentSize(NSSize(width: panelWidth, height: panelHeight))
    }
}

// (FirstMouseHostingView moved to its own file — it's now shared with
// ReminderPanel and StickyNotePanel.)

// MARK: - View model + view

@MainActor
final class CallOfferModel: ObservableObject {
    @Published var appName: String = ""
    @Published var isVisible: Bool = false
}

private struct CallOfferView: View {
    @ObservedObject var model: CallOfferModel
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.18))
                    Image(systemName: "phone.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Call detected — \(model.appName)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("Transcribe your side? It stays on your Mac.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Text("Dismiss")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(width: 96)

                Button(action: onAccept) {
                    Text("Transcribe")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .frame(width: 110)
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
        // Transparent room on every side (30pt top for the entry overshoot +
        // shadow; the 420-wide frame centers the 356 card with 32pt margins).
        .padding(.top, 30)
        .frame(width: 420, height: 190, alignment: .top)
    }
}
