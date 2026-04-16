import AppKit
import AVFoundation
import SwiftUI

/// A borderless, always-on-top floating NSPanel that hosts the soundwave animation.
/// It never steals keyboard focus (.nonactivatingPanel) and follows the user across
/// Spaces (.canJoinAllSpaces).
///
/// The panel is intentionally oversized (400×136) relative to the visible 320×56
/// content so the spring entry/exit animation can overshoot without being clipped
/// by the OS window boundary. The extra space is fully transparent.
///
/// Entry/exit animations are driven purely by SwiftUI (scale + offset + opacity spring),
/// so the NSPanel itself is always fully opaque — no NSAnimationContext needed.
final class SoundwavePanel: NSPanel {

    private let viewModel: SoundwaveViewModel

    /// Cancellable auto-hide work item (used by showCopied).
    private var pendingHide: DispatchWorkItem?

    /// Pre-loaded at init so play() fires with zero initialization latency.
    private let completionPlayer: AVAudioPlayer? = {
        guard let url = Bundle.main.url(forResource: "shhhcribble-scribble-sound",
                                        withExtension: "mp3"),
              let player = try? AVAudioPlayer(contentsOf: url)
        else {
            print("[Shhhcribble] ⚠️ completion sound not found in bundle — expected: shhhcribble-scribble-sound.mp3")
            return nil
        }
        player.enableRate = true
        player.rate       = 1.4
        player.volume     = 1.0
        player.prepareToPlay()   // pre-buffers audio so play() is instant
        return player
    }()

    init(viewModel: SoundwaveViewModel) {
        self.viewModel = viewModel

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 136),
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
        alphaValue         = 1.0   // SwiftUI controls visual opacity via isVisible

        let content = NSHostingView(rootView: SoundwaveView(viewModel: viewModel))
        content.frame = NSRect(x: 0, y: 0, width: 400, height: 136)
        contentView = content
    }

    // MARK: - Show / update / hide

    func show() {
        pendingHide?.cancel()
        pendingHide = nil

        positionAtTopCenter()
        viewModel.state    = .recording
        viewModel.liveText = ""
        viewModel.isVisible = false   // start collapsed so the spring has somewhere to come from

        orderFront(nil)

        // Kick off entry on next runloop tick so SwiftUI renders the initial collapsed state first
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                self.viewModel.isVisible = true
            }
        }
    }

    func showTranscribing() {
        withAnimation(.easeInOut(duration: 0.35)) {
            viewModel.state    = .transcribing
            viewModel.liveText = ""
        }
    }

    func showCopied() {
        pendingHide?.cancel()

        // Play first — player is pre-buffered so this fires with no latency
        completionPlayer?.currentTime = 0
        completionPlayer?.play()

        withAnimation(.easeInOut(duration: 0.35)) {
            viewModel.state    = .copied
            viewModel.liveText = ""
        }

        let item = DispatchWorkItem { [weak self] in self?.hide() }
        pendingHide = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: item)
    }

    /// Show a transient error message in the pill (e.g. "No microphone detected").
    /// Presents the panel if hidden, then auto-hides after 2s.
    func showError(_ message: String) {
        pendingHide?.cancel()

        // If the panel isn't on screen yet, bring it in with the same spring entry
        // used by show() so the error is visible even when recording never started.
        if !viewModel.isVisible {
            positionAtTopCenter()
            viewModel.isVisible = false
            orderFront(nil)
            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                    self.viewModel.isVisible = true
                }
            }
        }

        withAnimation(.easeInOut(duration: 0.25)) {
            viewModel.state    = .error(message)
            viewModel.liveText = ""
        }

        let item = DispatchWorkItem { [weak self] in self?.hide() }
        pendingHide = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: item)
    }

    func updateLevel(_ level: Float) {
        viewModel.audioLevel = Double(level)
    }

    /// Update the live transcription text shown while recording.
    func updateLiveText(_ text: String) {
        viewModel.liveText = text
    }

    func hide() {
        pendingHide?.cancel()
        pendingHide = nil

        // Exit animation: spring back up and shrink — reverse of entry
        withAnimation(.spring(response: 0.4, dampingFraction: 0.88)) {
            viewModel.isVisible = false
        }

        // Remove the window after the spring has settled
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.orderOut(nil)
            MainActor.assumeIsolated {
                self?.viewModel.state     = .hidden
                self?.viewModel.liveText  = ""
                self?.viewModel.audioLevel = 0
            }
        }
    }

    // MARK: - Positioning

    private func positionAtTopCenter() {
        guard let screen = NSScreen.main else { return }
        let screenFrame  = screen.visibleFrame
        let panelWidth:  CGFloat = 400
        let panelHeight: CGFloat = 136
        // Center horizontally; position so the visible 320×56 pill sits 8pts below the
        // top of the visible area (same apparent position as before the panel was enlarged).
        // The 40pts of transparent padding above the content push the panel frame upward.
        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.maxY - panelHeight + 40
        setFrameOrigin(NSPoint(x: x, y: y))
        setContentSize(NSSize(width: panelWidth, height: panelHeight))
    }
}
