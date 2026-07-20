import AppKit
import AVFoundation
import SwiftUI
import os

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

    /// Diagnostics — tail with:
    /// `log stream --predicate 'subsystem == "com.shhhcribble.app"'`
    private static let log = Logger(subsystem: "com.shhhcribble.app", category: "sound")

    /// Cancellable work item for any *deferred* panel mutation — the showCopied/
    /// showNoResult/showError auto-hide AND hide()'s deferred orderOut. Storing
    /// the orderOut here (rather than a raw asyncAfter) lets any re-present path
    /// cancel it, so a stale orderOut can't yank a freshly shown pill off-screen.
    private var pendingHide: DispatchWorkItem?

    /// Pre-loaded at init so play() fires with zero initialization latency.
    private let completionPlayer: AVAudioPlayer? = {
        guard let url = Bundle.main.url(forResource: "shhhcribble-scribble-sound",
                                        withExtension: "mp3"),
              let player = try? AVAudioPlayer(contentsOf: url)
        else {
            SoundwavePanel.log.error("Completion sound not found in bundle — expected: shhhcribble-scribble-sound.mp3")
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

    /// Present the recording pill — the "go" signal. Called from `onReady`, i.e.
    /// once the input route is physically live, so on a cold Bluetooth route the
    /// pill simply appears later; its absence is the "not ready" state.
    /// `representIfHidden()` runs the entry spring on first presentation.
    func showRecording() {
        pendingHide?.cancel()
        pendingHide = nil

        representIfHidden()

        withAnimation(.easeInOut(duration: 0.2)) {
            viewModel.state    = .recording
            viewModel.liveText = ""
        }
    }

    func playCompletionSound() {
        guard let player = completionPlayer else {
            Self.log.error("Completion sound skipped — player unavailable (resource missing at init).")
            return
        }
        player.currentTime = 0
        // play() returns false on a start/prepare failure. Logging the result
        // distinguishes "never started" from "started but inaudible" (the latter
        // points at the output route switching mid-playback — see the
        // completion-sound decision in CLAUDE.md / the live-diagnosis path).
        if player.play() {
            Self.log.notice("Completion sound play() started.")
        } else {
            Self.log.error("Completion sound play() returned false — not audible.")
        }
    }

    /// Transition the (already-visible) recording pill into a persistent
    /// "Transcribing…" state while the final transcribe + optional on-device AI
    /// cleanup run. Deliberately schedules NO auto-hide — it stays up until
    /// showCopied / showNoResult / showError replaces it once work finishes, so
    /// the user always sees that something is happening rather than a premature
    /// "Copied!". See AppDelegate.endRecording.
    func showTranscribing() {
        pendingHide?.cancel()
        pendingHide = nil

        // Re-present if the panel isn't on screen (e.g. a cold-AirPods quick
        // tap-stop reached here before show()'s entry ran) so the spinner is
        // never mutated into an off-screen window. Same recovery as showError.
        representIfHidden()

        withAnimation(.easeInOut(duration: 0.3)) {
            viewModel.state    = .transcribing
            viewModel.liveText = ""
        }
    }

    func showCopied() {
        pendingHide?.cancel()

        representIfHidden()

        withAnimation(.easeInOut(duration: 0.35)) {
            viewModel.state    = .copied
            viewModel.liveText = ""
        }

        scheduleHide(after: 1.0)
    }

    /// Bring the panel back on screen with the spring entry if it isn't visible.
    /// No-op when already visible. Used by every `show*` recovery path so a
    /// state mutation never lands on an off-screen window.
    private func representIfHidden() {
        guard !viewModel.isVisible else { return }
        positionAtTopCenter()
        viewModel.isVisible = false
        orderFront(nil)
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                self.viewModel.isVisible = true
            }
        }
    }

    /// Schedule the auto-hide as a cancellable item so a re-present cancels it.
    private func scheduleHide(after seconds: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in self?.hide() }
        pendingHide = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// Replace the persistent `.transcribing` pill with a neutral "No speech
    /// detected" acknowledgement when the final transcript came back empty.
    /// Re-presents the panel if it was hidden, then auto-hides.
    func showNoResult() {
        pendingHide?.cancel()

        representIfHidden()

        withAnimation(.easeInOut(duration: 0.25)) {
            viewModel.state    = .noResult
            viewModel.liveText = ""
        }

        scheduleHide(after: 1.0)
    }


    /// Present a transient neutral informational message near the cursor — e.g.
    /// "Getting ready…" when the hotkey is pressed before the model has finished
    /// loading, so the user sees why nothing happened instead of only a menu-bar
    /// tint. Re-presents if hidden, then auto-hides.
    func showInfo(_ message: String) {
        pendingHide?.cancel()

        representIfHidden()

        withAnimation(.easeInOut(duration: 0.25)) {
            viewModel.state    = .info(message)
            viewModel.liveText = ""
        }

        scheduleHide(after: 1.6)
    }

    /// Show a transient error message in the pill (e.g. "No microphone detected").
    /// Presents the panel if hidden, then auto-hides after 2s.
    func showError(_ message: String) {
        pendingHide?.cancel()

        // Bring the panel in (if needed) so the error is visible even when
        // recording never started.
        representIfHidden()

        withAnimation(.easeInOut(duration: 0.25)) {
            viewModel.state    = .error(message)
            viewModel.liveText = ""
        }

        scheduleHide(after: 1.6)
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

        // Exit animation: spring back up and shrink — reverse of entry
        withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
            viewModel.isVisible = false
        }

        // Remove the window after the spring settles — but store the work item
        // in pendingHide (cancellable) rather than firing a raw asyncAfter. A
        // re-present within this 0.3s window (show / showTranscribing /
        // showCopied / showNoResult / showError all call pendingHide?.cancel())
        // cancels it; otherwise a stale orderOut would yank a freshly shown pill
        // off-screen and reset state to .hidden — the open/close glitch.
        let item = DispatchWorkItem { [weak self] in
            self?.orderOut(nil)
            MainActor.assumeIsolated {
                self?.viewModel.state      = .hidden
                self?.viewModel.liveText   = ""
                self?.viewModel.audioLevel = 0
                self?.pendingHide          = nil
            }
        }
        pendingHide = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    // MARK: - Positioning

    private func positionAtTopCenter() {
        // Prefer the display the user is actually working on — the one under the
        // pointer — then NSScreen.main, then any screen. Only bail if there are
        // literally no displays (headless), which can't happen while a user is
        // dictating into a focused field. NSScreen.main alone put the pill on the
        // wrong monitor when the key-window display wasn't where the user was typing.
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
                ?? NSScreen.main
                ?? NSScreen.screens.first else { return }
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
