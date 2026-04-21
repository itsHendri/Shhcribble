import AVFoundation

/// Captures microphone input and converts it to 16 kHz mono Float32 samples
/// required by WhisperKit. A level callback is fired on the main thread with
/// a normalized amplitude (0–1) for the soundwave UI.
///
/// Thread-safety note: All public methods must be called on the main thread.
/// The AVCaptureDevice.requestAccess callback is async; `levelCallback` being
/// non-nil is used as a cancellation signal — if stop() clears it before the
/// callback fires, startEngine() is never called, preventing double-tap crashes.
final class AudioRecorder {

    private var engine = AVAudioEngine()
    private var samples: [Float] = []
    private var levelCallback: ((Float) -> Void)?
    private var errorCallback: ((String) -> Void)?
    private var tapInstalled = false
    private var configChangeObserver: NSObjectProtocol?

    // WhisperKit requires 16 kHz mono Float32
    private let targetSampleRate: Double = 16_000
    private let targetFormat: AVAudioFormat

    init() {
        targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        )!

        // React to route changes (AirPods connect/disconnect, default input switches).
        // When the engine's config changes mid-session, reinstall the tap against the
        // new input format instead of failing silently.
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleConfigurationChange()
        }
    }

    deinit {
        if let obs = configChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    // MARK: - Public API

    /// Start recording. `levelCallback` is called on the main thread with
    /// a 0–1 amplitude suitable for driving the soundwave animation.
    /// `onError` is invoked on the main thread when audio setup fails
    /// (e.g. no microphone detected).
    func start(levelCallback: @escaping (Float) -> Void,
               onError: ((String) -> Void)? = nil) {
        // Clean up any previous session that didn't shut down fully
        // (guards against the race condition where the permission callback
        // fired after a previous stop(), leaving the engine running)
        tearDown()

        self.levelCallback = levelCallback
        self.errorCallback = onError
        samples.removeAll(keepingCapacity: true)

        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            guard granted else {
                print("[Shhhcribble] Microphone permission denied.")
                DispatchQueue.main.async {
                    self?.errorCallback?("Microphone permission denied")
                }
                return
            }
            DispatchQueue.main.async {
                // If stop() was called while we awaited permission, levelCallback
                // will be nil — abort silently instead of starting a phantom session.
                guard let self, self.levelCallback != nil else { return }
                self.startEngine()
            }
        }
    }

    /// Stop recording and return the captured samples.
    func stop() -> [Float] {
        let captured = samples
        tearDown()
        return captured
    }

    /// Non-destructive snapshot of samples captured so far (for live transcription).
    var currentSamples: [Float] { samples }

    // MARK: - Private

    private func tearDown() {
        // Setting levelCallback = nil before removeTap / stop acts as a
        // cancellation flag for any in-flight permission callbacks.
        levelCallback = nil
        errorCallback = nil
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        engine.reset()
        engine = AVAudioEngine()  // new instance fully releases the CoreAudio device
        samples.removeAll(keepingCapacity: true)
    }

    private func startEngine() {
        // Guard against double-tap (should not happen, but be defensive)
        guard !tapInstalled else { return }

        let inputNode = engine.inputNode

        // If the user has pinned a specific mic, bind the engine's input AU to it.
        // On failure (device unplugged, translation error), silently fall back to
        // the system default — the user gets audio from *something* rather than nothing.
        if let uid = ModelManager.preferredInputDeviceUID,
           let deviceID = AudioDeviceManager.resolveAudioDeviceID(forUID: uid),
           let audioUnit = inputNode.audioUnit {
            var id = deviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &id,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            if status != noErr {
                print("[Shhhcribble] ⚠️ Failed to set input device (status=\(status)); using system default.")
            }
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)

        // No input device (e.g. Mac mini with no built-in mic and nothing connected)
        // returns a zero-channel / zero-rate format. `installTap` with this format
        // throws an Obj-C exception that crashes the app — bail out cleanly instead.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            print("[Shhhcribble] ❌ No microphone detected (sampleRate=\(inputFormat.sampleRate), channels=\(inputFormat.channelCount))")
            errorCallback?("No microphone detected")
            return
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            print("[Shhhcribble] Could not create AVAudioConverter.")
            errorCallback?("Audio converter unavailable")
            return
        }

        tapInstalled = true
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }

            let ratio = self.targetSampleRate / inputFormat.sampleRate
            let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

            guard let output = AVAudioPCMBuffer(pcmFormat: self.targetFormat,
                                                frameCapacity: outFrames) else { return }

            var inputConsumed = false
            var convError: NSError?
            converter.convert(to: output, error: &convError) { _, outStatus in
                if inputConsumed { outStatus.pointee = .noDataNow; return nil }
                outStatus.pointee = .haveData
                inputConsumed = true
                return buffer
            }

            guard convError == nil,
                  let channelData = output.floatChannelData?[0] else { return }

            let frameCount = Int(output.frameLength)
            let chunk = Array(UnsafeBufferPointer(start: channelData, count: frameCount))

            let rms = sqrt(chunk.map { $0 * $0 }.reduce(0, +) / Float(max(frameCount, 1)))
            let level = min(rms * 20.0, 1.0)

            DispatchQueue.main.async {
                self.samples.append(contentsOf: chunk)
                self.levelCallback?(level)
            }
        }

        // Pre-warm the route so CoreAudio wakes the (possibly Bluetooth) input
        // device before we call start(). Helps the "first AirPods record does
        // nothing" glitch.
        engine.prepare()

        do {
            try engine.start()
        } catch {
            tapInstalled = false
            print("[Shhhcribble] AVAudioEngine start failed: \(error.localizedDescription)")
            errorCallback?("Couldn't start microphone")
        }
    }

    /// Fired when the audio route changes mid-recording (e.g. AirPods drop,
    /// default input switches). Tear the tap down and reinstall against the
    /// new input format so the recording keeps working instead of dying silently.
    private func handleConfigurationChange() {
        // Only react if we're actively recording — otherwise nothing to do.
        guard tapInstalled, let level = levelCallback else { return }
        print("[Shhhcribble] Audio configuration changed — restarting engine")

        let onErr = errorCallback
        // Preserve already-captured samples across the restart
        let preservedSamples = samples

        // Tear down but keep callbacks; tearDown() wipes them, so re-assign.
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        engine.reset()
        engine = AVAudioEngine()
        samples = preservedSamples
        levelCallback = level
        errorCallback = onErr

        startEngine()
    }
}
