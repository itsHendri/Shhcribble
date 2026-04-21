import AppKit
import SwiftUI

/// Hosts the OnboardingView in a fixed-size centered window. Brings the app
/// forward (dock + activate) because onboarding is a foreground experience,
/// unlike the rest of Shhhcribble which is menu-bar-only.
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {

    private let transcriptionEngine: TranscriptionEngine
    private let onFinish: () -> Void

    init(transcriptionEngine: TranscriptionEngine, onFinish: @escaping () -> Void) {
        self.transcriptionEngine = transcriptionEngine
        self.onFinish = onFinish

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)

        window.delegate = self
        window.contentView = NSHostingView(rootView:
            OnboardingView(transcriptionEngine: transcriptionEngine) { [weak self] in
                self?.finish()
            }
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        ModelManager.hasCompletedOnboarding = true
        close()
        onFinish()
    }

    func windowWillClose(_ notification: Notification) {
        // Reverting to accessory hides the Dock icon again; menu bar remains.
        NSApp.setActivationPolicy(.accessory)
    }
}
