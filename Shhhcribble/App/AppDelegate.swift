import AppKit
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var hotKeyMonitor: HotKeyMonitor!
    private var audioRecorder: AudioRecorder!
    private var transcriptionEngine: TranscriptionEngine!
    private var textInserter: TextInserter!
    private var soundwavePanel: SoundwavePanel!
    private var menuBarController: MenuBarController!
    private var settingsWindowController: SettingsWindowController?
    private let musicPauser = MusicPauser()

    /// Internal recording state machine. `.transcribing` is a brief window
    /// between hotkey release and transcription completion — never surfaced in
    /// the pill (the UI flips optimistically to `.copied` on release); its
    /// only job is to block hotkey re-entry while the engine is still working.
    private enum AppState { case idle, recording, transcribing }
    private var state: AppState = .idle

    /// Hybrid activation: a press shorter than `tapThreshold` latches recording
    /// on (stop with a second tap); a longer press behaves as push-to-talk
    /// (release stops). `pressStartedAt` is the keyDown timestamp for the
    /// currently-held press; `latched` is set on the keyUp that converted the
    /// press into a tap.
    private var pressStartedAt: Date?
    private var latched: Bool = false
    private static let tapThreshold: TimeInterval = 0.25

    // Live transcription: runs Parakeet on the growing buffer every N seconds
    private var liveTranscriptionTask: Task<Void, Never>?
    private let liveTranscriptionInterval: TimeInterval = 3.0

    /// Global keyDown observer that catches Escape while recording so the user
    /// can cancel without pasting. Only active during .recording state.
    private var escapeMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[Shhhcribble] App launched.")

        let axTrusted = requestAccessibilityPermission()
        print("[Shhhcribble] AXIsProcessTrusted = \(axTrusted)")

        transcriptionEngine = TranscriptionEngine()
        audioRecorder       = AudioRecorder()
        textInserter        = TextInserter()

        let soundwaveViewModel = SoundwaveViewModel()
        soundwavePanel = SoundwavePanel(viewModel: soundwaveViewModel)

        menuBarController = MenuBarController(
            transcriptionEngine: transcriptionEngine,
            delegate: self
        )

        Task {
            await transcriptionEngine.loadModel(variant: ModelManager.selectedModel)
            menuBarController.rebuildMenu()
        }

        let hotkey = ModelManager.selectedHotkey
        hotKeyMonitor = HotKeyMonitor(
            onKeyDown: { [weak self] in
                guard let self else { return }
                switch self.state {
                case .recording where self.latched:
                    self.latched = false
                    self.pressStartedAt = nil
                    await self.endRecording()
                case .idle:
                    self.pressStartedAt = Date()
                    self.latched = false
                    await self.beginRecording()
                default:
                    break
                }
            },
            onKeyUp: { [weak self] in
                guard let self else { return }
                guard self.state == .recording, !self.latched else { return }
                let elapsed = self.pressStartedAt.map { Date().timeIntervalSince($0) } ?? .infinity
                if elapsed < Self.tapThreshold {
                    self.latched = true
                } else {
                    self.pressStartedAt = nil
                    await self.endRecording()
                }
            }
        )
        hotKeyMonitor.start(keyCode: hotkey.keyCode, modifiers: hotkey.modifiers)
    }

    /// Defensive resume if the user quits mid-recording — otherwise music
    /// we paused stays paused with no obvious way to discover why.
    func applicationWillTerminate(_ notification: Notification) {
        musicPauser.resumeIfPaused()
    }

    // MARK: - Recording state machine

    private func beginRecording() async {
        guard state == .idle else { return }
        guard transcriptionEngine.isReady else {
            print("[Shhhcribble] Model not ready: \(transcriptionEngine.statusText)")
            menuBarController.flashNotReady()
            return
        }

        // Resolve mic permission BEFORE showing the soundwave panel. On a
        // fresh install the system prompt is async and blocks audio capture
        // while visible — showing the "recording" panel during the prompt
        // would mislead the user into speaking into a dead mic. The fast
        // path (already authorized) is a synchronous status check so there's
        // no added latency after first launch.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            actuallyBeginRecording()

        case .notDetermined:
            // First-ever recording on this install. Surface the prompt and
            // only continue if the user grants access. The state == .idle
            // re-check after the prompt protects against the user pressing
            // the hotkey again mid-prompt.
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                print("[Shhhcribble] Microphone permission denied at prompt.")
                soundwavePanel.showError("Microphone permission denied")
                return
            }
            guard state == .idle else { return }
            actuallyBeginRecording()

        case .denied, .restricted:
            print("[Shhhcribble] Microphone permission already denied.")
            soundwavePanel.showError("Microphone permission denied")

        @unknown default:
            soundwavePanel.showError("Microphone permission unknown")
        }
    }

    /// Actual start sequence once mic permission is confirmed. Split out from
    /// beginRecording() so the panel and recorder only kick off after the
    /// permission prompt resolves on fresh installs.
    private func actuallyBeginRecording() {
        print("[Shhhcribble] Recording started")
        state = .recording
        if ModelManager.pauseMusicEnabled {
            musicPauser.pauseIfPlaying()
        }
        soundwavePanel.show()
        menuBarController.setRecordingIndicator(active: true)
        audioRecorder.start(
            levelCallback: { [weak self] level in
                self?.soundwavePanel.updateLevel(level)
            },
            onError: { [weak self] message in
                self?.handleAudioError(message)
            }
        )
        startLiveTranscription()
        startEscapeMonitor()
    }

    /// Cancels the current recording: stops audio, discards samples, hides the
    /// panel, and returns to idle without pasting anything.
    private func cancelRecording() {
        guard state == .recording else { return }
        print("[Shhhcribble] Recording cancelled (Escape)")
        stopLiveTranscription()
        stopEscapeMonitor()
        _ = audioRecorder.stop()
        musicPauser.resumeIfPaused()
        menuBarController.setRecordingIndicator(active: false)
        soundwavePanel.hide()
        state = .idle
    }

    private func startEscapeMonitor() {
        stopEscapeMonitor()
        // Escape keyCode = 53. A global monitor fires for events delivered to
        // other apps, letting us observe Escape while the nonactivating panel
        // can't receive key events itself.
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.cancelRecording() }
        }
    }

    private func stopEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }

    /// Called from AudioRecorder when setup fails (no mic, permission denied, etc.)
    /// Abort the current recording attempt cleanly and surface the error in the pill.
    private func handleAudioError(_ message: String) {
        print("[Shhhcribble] Audio error: \(message)")
        stopLiveTranscription()
        stopEscapeMonitor()
        _ = audioRecorder.stop()
        musicPauser.resumeIfPaused()
        menuBarController.setRecordingIndicator(active: false)
        soundwavePanel.showError(message)
        state = .idle
        latched = false
        pressStartedAt = nil
    }

    private func endRecording() async {
        guard state == .recording else { return }
        stopEscapeMonitor()

        // Fire the scribble sound the instant the user releases / second-taps,
        // before transcription runs. Gives immediate audible confirmation
        // even when the recording transcribes to nothing (empty speech,
        // breath-only). This is the single source of audible feedback per
        // recording — see SoundwavePanel.playCompletionSound() docs.
        soundwavePanel.playCompletionSound()

        stopLiveTranscription()

        state = .transcribing
        menuBarController.setRecordingIndicator(active: false)

        // Optimistic close: flip the pill to "Copied!" the instant the user
        // releases, before transcription runs. The 1 s auto-hide timer starts
        // now, so the lozenge disappears quickly regardless of how long batch
        // transcription takes. If the result turns out empty or errors,
        // showNoResult / showError re-present the pill with the corrected
        // state (they handle the case where the hide timer already fired).
        soundwavePanel.showCopied()

        // Keep recording for a short tail so the last word isn't clipped.
        // Speech typically trails 200-400ms after the speaker "finishes".
        try? await Task.sleep(for: .milliseconds(350))

        let samples = audioRecorder.stop()
        // Resume music after the audio system settles. Delay is transport-
        // aware (longer on Bluetooth to clear the HFP→A2DP codec
        // transition, shorter on wired to just clear the chime). Cancel,
        // error, and quit paths resume immediately — no chime to coexist
        // with there. See MusicPauser for delay rationale.
        musicPauser.scheduleResumeAfterOutputSettles()
        print("[Shhhcribble] Captured \(samples.count) samples (~\(String(format: "%.1f", Double(samples.count)/16000))s)")

        var textToInsert: String? = nil
        var transcriptionFailed = false
        do {
            let text = try await transcriptionEngine.transcribe(audioSamples: samples)
            var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if ModelManager.fillerFilterEnabled {
                trimmed = FillerWordFilter.filter(trimmed)
            }
            textToInsert = trimmed.isEmpty ? nil : trimmed
        } catch {
            print("[Shhhcribble] ❌ Transcription error: \(error.localizedDescription)")
            transcriptionFailed = true
        }

        if let text = textToInsert {
            // Save to history and refresh menu before inserting
            ModelManager.addToHistory(text)
            menuBarController.rebuildMenu()

            print("[Shhhcribble] Inserting: \"\(text.prefix(80))\"")

            // Panel stays visible (nonactivating — target app keeps focus).
            // Small delay lets any focus changes settle before the insert.
            try? await Task.sleep(for: .milliseconds(150))

            // Capture the target PID NOW (not at record-start) so the paste
            // goes to whatever field the user has most recently focused —
            // letting them start recording in Slack and finish by pasting
            // into Notes.
            let targetPid = NSWorkspace.shared.frontmostApplication?.processIdentifier

            // showCopied was already fired optimistically at release — just paste.
            let _ = textInserter.insert(text: text, targetPid: targetPid)
        } else if transcriptionFailed {
            soundwavePanel.showError("Transcription failed")
        } else {
            soundwavePanel.showNoResult()
        }

        state = .idle
    }

    // MARK: - Live transcription

    private func startLiveTranscription() {
        liveTranscriptionTask = Task { [weak self] in
            guard let self else { return }
            // Wait a beat before the first pass so there's audio to transcribe
            try? await Task.sleep(for: .seconds(liveTranscriptionInterval))

            while !Task.isCancelled, self.state == .recording {
                let snapshot = self.audioRecorder.currentSamples
                // Need at least 1s of audio before attempting live transcription
                if snapshot.count > 16_000 {
                    if let text = try? await self.transcriptionEngine.transcribe(audioSamples: snapshot) {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            self.soundwavePanel.updateLiveText(trimmed)
                        }
                    }
                }
                try? await Task.sleep(for: .seconds(self.liveTranscriptionInterval))
            }
        }
    }

    private func stopLiveTranscription() {
        liveTranscriptionTask?.cancel()
        liveTranscriptionTask = nil
    }

    // MARK: - Hotkey update (called from SettingsView)

    func updateHotkey(_ option: ModelManager.HotkeyOption) {
        ModelManager.selectedHotkeyID = option.id
        hotKeyMonitor.updateHotkey(keyCode: option.keyCode, modifiers: option.modifiers)
        print("[Shhhcribble] Hotkey changed to \(option.label)")
    }

    // MARK: - Permissions

    @discardableResult
    private func requestAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}

// MARK: - MenuBarControllerDelegate

extension AppDelegate: MenuBarControllerDelegate {
    func menuBarControllerDidRequestSettings(_ controller: MenuBarController) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                transcriptionEngine: transcriptionEngine,
                appDelegate: self
            )
            settingsWindowController?.window?.delegate = self
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func menuBarControllerDidRequestQuit(_ controller: MenuBarController) {
        NSApp.terminate(nil)
    }

    func menuBarControllerDidRequestRepaste(_ controller: MenuBarController, text: String) {
        // Capture frontmost app now (before menu closes and focus changes)
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        Task {
            // Small delay so the menu has fully closed before we try to insert
            try? await Task.sleep(for: .milliseconds(200))
            let _ = textInserter.insert(text: text, targetPid: pid)
        }
    }
}

// MARK: - NSWindowDelegate

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        settingsWindowController = nil
    }
}
