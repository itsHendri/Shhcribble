import AppKit
import SwiftUI

/// Hosts the SwiftUI TranscriptionsView in a resizable window. Mirrors
/// SettingsWindowController. Opened from the menu-bar "Transcriptions…" item
/// and auto-focused when a file transcription completes.
final class TranscriptionsWindowController: NSWindowController {

    convenience init(store: TranscriptStore,
                     fileTranscriber: FileTranscriber,
                     engine: TranscriptionEngine,
                     appDelegate: AppDelegate,
                     onTranscribeFile: @escaping () -> Void,
                     onQuit: @escaping () -> Void) {
        let root = TranscriptionsView(
            store: store,
            fileTranscriber: fileTranscriber,
            engine: engine,
            appDelegate: appDelegate,
            onTranscribeFile: onTranscribeFile,
            onQuit: onQuit
        )
        let hostingVC = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hostingVC)
        window.title = "Shhhcribble"
        // Hide the centered native title and show a custom leading label so the
        // menu-bar icon can sit directly in front of the app name.
        window.titleVisibility = .hidden
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Floor the size so the sidebar + list + reader always fit — below this
        // the split columns overflow and clip. Autosave name is bumped (.v2) so a
        // stale small frame saved under the old 3-column layout isn't restored.
        window.contentMinSize = NSSize(width: 840, height: 520)
        window.setContentSize(NSSize(width: 1000, height: 640))
        window.setFrameAutosaveName("TranscriptionsWindow.v2")
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
