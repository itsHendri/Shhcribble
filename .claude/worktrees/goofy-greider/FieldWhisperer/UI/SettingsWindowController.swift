import AppKit
import SwiftUI

/// Hosts the SwiftUI SettingsView in a regular titled window.
final class SettingsWindowController: NSWindowController {

    convenience init(transcriptionEngine: TranscriptionEngine, appDelegate: AppDelegate) {
        let rootView  = SettingsView(transcriptionEngine: transcriptionEngine, appDelegate: appDelegate)
        let hostingVC = NSHostingController(rootView: rootView)

        let window = NSWindow(contentViewController: hostingVC)
        window.title      = "FieldWhisperer Settings"
        window.styleMask  = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 440, height: 600))
        window.center()

        self.init(window: window)
    }
}
