import AppKit
import SwiftUI

/// Hosts the SwiftUI TranscriptionsView in a resizable window. Mirrors
/// SettingsWindowController. Opened from the menu-bar "Transcriptions…" item
/// and auto-focused when a file transcription completes.
final class TranscriptionsWindowController: NSWindowController {

    convenience init(store: TranscriptStore,
                     fileTranscriber: FileTranscriber,
                     engine: TranscriptionEngine,
                     onTranscribeFile: @escaping () -> Void,
                     onOpenSettings: @escaping () -> Void,
                     onQuit: @escaping () -> Void) {
        let root = TranscriptionsView(
            store: store,
            fileTranscriber: fileTranscriber,
            engine: engine,
            onTranscribeFile: onTranscribeFile,
            onOpenSettings: onOpenSettings,
            onQuit: onQuit
        )
        let hostingVC = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hostingVC)
        window.title = "Shhhcribble"
        // Hide the centered native title and show a custom leading label so the
        // menu-bar icon can sit directly in front of the app name.
        window.titleVisibility = .hidden
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 900, height: 560))
        window.setFrameAutosaveName("TranscriptionsWindow")
        window.center()

        let titleAccessory = NSTitlebarAccessoryViewController()
        titleAccessory.layoutAttribute = .leading
        let host = NSHostingView(rootView: TitlebarLabel())
        host.frame = NSRect(x: 0, y: 0, width: 140, height: 22)
        titleAccessory.view = host
        window.addTitlebarAccessoryViewController(titleAccessory)

        self.init(window: window)
    }
}

/// Leading titlebar content: the menu-bar icon followed by the app name.
private struct TitlebarLabel: View {
    var body: some View {
        HStack(spacing: 6) {
            icon
            Text("Shhhcribble").font(.system(size: 13, weight: .medium))
        }
        .padding(.leading, 8)
    }

    @ViewBuilder private var icon: some View {
        if let img = NSImage(named: "MenuBarIcon") {
            Image(nsImage: img)
                .renderingMode(.template)
                .resizable()
                .frame(width: 15, height: 15)
                .foregroundStyle(.primary)
        } else {
            Image(systemName: "mic.fill").font(.system(size: 12))
        }
    }
}
