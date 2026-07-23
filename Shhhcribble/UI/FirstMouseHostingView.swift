import AppKit
import SwiftUI

/// Hosting view that reports `acceptsFirstMouse`, so a click landing on a
/// floating panel while another app is frontmost is delivered as a real
/// button/control click instead of being swallowed to merely focus the panel.
/// Shared by every nonactivating panel with interactive content
/// (`CallOfferPanel`, `ReminderPanel`, `StickyNotePanel`).
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
