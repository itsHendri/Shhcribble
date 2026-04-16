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

    private enum AppState { case idle, recording, transcribing }
    private var state: AppState = .idle

    // Live transcription: runs Parakeet on the growing buffer every N seconds
    private var liveTranscriptionTask: Task<Void, Never>?
    private let liveTranscriptionInterval: TimeInterval = 3.0

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[Shhcribble] App launched.")

        let axTrusted = requestAccessibilityPermission()
        print("[Shhcribble] AXIsProcessTrusted = \(axTrusted)")

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
                switch ModelManager.activationMode {
                case .pushToTalk: await self.beginRecording()
                case .toggle:     await self.toggleRecording()
                }
            },
            onKeyUp: { [weak self] in
                guard let self else { return }
                // Toggle mode ignores keyUp — stop is driven by the next keyDown.
                if ModelManager.activationMode == .pushToTalk {
                    await self.endRecording()
                }
            }
        )
        hotKeyMonitor.start(keyCode: hotkey.keyCode, modifiers: hotkey.modifiers)
    }

    // MARK: - Recording state machine

    private func beginRecording() async {
        guard state == .idle else { return }
        guard transcriptionEngine.isReady else {
            print("[Shhcribble] Model not ready: \(transcriptionEngine.statusText)")
            menuBarController.flashNotReady()
            return
        }
        print("[Shhcribble] Recording started")
        state = .recording
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
    }

    /// Toggle activation: tap once to start recording, tap again to stop & paste.
    private func toggleRecording() async {
        switch state {
        case .idle:         await beginRecording()
        case .recording:    await endRecording()
        case .transcribing: break  // ignore hotkey while we're transcribing
        }
    }

    /// Called from AudioRecorder when setup fails (no mic, permission denied, etc.)
    /// Abort the current recording attempt cleanly and surface the error in the pill.
    private func handleAudioError(_ message: String) {
        print("[Shhcribble] Audio error: \(message)")
        stopLiveTranscription()
        _ = audioRecorder.stop()
        menuBarController.setRecordingIndicator(active: false)
        soundwavePanel.showError(message)
        state = .idle
    }

    private func endRecording() async {
        guard state == .recording else { return }
        stopLiveTranscription()

        state = .transcribing
        soundwavePanel.showTranscribing()
        menuBarController.setRecordingIndicator(active: false)

        // Keep recording for a short tail so the last word isn't clipped.
        // Speech typically trails 200-400ms after the speaker "finishes".
        try? await Task.sleep(for: .milliseconds(350))

        let samples = audioRecorder.stop()
        print("[Shhcribble] Captured \(samples.count) samples (~\(String(format: "%.1f", Double(samples.count)/16000))s)")

        var textToInsert: String? = nil
        do {
            let text = try await transcriptionEngine.transcribe(audioSamples: samples)
            var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if ModelManager.fillerFilterEnabled {
                trimmed = FillerWordFilter.filter(trimmed)
            }
            textToInsert = trimmed.isEmpty ? nil : trimmed
        } catch {
            print("[Shhcribble] ❌ Transcription error: \(error.localizedDescription)")
        }

        guard let text = textToInsert else {
            soundwavePanel.hide()
            state = .idle
            return
        }

        // Save to history and refresh menu before inserting
        ModelManager.addToHistory(text)
        menuBarController.rebuildMenu()

        print("[Shhcribble] Inserting: \"\(text.prefix(80))\"")

        // Panel stays visible (nonactivating — target app keeps focus).
        // Small delay lets any focus changes settle before the insert.
        try? await Task.sleep(for: .milliseconds(150))

        // Capture the target PID NOW (not at record-start) so the paste goes
        // to whatever field the user has most recently focused — letting them
        // start recording in Slack and finish by pasting into Notes.
        let targetPid = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // Fire sound and paste simultaneously — player is pre-buffered so
        // showCopied() plays instantly, and postToPid is near-instantaneous.
        soundwavePanel.showCopied()
        let _ = textInserter.insert(text: text, targetPid: targetPid)

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
        print("[Shhcribble] Hotkey changed to \(option.label)")
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
