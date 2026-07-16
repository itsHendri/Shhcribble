import AVFoundation
import CoreAudio
import os

/// Captures microphone input and converts it to 16 kHz mono Float32 samples
/// required by WhisperKit. A level callback is fired on the main thread with
/// a normalized amplitude (0–1) for the soundwave UI.
///
/// Thread-safety note: All public methods must be called on the main thread.
/// The AVCaptureDevice.requestAccess callback is async; `levelCallback` being
/// non-nil is used as a cancellation signal — if stop() clears it before the
/// callback fires, startEngine() is never called, preventing double-tap crashes.
final class AudioRecorder {

    private static let log = Logger(subsystem: "com.shhhcribble.app", category: "audio")

    private var engine = AVAudioEngine()
    private var samples: [Float] = []
    private var levelCallback: ((Float) -> Void)?
    private var errorCallback: ((String) -> Void)?
    private var tapInstalled = false
    private var configChangeObserver: NSObjectProtocol?

    // WhisperKit requires 16 kHz mono Float32
    private let targetSampleRate: Double = 16_000
    private let targetFormat: AVAudioFormat

    // MARK: Route warm-up (cold AirPods "first record is silent" fix)

    /// Fired (once per recording) when the input route is physically live — i.e.
    /// the HAL reports a non-zero input channel count. On AirPods sitting idle in
    /// A2DP the mic has 0 channels until starting IO drives the A2DP→HFP switch;
    /// any audio captured before that is silence and is unrecoverable. The caller
    /// uses this to delay the visible "go" signal so the user doesn't speak into a
    /// dead mic. See the "Route warm-up" decision in CLAUDE.md.
    private var onReadyCallback: (() -> Void)?
    private var didFireReady = false
    private var warmUpPolling = false
    private var warmUpDeadline: DispatchTime?
    /// Max time to wait for the route to come up before going live anyway (so a
    /// genuinely dead mic can't hang recording forever). Generous because the
    /// HFP engage can take a few hundred ms; the warm path returns on the first
    /// poll so this ceiling is only ever hit by a truly stuck route.
    private let warmUpBudget: TimeInterval = 1.2
    private let warmUpPollInterval: TimeInterval = 0.025

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
               onReady: (() -> Void)? = nil,
               onError: ((String) -> Void)? = nil) {
        // Clean up any previous session that didn't shut down fully
        // (guards against the race condition where the permission callback
        // fired after a previous stop(), leaving the engine running)
        tearDown()

        self.levelCallback = levelCallback
        self.errorCallback = onError
        self.onReadyCallback = onReady
        self.didFireReady = false
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
        logCaptureDiagnostics(captured)
        tearDown()
        return captured
    }

    /// Log-only diagnostic (no behavior change) for the cold-AirPods "No speech
    /// detected" investigation. Records how much audio we captured and — crucially
    /// — the signal level of the FIRST second vs the OVERALL take. The theory: on a
    /// cold Bluetooth route the mic reports "ready" (1 ch) instantly but delivers
    /// silence for the first ~0.5–1 s of the HFP switch, so a quick tap records a
    /// dead front window. If a failing cold start logs `first-1s rms ≈ 0` while
    /// `overall rms > 0` (or the whole take is ≈0 on a short tap), that's the proof.
    private func logCaptureDiagnostics(_ s: [Float]) {
        let total = s.count
        let seconds = Double(total) / targetSampleRate
        let (firstPeak, firstRMS) = Self.peakRMS(s.prefix(Int(targetSampleRate)))
        let (allPeak, allRMS) = Self.peakRMS(s)
        // Audio levels only (no content) — mark public so they aren't redacted to
        // <private> in the unified log.
        Self.log.notice("Capture: \(total) samples (\(seconds, format: .fixed(precision: 2), privacy: .public)s) — first-1s peak \(Double(firstPeak), format: .fixed(precision: 4), privacy: .public) rms \(Double(firstRMS), format: .fixed(precision: 4), privacy: .public); overall peak \(Double(allPeak), format: .fixed(precision: 4), privacy: .public) rms \(Double(allRMS), format: .fixed(precision: 4), privacy: .public)")
    }

    private static func peakRMS<C: Collection>(_ s: C) -> (peak: Float, rms: Float) where C.Element == Float {
        guard !s.isEmpty else { return (0, 0) }
        var peak: Float = 0
        var sumSq: Float = 0
        for x in s {
            let a = abs(x)
            if a > peak { peak = a }
            sumSq += x * x
        }
        return (peak, (sumSq / Float(s.count)).squareRoot())
    }

    /// Non-destructive snapshot of samples captured so far (for live transcription).
    var currentSamples: [Float] { samples }

    // MARK: - Private

    private func tearDown() {
        // Setting levelCallback = nil before removeTap / stop acts as a
        // cancellation flag for any in-flight permission callbacks AND for an
        // in-flight warm-up poll (pollWarmUp bails when it sees nil).
        levelCallback = nil
        errorCallback = nil
        onReadyCallback = nil
        didFireReady = false
        warmUpPolling = false
        warmUpDeadline = nil
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

        let inputNode   = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        // The hardware-side input format. `outputFormat(forBus:0)` can report a
        // valid-looking default (e.g. 44.1 kHz/1ch) while the real input stream is
        // still 0ch/0Hz — i.e. the mic route isn't ready yet. Classic triggers:
        // AirPods mid A2DP→HFP switch, or a cold launch / fresh install before the
        // input device has bound. Installing a tap in that state throws an Obj-C
        // exception that SIGABRTs the whole app (observed on the 1.6.0 DMG).
        let hwFormat = inputNode.inputFormat(forBus: 0)

        // No input device, or the input route isn't ready yet. `installTap` with a
        // zero-channel / zero-rate format throws an Obj-C exception that crashes the
        // app — bail to the error pill instead. Checking BOTH formats is what closes
        // the gap: the hardware side (`hwFormat`) catches the "not ready" race that
        // the output side reports as valid.
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            print("[Shhhcribble] ❌ Microphone not ready (out: \(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch, hw: \(hwFormat.sampleRate)Hz/\(hwFormat.channelCount)ch)")
            errorCallback?("Microphone not ready — try again")
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
            // IO is now running, which is what actually drives a cold AirPods
            // route through the A2DP→HFP switch. Wait for the route to come up
            // before telling the caller it's safe to speak.
            beginWarmUpIfNeeded()
        } catch {
            tapInstalled = false
            print("[Shhhcribble] AVAudioEngine start failed: \(error.localizedDescription)")
            errorCallback?("Couldn't start microphone")
        }
    }

    // MARK: - Route warm-up

    /// Begin polling the HAL for input-route readiness, if a caller asked to be
    /// told when it's live. Idempotent across `handleConfigurationChange()`
    /// engine rebuilds (which call `startEngine()` again): the poll queries the
    /// hardware, not this engine instance, so one poll spans the whole switch.
    private func beginWarmUpIfNeeded() {
        guard onReadyCallback != nil, !didFireReady, !warmUpPolling else { return }
        warmUpPolling = true
        warmUpDeadline = .now() + warmUpBudget
        let dev = Self.defaultInputDeviceID()
        Self.log.notice("Warm-up start: input \"\(Self.deviceName(dev), privacy: .public)\" reports \(Self.inputChannelCount(of: dev)) ch")
        pollWarmUp()
    }

    private func pollWarmUp() {
        // Torn down mid-warm-up? `levelCallback` is the cancellation flag.
        guard warmUpPolling, levelCallback != nil else { warmUpPolling = false; return }

        let dev = Self.defaultInputDeviceID()
        let channels = Self.inputChannelCount(of: dev)
        let expired = warmUpDeadline.map { DispatchTime.now() >= $0 } ?? true

        if channels > 0 {
            Self.log.notice("Warm-up ready: \(channels) ch on \"\(Self.deviceName(dev), privacy: .public)\" — discarding pre-roll, going live")
            finishWarmUp()
        } else if expired {
            Self.log.error("Warm-up timed out after \(self.warmUpBudget, format: .fixed(precision: 2))s with 0 ch — going live anyway (may capture silence)")
            finishWarmUp()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + warmUpPollInterval) { [weak self] in
                self?.pollWarmUp()
            }
        }
    }

    private func finishWarmUp() {
        warmUpPolling = false
        didFireReady = true
        warmUpDeadline = nil
        // Drop any silent pre-roll captured while the route was waking so it
        // doesn't dilute the level meter or the final transcript.
        samples.removeAll(keepingCapacity: true)
        let callback = onReadyCallback
        onReadyCallback = nil
        callback?()
    }

    // MARK: - CoreAudio HAL helpers

    /// The system default input device, or 0 if none.
    private static func defaultInputDeviceID() -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : 0
    }

    /// The *actual* number of input channels the hardware currently exposes.
    /// This is the signal that doesn't lie: unlike `AVAudioEngine`'s
    /// `inputFormat(forBus:)` (which reports a nominal format even while AirPods
    /// are mid A2DP→HFP switch), the HAL stream configuration reads 0 until the
    /// mic route is physically live.
    private static func inputChannelCount(of deviceID: AudioDeviceID) -> Int {
        guard deviceID != 0 else { return 0 }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let ablPtr = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablPtr.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ablPtr) == noErr else { return 0 }
        let abl = UnsafeMutableAudioBufferListPointer(ablPtr.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Human-readable device name for diagnostics.
    private static func deviceName(_ deviceID: AudioDeviceID) -> String {
        guard deviceID != 0 else { return "none" }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &name)
        return status == noErr ? (name as String) : "unknown"
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
