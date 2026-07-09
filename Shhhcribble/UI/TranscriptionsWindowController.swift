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
        // Shared between the titlebar bar (which owns the sidebar-toggle button)
        // and the SwiftUI content (which owns the split view).
        let chrome = TranscriptionsChrome()

        let root = TranscriptionsView(
            store: store,
            fileTranscriber: fileTranscriber,
            engine: engine,
            appDelegate: appDelegate,
            chrome: chrome,
            onTranscribeFile: onTranscribeFile,
            onQuit: onQuit
        )
        let hostingVC = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hostingVC)
        // Blank the native title; the branded icon+name is drawn by the titlebar
        // bar below, so a non-empty window title would show a second one.
        window.title = ""
        window.titleVisibility = .hidden
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        // Floor the size so the sidebar + list + reader always fit — below this
        // the split columns overflow and clip. Autosave name is bumped (.v2) so a
        // stale small frame saved under the old 3-column layout isn't restored.
        window.contentMinSize = NSSize(width: 840, height: 520)
        window.setContentSize(NSSize(width: 1000, height: 640))
        window.setFrameAutosaveName("TranscriptionsWindow.v2")
        window.center()

        // Leading titlebar bar: the (contained) sidebar-toggle button followed by
        // the branded icon+name on the plain titlebar background. Hosting both in
        // one leading accessory guarantees the order — menu button first, title
        // second — which mixing a toolbar item with an accessory does not.
        let titleAccessory = NSTitlebarAccessoryViewController()
        titleAccessory.layoutAttribute = .leading
        // Span the full titlebar width so the branded title can center across it
        // (a content-width accessory would only center within its own small box).
        let host = NSHostingView(rootView: TitlebarBar(chrome: chrome))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 30)
        titleAccessory.view = host
        window.addTitlebarAccessoryViewController(titleAccessory)

        self.init(window: window)
    }
}

/// Shared chrome state: the titlebar toggle lives in an AppKit-hosted accessory,
/// separate from the SwiftUI content that owns the `NavigationSplitView`, so they
/// coordinate the sidebar through this one published flag.
final class TranscriptionsChrome: ObservableObject {
    @Published var sidebarCollapsed = false
}

/// Leading titlebar bar: a contained sidebar-toggle button, then the menu-bar
/// icon and app name on the plain titlebar background.
private struct TitlebarBar: View {
    @ObservedObject var chrome: TranscriptionsChrome

    var body: some View {
        ZStack {
            // Branded title centered across the whole titlebar.
            HStack(spacing: 6) {
                icon
                Text("Shhhcribble").font(.system(size: 13, weight: .semibold))
            }
            .frame(maxWidth: .infinity, alignment: .center)

            // Sidebar toggle pinned to the leading edge, tucked up against the
            // window's traffic-light controls.
            toggle
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, 2)
        .padding(.trailing, 10)
    }

    /// Sidebar toggle as an explicit glass lozenge — `.regularMaterial` in a
    /// rounded rect with a hairline stroke, matching the app's other glass
    /// affordances (the "Upload Audio…" lozenge, the Copied toast). The system
    /// `.buttonStyle(.glass)` renders too faintly for a lone titlebar icon to
    /// read as a button, so we draw the material ourselves for a consistent look
    /// on every supported OS.
    @ViewBuilder private var toggle: some View {
        Button {
            chrome.sidebarCollapsed.toggle()
        } label: {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 23)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(.quaternary, lineWidth: 0.5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show or hide the sidebar")
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
