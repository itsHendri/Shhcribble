import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers
import os
// Sparkle is temporarily detached from the build so the app can ship as a plain
// ad-hoc DMG without a Developer ID cert (embedded Sparkle.framework fails
// Library Validation under Hardened Runtime + ad-hoc signing). All Sparkle code
// is guarded by `#if canImport(Sparkle)`, which auto-reactivates the moment the
// Sparkle SPM package is re-added to the target. See CLAUDE.md "Sparkle auto-update".
#if canImport(Sparkle)
import Sparkle
#endif

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
    private var transcriptionsWindowController: TranscriptionsWindowController?
    private let musicPauser = MusicPauser()

    /// SQLite-backed store of all transcripts (dictation + file). Replaces the
    /// old cap-10 UserDefaults history; migrates it in on first launch.
    private var transcriptStore: TranscriptStore!
    /// Coordinates file/video transcription off the AudioRecorder path.
    private var fileTranscriber: FileTranscriber!
    private var cancellables = Set<AnyCancellable>()

    #if canImport(Sparkle)
    /// Sparkle auto-updater. `startingUpdater: true` enables automatic
    /// background checks; the menu's "Check for Updates…" triggers a manual
    /// check via `checkForUpdates(_:)`. Feed + EdDSA public key come from
    /// Info.plist (`SUFeedURL` / `SUPublicEDKey`).
    private var updaterController: SPUStandardUpdaterController!
    #endif

    /// Internal recording state machine. `.transcribing` covers the window from
    /// hotkey release through transcription + optional cleanup; it IS surfaced as
    /// the persistent "Transcribing…" spinner pill (which flips to `.copied` only
    /// once the paste lands). It is set immediately on entry to `endRecording()`
    /// so a re-entrant hotkey/Escape during the work is ignored.
    private enum AppState { case idle, recording, transcribing }
    private var state: AppState = .idle

    /// True from the moment `beginRecording()` commits to starting until the
    /// recording is actually live (or the attempt aborts). `state` stays `.idle`
    /// across the first-launch mic-permission `await`, so without this flag a
    /// file opened during that await could start a job on the shared AsrManager.
    /// `isDictationActive` (the FileTranscriber gate) reads it, closing that race.
    private var dictationStarting = false

    /// Whether the Transcriptions window has already been presented for the
    /// current file-transcription batch, so per-file progress ticks don't
    /// re-activate (and steal focus to) the window on every update.
    private var didPresentFileWindow = false

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
    /// Carbon event time (seconds since boot) of the keyDown that started the
    /// current recording — the moment the key was *physically* pressed, not when
    /// our handler got to run. See HotKeyMonitor's doc: the handlers are
    /// serialized on the main actor behind a blocking recording start, so
    /// wall-clock inside the keyUp handler misread quick taps as long holds.
    private var recordingStartedByKeyDownAt: Double?
    private let holdThreshold: TimeInterval = 0.5

    /// Cancellable "Waking mic…" placeholder. Only shown if the input route
    /// hasn't gone live within `warmingUpPillDelay` — so the warm path (built-in
    /// mic / warm AirPods, onReady in ~100–200 ms) shows the recording pill
    /// directly with no flash, while a cold AirPods wake (onReady up to ~1.2 s)
    /// gets the "wait to speak" placeholder. Cancelled by onReady.
    private var warmingUpPillWorkItem: DispatchWorkItem?
    private let warmingUpPillDelay: TimeInterval = 0.25

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[Shhhcribble] App launched.")

        // As an LSUIElement app we ship no menu bar, so macOS has no Edit menu to
        // route Cut/Copy/Paste/Select-All/Undo through — which silently breaks
        // ⌘C/⌘V/⌘A/⌘Z in every text field and the transcript reader. Install a
        // minimal main menu with a standard Edit menu; the items target the first
        // responder (nil target) so they reach whatever text view is focused.
        installMainMenu()

        let axTrusted = requestAccessibilityPermission()
        print("[Shhhcribble] AXIsProcessTrusted = \(axTrusted)")

        transcriptionEngine = TranscriptionEngine()
        audioRecorder       = AudioRecorder()
        textInserter        = TextInserter()

        // Map the retired cleanup toggle onto the new active-style selection
        // (one-shot). Must run before anything reads ModelManager.activeStyleID.
        ModelManager.migrateCleanupToStyleIfNeeded()

        // Storage + file-transcription coordinator. The store migrates the
        // legacy UserDefaults history on first launch. The coordinator shares
        // the loaded AsrManager with dictation *serially* — it only runs while
        // no recording is active (and dictation is blocked while it runs).
        transcriptStore = TranscriptStore.makeDefault()

        // The user must always have a valid, selectable active style. If the
        // stored id points at a deleted style (or the retired "off"), reset to
        // Default so the picker never shows a blank selection and dictation never
        // silently runs unstyled.
        let validStyleIDs = Set(transcriptStore.styles.map { $0.id.uuidString } + [ActiveStyle.defaultCleanupID])
        if !validStyleIDs.contains(ModelManager.activeStyleID) {
            ModelManager.activeStyleID = ActiveStyle.defaultCleanupID
        }

        fileTranscriber = FileTranscriber(
            engine: transcriptionEngine,
            store: transcriptStore,
            isDictationActive: { [weak self] in
                guard let self else { return false }
                return self.state != .idle || self.dictationStarting
            }
        )
        fileTranscriber.$status
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.handleFileStatus(status) }
            .store(in: &cancellables)

        let soundwaveViewModel = SoundwaveViewModel()
        soundwavePanel = SoundwavePanel(viewModel: soundwaveViewModel)

        menuBarController = MenuBarController(delegate: self)

        #if canImport(Sparkle)
        // Start Sparkle. Reads SUFeedURL + SUPublicEDKey from Info.plist; runs
        // automatic background update checks. `userDriverDelegate: self` opts
        // into "gentle reminders" — as an LSUIElement app we badge the menu-bar
        // icon instead of letting a scheduled-update alert pop unnoticed in the
        // background (see the SPUStandardUserDriverDelegate extension below).
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        #endif

        Task {
            await transcriptionEngine.loadModel(variant: ModelManager.selectedModel)
        }

        // Warm the on-device model so the first dictation doesn't pay cold start.
        // Warm whenever the active style is anything but Off (Default clean-up or a
        // transform both use TranscriptCleaner's session). No-op when the model is
        // unavailable.
        if ModelManager.activeStyleID != ActiveStyle.offID {
            TranscriptCleaner.prewarm()
        }

        let hotkey = ModelManager.selectedHotkey
        hotKeyMonitor = HotKeyMonitor(
            onKeyDown: { [weak self] eventTime in
                guard let self else { return }
                switch self.state {
                case .idle:
                    self.recordingStartedByKeyDownAt = eventTime
                    await self.beginRecording()
                case .recording:
                    // Second tap of a toggle-style use — stop and transcribe.
                    await self.endRecording()
                case .transcribing:
                    break  // ignore hotkey while we're transcribing
                }
            },
            onKeyUp: { [weak self] eventTime in
                guard let self else { return }
                // Only a release that ends an active recording matters. If the
                // hold lasted ≥ holdThreshold, treat it as push-to-talk and
                // stop now; a quick tap is left recording (toggle) until the
                // next keyDown. A keyUp seen in any other state — notably the
                // release of a toggle "stop" tap, which already moved us to
                // .transcribing — is ignored.
                //
                // `heldFor` is the difference of the two Carbon *event* times, so
                // it is the real key-hold duration. Measuring with a clock read
                // here instead would time how long the main actor was blocked by
                // the recording start (AppleScript pause + cold engine.start) and
                // misclassify a quick tap as push-to-talk — stopping the recording
                // instantly with "No speech detected".
                //
                // Note that correct measurement is NOT sufficient: `.automatic`
                // still classifies against a start that may have been stalled, so
                // a genuine hold can be released before the mic is even live. That
                // is why the explicit modes exist — see `ModelManager.ActivationMode`.
                guard self.state == .recording else { return }
                let heldFor = self.recordingStartedByKeyDownAt.map { eventTime - $0 }
                // In .toggle this is always false — keyUp never ends a recording,
                // the next keyDown does. That is what makes toggle immune to a
                // stalled start.
                if ModelManager.activationMode.keyUpShouldEndRecording(
                    heldFor: heldFor, holdThreshold: self.holdThreshold) {
                    await self.endRecording()
                }
            }
        )
        hotKeyMonitor.start(keyCode: hotkey.keyCode, modifiers: hotkey.modifiers)
    }

    /// Defensive resume if the user quits mid-recording — otherwise music
    /// we paused stays paused with no obvious way to discover why. Synchronous:
    /// the process is about to exit, so a fire-and-forget hop onto the pauser's
    /// script thread might not run in time.
    func applicationWillTerminate(_ notification: Notification) {
        musicPauser.resumeIfPausedSync()
    }

    // MARK: - Recording state machine

    private func beginRecording() async {
        guard state == .idle else { return }
        // A file transcription is using the shared AsrManager — starting a
        // dictation now would corrupt its decoder state. Reject with a hint;
        // the file job is short-lived and the user can try again after.
        guard !fileTranscriber.isRunning else {
            soundwavePanel.showInfo("Finishing file transcription — try again in a moment")
            return
        }
        guard transcriptionEngine.isReady else {
            print("[Shhhcribble] Model not ready: \(transcriptionEngine.statusText)")
            // Near-cursor feedback so a first-launch press during model load
            // isn't silently dropped with only an easy-to-miss menu-bar tint.
            soundwavePanel.showInfo("Getting ready — try again in a moment")
            menuBarController.flashNotReady()
            return
        }

        // Commit to starting: block file jobs from grabbing the shared engine
        // across the permission await below. actuallyBeginRecording() clears it
        // once the recording is live; this defer clears it on every abort path.
        dictationStarting = true
        defer { if state != .recording { dictationStarting = false } }

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
        dictationStarting = false   // recording is live; `state` now covers the gate
        transcriptionEngine.isBusy = true
        musicPauser.pauseIfPlaying()
        menuBarController.setRecordingIndicator(active: true)
        // Escape-to-cancel is armed immediately so the user can bail even during
        // a cold-AirPods warm-up.
        startEscapeMonitor()
        // Show a "Waking mic…" placeholder ONLY if the route is still cold after a
        // short grace period — this signals cold-AirPods users to *wait* instead of
        // speaking into the dead route. The warm path (onReady in ~100–200 ms)
        // cancels this before it fires, so it shows the recording pill directly with
        // no flash. The real "go" signal (recording pill) always waits for onReady.
        let warmItem = DispatchWorkItem { [weak self] in
            guard let self, self.state == .recording else { return }
            self.soundwavePanel.showWarmingUp()
        }
        warmingUpPillWorkItem = warmItem
        DispatchQueue.main.asyncAfter(deadline: .now() + warmingUpPillDelay, execute: warmItem)
        audioRecorder.start(
            levelCallback: { [weak self] level in
                self?.soundwavePanel.updateLevel(level)
            },
            // Show/flip to the recording "go" state once the input route is
            // physically live. On AirPods sitting in A2DP the mic has 0 channels
            // until IO drives the A2DP→HFP switch; speaking before then is
            // captured as unrecoverable silence ("first record is silent" glitch).
            // showRecording() presents the pill if the placeholder never showed
            // (warm path) or transitions it from .warmingUp (cold path).
            onReady: { [weak self] in
                guard let self, self.state == .recording else { return }
                self.cancelWarmingUpPill()
                self.soundwavePanel.showRecording()
                self.startLiveTranscription()
            },
            onError: { [weak self] message in
                self?.handleAudioError(message)
            }
        )
    }

    /// Drop the pending "Waking mic…" placeholder. Every path that leaves
    /// `.recording` calls this: the work item's own `state == .recording` guard
    /// would also cover it, but only because those paths happen to mutate
    /// `state` first — don't leave correctness resting on that ordering.
    private func cancelWarmingUpPill() {
        warmingUpPillWorkItem?.cancel()
        warmingUpPillWorkItem = nil
    }

    /// Cancels the current recording: stops audio, discards samples, hides the
    /// panel, and returns to idle without pasting anything.
    private func cancelRecording() {
        guard state == .recording else { return }
        print("[Shhhcribble] Recording cancelled (Escape)")
        cancelWarmingUpPill()
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
        cancelWarmingUpPill()
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

        // Leave .recording IMMEDIATELY — before any await below — so a second
        // hotkey event or an Escape landing during the live-task cancellation
        // (which can take hundreds of ms to >1s) hits the .transcribing branch
        // and is ignored. endRecording() is otherwise re-entrant across
        // `await liveTask?.value` and could double-transcribe/paste or slip an
        // Escape-cancel through against the already-ending recording.
        state = .transcribing
        cancelWarmingUpPill()
        recordingStartedByKeyDownAt = nil
        stopEscapeMonitor()
        menuBarController.setRecordingIndicator(active: false)

        // Resolve the active style NOW, from the app that was frontmost while the
        // user spoke (per-app auto-selection); a mapped app overrides the default
        // selection. Captured before the awaits below so it reflects the dictation
        // context, not wherever focus drifts during transcription. (Edge case: if
        // the user starts in one app and finishes/pastes in another, the record-
        // time app decides the style — accepted for v1.) A nil bundle ID disables
        // the per-app pass in the resolver — which is how the master switch works.
        // Only auto-activate a per-app style when the user is actually typing into
        // an editable field in the frontmost app — not merely because that app is
        // frontmost (e.g. reading Mail without a compose window open should not
        // force the Email style). Gated on the master switch too.
        let frontmostBundleID = (ModelManager.styleAppActivationEnabled && frontmostFocusIsEditable())
            ? NSWorkspace.shared.frontmostApplication?.bundleIdentifier : nil
        let activeStyle = StyleResolver.resolve(
            frontmostBundleID: frontmostBundleID,
            activeStyleID: ModelManager.activeStyleID,
            styles: transcriptStore.styles
        )

        // Fire the scribble sound the instant the user releases / second-taps,
        // before transcription runs. Gives immediate audible confirmation
        // even when the recording transcribes to nothing (empty speech,
        // breath-only). This is the single source of audible feedback per
        // recording — see SoundwavePanel.playCompletionSound() docs.
        soundwavePanel.playCompletionSound()

        // Show a persistent "Transcribing…" state while the final transcribe +
        // optional on-device AI cleanup run. Because cleanup runs to completion
        // (no timeout), this honestly reflects work happening in the background
        // instead of an optimistic "Copied!" that lands before the paste is real.
        // It stays up — no auto-hide — until showCopied (after paste lands),
        // showNoResult, or showError replaces it below.
        soundwavePanel.showTranscribing()

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
        var rawTranscript = ""
        var transcriptionFailed = false
        do {
            let text = try await transcriptionEngine.transcribe(audioSamples: samples)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            rawTranscript = trimmed
            // Shared pipeline: dictionary → styled AI cleanup/transform (per the
            // resolved active style) or the FillerWordFilter floor. See
            // TranscriptPipeline. Snapshot the dictionary on the main actor here —
            // the pipeline is nonisolated / runs off-main (style resolved above).
            let dictionary = transcriptStore.dictionaryEntries
            let result = await TranscriptPipeline.process(trimmed, dictionary: dictionary, style: activeStyle)
            textToInsert = result.isEmpty ? nil : result
        } catch {
            print("[Shhhcribble] ❌ Transcription error: \(error.localizedDescription)")
            transcriptionFailed = true
        }

        if let text = textToInsert {
            // Persist to the store (raw kept alongside the cleaned text). Record
            // the transform style's name so the Studio can tag it — nil for Default
            // clean-up / Off (only a real transform shows a tag). The menu rebuilds
            // automatically via the store subscription.
            var styleName: String? = nil
            var styleID: String? = nil
            if case .custom(let s) = activeStyle { styleName = s.name; styleID = s.id.uuidString }
            transcriptStore.addDictation(
                text: text,
                rawText: rawTranscript.isEmpty ? text : rawTranscript,
                styleName: styleName,
                styleID: styleID
            )

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

        // Pick up any files that were opened/queued while we were recording.
        fileTranscriber.drainIfIdle()
    }

    // MARK: - File transcription

    /// Finder "Open With" / `open -a Shhhcribble file.m4a` entry point. Multiple
    /// selected files all arrive here and are queued sequentially — none dropped.
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let urls = filenames.map { URL(fileURLWithPath: $0) }
        fileTranscriber.enqueue(urls)
        sender.reply(toOpenOrPrint: .success)
    }

    /// Show an NSOpenPanel filtered to audio/video and enqueue the selection.
    private func presentFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = FileTranscriber.supportedContentTypes
        panel.prompt = "Transcribe"
        panel.message = "Choose audio or video files to transcribe"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            fileTranscriber.enqueue(panel.urls)
        }
    }

    /// Drives lightweight UI as file jobs progress: opens the Transcriptions
    /// window so results appear live, and surfaces failures in the pill.
    private func handleFileStatus(_ status: FileTranscriber.Status) {
        switch status {
        case .running:
            // Present + focus the window once per batch. `.running` fires on
            // every progress tick, so guard on didPresentFileWindow to avoid
            // yanking focus back to the window on each update.
            if !didPresentFileWindow {
                didPresentFileWindow = true
                showTranscriptionsWindow(activate: true)
            }
        case .finished:
            didPresentFileWindow = false
        case .failed(let name, let message):
            soundwavePanel.showError("\(name): \(message)")
        case .idle:
            didPresentFileWindow = false
        }
    }

    private func showTranscriptionsWindow(activate: Bool) {
        if transcriptionsWindowController == nil {
            transcriptionsWindowController = TranscriptionsWindowController(
                store: transcriptStore,
                fileTranscriber: fileTranscriber,
                engine: transcriptionEngine,
                appDelegate: self,
                onTranscribeFile: { [weak self] in self?.presentFilePicker() },
                onQuit: { NSApp.terminate(nil) }
            )
            transcriptionsWindowController?.window?.delegate = self
        }
        transcriptionsWindowController?.showWindow(nil)
        if activate {
            transcriptionsWindowController?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Live transcription

    private func startLiveTranscription() {
        liveTranscriptionTask = Task { [weak self] in
            guard let self else { return }
            // Wait a beat before the first pass so there's audio to transcribe
            try? await Task.sleep(for: .seconds(liveTranscriptionInterval))

            while !Task.isCancelled, self.state == .recording {
                // Snapshot the dictionary on the main actor each pass so mid-session
                // edits are reflected (the store is @MainActor).
                let dictionary = self.transcriptStore.dictionaryEntries
                let snapshot = self.audioRecorder.currentSamples
                // Need at least 1s of audio before attempting live transcription
                if snapshot.count > 16_000 {
                    if let text = try? await self.transcriptionEngine.transcribe(audioSamples: snapshot) {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            // Same dictionary pass as the final transcript so the
                            // live preview shows the user's corrected terms.
                            self.soundwavePanel.updateLiveText(
                                PersonalDictionary.apply(dictionary, to: trimmed)
                            )
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

    // MARK: - Updates (called from SettingsView)

    /// True when the in-app updater is compiled in (Sparkle package attached).
    /// Drives whether Settings shows the "Check for Updates…" button.
    var updaterAvailable: Bool {
        #if canImport(Sparkle)
        return true
        #else
        return false
        #endif
    }

    /// Manual update check. Activates the app first so Sparkle's update window
    /// isn't lost behind other apps (we're an LSUIElement menu-bar app with no
    /// dock icon), and clears any pending gentle-reminder badge — the user is
    /// engaging with updates right now.
    func checkForUpdates() {
        #if canImport(Sparkle)
        menuBarController.setUpdateBadge(visible: false)
        NSApp.activate(ignoringOtherApps: true)
        updaterController.checkForUpdates(nil)
        #endif
    }

    // MARK: - Permissions

    @discardableResult
    private func requestAccessibilityPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Whether the frontmost app currently has a focused **editable** text
    /// element. Gates per-app style auto-activation so a style only kicks in when
    /// the user is actually in a text field (composing), not just because the app
    /// is frontmost. The system-wide AX focused element belongs to the active app,
    /// so this covers "app in foreground AND a field is selected" in one check.
    ///
    /// Requires AX trust (the app already uses it for paste/Escape). When AX is
    /// untrusted we can't inspect focus, so we permit activation — degrading to
    /// plain app-frontmost matching rather than silently never activating.
    private func frontmostFocusIsEditable() -> Bool {
        guard AXIsProcessTrusted() else { return true }

        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return false }
        let element = focusedRef as! AXUIElement

        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let editableRoles: Set<String> = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String,
        ]
        if let role = roleRef as? String, editableRoles.contains(role) { return true }

        // Web / custom fields (contenteditable) may report a different role but
        // expose a settable string value — treat that as editable too.
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
           settable.boolValue {
            return true
        }
        return false
    }

    /// Install a minimal main menu whose Edit submenu wires the standard
    /// clipboard/undo actions to the first responder. Without this, an
    /// LSUIElement app's text views get no ⌘X/⌘C/⌘V/⌘A/⌘Z because there is no
    /// menu carrying those key equivalents. Titles never show (no menu bar); the
    /// menu exists purely to route the shortcuts.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        // A first (app) menu is required for the menu bar to be well-formed.
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }
}

#if canImport(Sparkle)
// MARK: - Sparkle gentle reminders (SPUStandardUserDriverDelegate)
//
// As a menu-bar-only app (LSUIElement) we have no dock icon and usually no
// window, so Sparkle's scheduled "update available" alert would appear in the
// background where nobody sees it (Sparkle logs a one-time warning about
// exactly this). Instead: when a *scheduled* check finds an update and the app
// isn't in immediate focus, we suppress the alert and badge the menu-bar icon
// amber. The user notices, opens the window, hits "Check for Updates…" in
// Settings (or Sparkle re-presents on the next launch in focus). User-initiated
// checks are untouched — those always show Sparkle's UI directly.
extension AppDelegate: SPUStandardUserDriverDelegate {

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // In immediate focus (e.g. right at launch, app frontmost) Sparkle's
        // own alert is fine; otherwise we take over with the badge.
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        guard !handleShowingUpdate else { return }
        menuBarController.setUpdateBadge(visible: true)
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        menuBarController.setUpdateBadge(visible: false)
    }

    func standardUserDriverWillFinishUpdateSession() {
        menuBarController.setUpdateBadge(visible: false)
    }
}
#endif

// MARK: - MenuBarControllerDelegate

extension AppDelegate: MenuBarControllerDelegate {
    func menuBarControllerDidRequestSettings(_ controller: MenuBarController) {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                transcriptionEngine: transcriptionEngine,
                appDelegate: self,
                transcriptStore: transcriptStore
            )
            settingsWindowController?.window?.delegate = self
        }
        settingsWindowController?.showWindow(nil)
        settingsWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func menuBarControllerDidRequestCheckForUpdates(_ controller: MenuBarController) {
        checkForUpdates()
    }

    func menuBarControllerUpdaterAvailable(_ controller: MenuBarController) -> Bool {
        updaterAvailable
    }

    func menuBarControllerDidRequestQuit(_ controller: MenuBarController) {
        NSApp.terminate(nil)
    }

    func menuBarControllerDidRequestTranscribeFile(_ controller: MenuBarController) {
        presentFilePicker()
    }

    func menuBarControllerDidRequestOpenTranscriptions(_ controller: MenuBarController) {
        showTranscriptionsWindow(activate: true)
    }

    func menuBarControllerStyleMenu(_ controller: MenuBarController) -> (activeID: String, styles: [Style]) {
        (ModelManager.activeStyleID, transcriptStore.stylesAlphabetical)
    }

    func menuBarController(_ controller: MenuBarController, didSelectStyleID id: String) {
        // Setter posts activeStyleDidChangeNotification, keeping the window's
        // Styles picker in sync. Prewarm the model unless the user chose Off.
        ModelManager.activeStyleID = id
        if id != ActiveStyle.offID { TranscriptCleaner.prewarm() }
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
        let closing = notification.object as? NSWindow
        if closing == settingsWindowController?.window {
            settingsWindowController = nil
        } else if closing == transcriptionsWindowController?.window {
            transcriptionsWindowController = nil
        }
    }
}
