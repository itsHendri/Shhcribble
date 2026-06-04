import AppKit
import AVFoundation
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private static let log = Logger(subsystem: "com.shhhcribble.app", category: "recording")

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

    // Live transcription: runs Parakeet on the growing buffer every N seconds
    private var liveTranscriptionTask: Task<Void, Never>?
    private let liveTranscriptionInterval: TimeInterval = 3.0

    /// Global keyDown observer that catches Escape while recording so the user
    /// can cancel without pasting. Only active during .recording state.
    private var escapeMonitor: Any?

    /// Timestamp of the hotkey keyDown that started the current recording.
    /// On keyUp we measure the elapsed hold: a long hold (≥ holdThreshold) is
    /// read as push-to-talk and releases stop the recording; a quick tap is
    /// read as toggle and the recording stays on until the next tap.
    private var recordingStartedByKeyDownAt: DispatchTime?
    private let holdThreshold: TimeInterval = 0.5

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

        // Warm the on-device cleanup model so the first cleanup doesn't pay cold
        // start. No-op when the feature is off or the model is unavailable.
        if ModelManager.transcriptCleanupEnabled {
            TranscriptCleaner.prewarm()
        }

        let hotkey = ModelManager.selectedHotkey
        hotKeyMonitor = HotKeyMonitor(
            onKeyDown: { [weak self] in
                guard let self else { return }
                switch self.state {
                case .idle:
                    self.recordingStartedByKeyDownAt = .now()
                    await self.beginRecording()
                case .recording:
                    // Second tap of a toggle-style use — stop and transcribe.
                    await self.endRecording()
                case .transcribing:
                    break  // ignore hotkey while we're transcribing
                }
            },
            onKeyUp: { [weak self] in
                guard let self else { return }
                // Only a release that ends an active recording matters. If the
                // hold lasted ≥ holdThreshold, treat it as push-to-talk and
                // stop now; a quick tap is left recording (toggle) until the
                // next keyDown. A keyUp seen in any other state — notably the
                // release of a toggle "stop" tap, which already moved us to
                // .transcribing — is ignored.
                guard self.state == .recording,
                      let startedAt = self.recordingStartedByKeyDownAt else { return }
                let heldFor = Double(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000_000
                if heldFor >= self.holdThreshold {
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
        transcriptionEngine.isBusy = true
        musicPauser.pauseIfPlaying()
        menuBarController.setRecordingIndicator(active: true)
        // Escape-to-cancel is armed immediately so the user can bail even during
        // a cold-AirPods warm-up.
        startEscapeMonitor()
        audioRecorder.start(
            levelCallback: { [weak self] level in
                self?.soundwavePanel.updateLevel(level)
            },
            // Show the pill — the "go" signal — only once the input route is
            // physically live. On AirPods sitting in A2DP the mic has 0 channels
            // until IO drives the A2DP→HFP switch; speaking before then is
            // captured as unrecoverable silence ("first record is silent" glitch).
            // The warm path (built-in mic / warm AirPods) fires this on the first
            // poll, so there's no perceptible delay there.
            onReady: { [weak self] in
                guard let self, self.state == .recording else { return }
                self.soundwavePanel.show()
                self.startLiveTranscription()
            },
            onError: { [weak self] message in
                self?.handleAudioError(message)
            }
        )
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
        recordingStartedByKeyDownAt = nil
        state = .idle
        transcriptionEngine.isBusy = false
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
        recordingStartedByKeyDownAt = nil
        state = .idle
        transcriptionEngine.isBusy = false
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

        // Cancel the live-preview polling task AND wait for it to actually
        // finish before invoking the final batch transcribe below.
        // TranscriptionEngine is @MainActor, so Swift-level calls serialize —
        // but FluidAudio's underlying AsrManager makes no published guarantee
        // about re-entry safety. Waiting here ensures the next .transcribe()
        // call has the engine entirely to itself.
        let liveTask = liveTranscriptionTask
        liveTranscriptionTask = nil
        liveTask?.cancel()
        if liveTask != nil {
            Self.log.notice("Awaiting live-preview task cancellation before final transcribe…")
            _ = await liveTask?.value
            Self.log.notice("Live-preview task settled — proceeding to final transcribe.")
        }

        recordingStartedByKeyDownAt = nil
        state = .transcribing
        menuBarController.setRecordingIndicator(active: false)

        // Show a persistent "Transcribing…" state while the final transcribe +
        // optional on-device AI cleanup run. Because cleanup runs to completion
        // (no timeout), this honestly reflects work happening in the background
        // instead of an optimistic "Copied!" that lands before the paste is real.
        // It stays up — no auto-hide — until showCopied (after paste lands),
        // showNoResult, or showError replaces it below.
        soundwavePanel.showTranscribing()

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
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            var result = trimmed
            // On-device LLM cleanup (Apple FoundationModels) replaces the regex
            // filler filter when enabled + available. It handles fillers, false
            // starts, punctuation and capitalization in one pass. It runs to
            // completion (no timeout — see TranscriptCleaner); on failure, empty
            // output, or an unavailable model, TranscriptCleaner.clean returns nil
            // and we fall back to FillerWordFilter — the always-on universal floor
            // (not a user setting; removed alongside the redundant Settings toggle).
            if !trimmed.isEmpty,
               ModelManager.transcriptCleanupEnabled,
               let cleaned = await TranscriptCleaner.clean(trimmed), !cleaned.isEmpty {
                result = cleaned
            } else {
                result = FillerWordFilter.filter(trimmed)
            }
            textToInsert = result.isEmpty ? nil : result
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

            let _ = textInserter.insert(text: text, targetPid: targetPid)

            // Now that the paste has actually landed, flip the persistent
            // "Transcribing…" pill to "Copied!" with its 1 s auto-hide.
            soundwavePanel.showCopied()
        } else if transcriptionFailed {
            soundwavePanel.showError("Transcription failed")
        } else {
            soundwavePanel.showNoResult()
        }

        state = .idle
        transcriptionEngine.isBusy = false
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
