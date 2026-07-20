import AVFoundation
import CoreAudio
import os

/// Captures microphone input and converts it to 16 kHz mono Float32 samples
/// required by WhisperKit. A level callback is fired on the main thread with
/// a normalized amplitude (0–1) for the soundwave UI.
///
/// ## Threading model (load-bearing — see the audioQueue decision in CLAUDE.md)
///
/// All public methods must be called on the main thread, and all callbacks
/// (`levelCallback` / `onReady` / `onError`) fire on the main thread. But the
/// engine itself lives on a private serial queue:
///
/// - **Main-owned state:** `samples`, the three callbacks, `didFireReady`, the
///   whole warm-up cluster, and `recordingGeneration`. The warm-up poll runs on
///   main and reads HAL statics only — never the engine.
/// - **audioQueue-owned state:** `engine` (every lifecycle call — alloc,
///   `inputNode`, `installTap`/`removeTap`, `prepare`, `start`, `stop`,
///   `reset`, realloc — happens inside queue blocks), `tapInstalled`, and
///   `activeQueueGeneration`. AVAudioEngine's threading contract is
///   undocumented; the shipping-verified discipline is "serialize every engine
///   call on ONE queue" — this queue. Moving `engine.start()` here is what
///   stops a cold-Bluetooth start (~790 ms measured) from freezing the main
///   actor, delaying the go-signal, and starving the queued keyUp handler.
/// - **Generation tokens bridge the two:** `recordingGeneration` is bumped on
///   main per teardown and captured *by value* into every queue block at
///   enqueue time — never read across threads. Queue→main hops re-check it on
///   main; delayed (`asyncAfter`) queue blocks — which jump the serial FIFO —
///   compare their captured value against the queue-confined
///   `activeQueueGeneration` instead.
/// - **Hard invariant: every hop between main and audioQueue is `async`, in
///   both directions.** No `audioQueue.sync` from main (a cold `engine.start()`
///   may be blocking the queue for ~1 s), and no `DispatchQueue.main.sync` from
///   the queue. This is the structural defense against the documented
///   `AVAudioEngine dealloc → dispatch_sync_f_slow` deadlock class.
/// - **Quit takes no drain:** the OS reaps the HAL client on process death; a
///   sync drain would block termination behind a possibly-blocking start.
///
/// Consequence to know: after `stop()` returns, the engine may keep running for
/// up to ~1 s until the queued teardown lands behind an in-flight cold start.
/// Every callback from that zombie window dies at the main-side generation
/// check, so the rest of the app never observes it.
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
    /// Whether the input route being warmed up is Bluetooth — the channel-count
    /// signal is only trustworthy on non-Bluetooth transports (see `pollWarmUp`).
    /// Re-evaluated on every engine rebuild by `refreshWarmUpRoute()`, so a route
    /// that changes mid-warm-up is judged by its own rules, not the old device's.
    private var warmUpRouteIsBluetooth = false
    /// Set by the tap the first time a converted chunk contains any non-silent
    /// sample. On a cold Bluetooth route the HAL delivers *literal digital zero*
    /// until the A2DP→HFP switch completes, so this is the readiness signal that
    /// actually tracks the hardware. Confirmed by capture diagnostics 2026-07-20:
    /// a cold AirPods take logged `first-1s peak 0.0000` against `overall 0.9462`.
    private var sawNonSilentAudio = false
    /// Max time to wait for the route to come up before going live anyway (so a
    /// genuinely dead mic can't hang recording forever). Generous because the
    /// HFP engage can take a few hundred ms; the warm path returns on the first
    /// poll so this ceiling is only ever hit by a truly stuck route.
    private let warmUpBudget: TimeInterval = 1.2
    /// Bluetooth needs a longer ceiling: we're waiting on a physical codec
    /// switch, not just a device binding. Only ever paid on a genuinely cold
    /// route — a warm one delivers audio within a poll or two.
    private let btWarmUpBudget: TimeInterval = 2.0
    /// Bluetooth-only **backstop**, not the primary signal: go live once the
    /// route has had this long even if we've heard nothing at all.
    ///
    /// It does NOT need to cover "the user hasn't spoken yet" — a *live* mic
    /// always emits room tone (0.0133+ peak in field captures), orders of
    /// magnitude above `silenceEpsilon`, so `sawNonSilentAudio` trips when the
    /// **route goes live**, not when the user speaks. A user sitting silent is
    /// served by room tone within a buffer of the HFP switch landing.
    ///
    /// This only covers the pathological case of a live route emitting true
    /// digital zero. It must therefore sit **above** the measured dead window —
    /// the cold capture read `first-1s peak 0.0000`, so the mic was dead for at
    /// least 1.0 s. A shorter value would fire "go" into a still-dead mic and
    /// re-introduce the exact bug this fix exists to kill.
    private let btMinDwell: TimeInterval = 1.5
    private var warmUpStartedAt: DispatchTime?
    /// When the warm-up *first* began, never re-armed. `refreshWarmUpRoute()`
    /// pushes `warmUpDeadline` out on every route change, so a flapping route
    /// could otherwise delay `onReady` — and therefore the recording pill —
    /// forever. This is the absolute backstop.
    ///
    /// Known bounded gap (accepted): this can expire while audioQueue is still
    /// blocked inside a rebuild's `engine.start()`, firing `onReady` — the "go"
    /// pill — against an engine that isn't running yet. Worst case ≈ 1.1 s of
    /// lost speech until the rebuild lands and its tap resumes appending. No
    /// corruption (samples are main-owned) and strictly better than hanging;
    /// "a dead mic must never hang recording forever" is the older invariant.
    private var warmUpHardDeadline: DispatchTime?
    private let warmUpHardCeiling: TimeInterval = 3.0
    private let warmUpPollInterval: TimeInterval = 0.025
    /// Amplitude below which a sample counts as digital silence. A *dead*
    /// Bluetooth route delivers exactly 0.0000; a *live* one never has, even on
    /// a quiet first second — field captures floor at 0.0133/0.0450 peak on
    /// AirPods and 0.0016 rms on the built-in mic. 1e-4 sits two orders of
    /// magnitude below the live floor and above the dead one.
    static let silenceEpsilon: Float = 1e-4
    /// Bumped per recording so a tap callback still in flight when the tap is
    /// removed cannot set `sawNonSilentAudio` for the *next* recording — that
    /// would silently restore the pre-fix "ready on first poll" behaviour.
    /// Main-owned: written on main, read on main, captured by value into queue
    /// blocks at enqueue time. Never read across threads.
    private var recordingGeneration: UInt64 = 0

    // MARK: Engine queue (see the threading model in the class doc)

    /// Owns every AVAudioEngine lifecycle call. Serial, so start → rebuild →
    /// teardown can never reorder. `.userInitiated`, NOT `.userInteractive` —
    /// a user-interactive queue triggers documented priority-inversion warnings
    /// inside AVAudioEngine's own machinery.
    private let audioQueue = DispatchQueue(label: "com.shhhcribble.audio-engine",
                                           qos: .userInitiated)
    /// Queue-confined mirror of the generation the queue currently serves. Set
    /// at the top of every immediately-enqueued block from the value captured
    /// on main at enqueue time. Exists for the one thing FIFO can't cover:
    /// `asyncAfter` retry blocks are submitted at *fire* time, jumping the
    /// FIFO — a stale retry from recording N firing after recording N+1's
    /// bring-up would otherwise start an engine whose tap output is silently
    /// generation-dropped, leaving N+1 with no samples. Delayed blocks compare
    /// against this and drop on mismatch. Touched ONLY on audioQueue.
    private var activeQueueGeneration: UInt64 = 0

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

    /// Start recording. Returns in microseconds — the engine bring-up
    /// (including the ~790 ms `engine.start()` block on a cold Bluetooth
    /// route) runs on `audioQueue`, so the main actor stays responsive and
    /// the hotkey keyUp is processed on time. `levelCallback` is called on
    /// the main thread with a 0–1 amplitude for the soundwave animation;
    /// `onReady` fires on main once the input route is physically live;
    /// `onError` fires on main when audio setup fails.
    func start(levelCallback: @escaping (Float) -> Void,
               onReady: (() -> Void)? = nil,
               onError: ((String) -> Void)? = nil) {
        // Reset main-side state from any previous session; the engine half of
        // the cleanup is enqueued below, ahead of this recording's bring-up.
        tearDownBookkeeping()

        self.levelCallback = levelCallback
        self.errorCallback = onError
        self.onReadyCallback = onReady
        self.didFireReady = false
        samples.removeAll(keepingCapacity: true)

        // Synchronous permission guard, belt-and-braces: AppDelegate's
        // beginRecording() fully resolves permission (prompt included) before
        // ever calling start(), so a prompt can never be needed here. The old
        // in-house requestAccess round-trip added an async hop whose "callback
        // fired after stop()" staleness class this guard deletes outright.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            print("[Shhhcribble] Microphone permission not granted.")
            // failOnMain reads errorCallback at fire time under a generation
            // check — so a stop() landing before the hop drops this error, the
            // same way the old async-requestAccess path did.
            failOnMain(generation: recordingGeneration, "Microphone permission denied")
            return
        }

        // ONE enqueue: tear down any prior engine and bring up the fresh one in
        // a single block, so the queue's view of the engine is always coherent.
        let generation = recordingGeneration
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.activeQueueGeneration = generation
            self.tearDownEngineBody()
            self.bringUpEngineBody(generation: generation, retriesLeft: 0)
        }
    }

    /// Stop recording and return the captured samples. Still synchronous for
    /// its return value — `samples` is main-owned, so the snapshot is
    /// immediate. The engine teardown is enqueued async behind any in-flight
    /// bring-up (never `queue.sync`: a cold start may be blocking the queue,
    /// and main must not wait on it).
    func stop() -> [Float] {
        let captured = samples
        logCaptureDiagnostics(captured)
        tearDownBookkeeping()
        let generation = recordingGeneration
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.activeQueueGeneration = generation
            self.tearDownEngineBody()
        }
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

    /// Main-side half of the old `tearDown()`: reset every main-owned field and
    /// bump the generation, invalidating all in-flight callbacks/hops/retries
    /// for the recording being torn down. Never touches the engine.
    private func tearDownBookkeeping() {
        // Setting levelCallback = nil acts as the cancellation flag for the
        // in-flight warm-up poll (pollWarmUp bails when it sees nil) and gates
        // handleConfigurationChange's "is a recording wanted" check.
        levelCallback = nil
        errorCallback = nil
        onReadyCallback = nil
        didFireReady = false
        warmUpPolling = false
        warmUpDeadline = nil
        warmUpRouteIsBluetooth = false
        sawNonSilentAudio = false
        warmUpStartedAt = nil
        warmUpHardDeadline = nil
        // Invalidate any tap callback / queue hop still in flight.
        recordingGeneration &+= 1
        samples.removeAll(keepingCapacity: true)
    }

    /// Queue-side half of the old `tearDown()`. MUST run on `audioQueue`, and
    /// is only ever called from inside queue blocks. The old engine instance
    /// deallocs here, on the queue — never on main.
    private func tearDownEngineBody() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        engine.reset()
        engine = AVAudioEngine()  // new instance fully releases the CoreAudio device
    }

    /// Fire an error callback on main, generation-checked so an error from a
    /// dead recording can never abort its successor (handleAudioError tears the
    /// whole recording state machine down — a stale one would be catastrophic).
    private func failOnMain(generation: UInt64, _ message: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.recordingGeneration == generation else { return }
            self.errorCallback?(message)
        }
    }

    /// Engine bring-up. MUST run on `audioQueue` — this is where the blocking
    /// `engine.prepare()` / `engine.start()` live now.
    ///
    /// - Parameter generation: captured on main at enqueue time; every hop back
    ///   to main re-checks it there, and delayed retries check it against the
    ///   queue-confined `activeQueueGeneration`.
    /// - Parameter retriesLeft: how many more times to re-poll for a default
    ///   input device before declaring "no microphone". Non-zero only on the
    ///   `handleConfigurationChange()` rebuild path, where a route handoff can
    ///   momentarily report no device.
    private func bringUpEngineBody(generation: UInt64, retriesLeft: Int) {
        // Guard against double bring-up (rebuild blocks always tear down first,
        // so this should never fire — defensive).
        guard !tapInstalled else { return }

        // No input device AT ALL (e.g. a Mac mini with nothing plugged in).
        // This must be checked via the HAL *before* touching `engine.inputNode`
        // below: with zero input devices, merely asking AVAudioEngine for its
        // input node raises an Obj-C exception, which Swift cannot catch — it
        // SIGABRTs the whole app. The 0ch/0Hz format guard further down is too
        // late, and only covers a device that exists but isn't ready yet.
        guard Self.defaultInputDeviceID() != 0 else {
            // On the mid-recording rebuild path the default input can read 0 for
            // a moment during a handoff (AirPods → built-in). Don't kill a live
            // dictation for a transient gap — retry a few ticks before giving up.
            if retriesLeft > 0 {
                Self.log.notice("No input device yet — retrying (\(retriesLeft) left)")
                audioQueue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    // asyncAfter jumps the serial FIFO (submitted at fire time),
                    // so this is exactly the block that must compare against the
                    // queue's authoritative generation: a teardown or a newer
                    // recording's bring-up may have run in the meantime.
                    guard let self, self.activeQueueGeneration == generation,
                          !self.tapInstalled else { return }
                    self.bringUpEngineBody(generation: generation,
                                           retriesLeft: retriesLeft - 1)
                }
                return
            }
            Self.log.error("No input device present — refusing to touch engine.inputNode")
            failOnMain(generation: generation, "No microphone found")
            return
        }

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
            failOnMain(generation: generation, "Microphone not ready — try again")
            return
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            print("[Shhhcribble] Could not create AVAudioConverter.")
            failOnMain(generation: generation, "Audio converter unavailable")
            return
        }

        tapInstalled = true
        // The converter is created here on the queue and used on the render
        // thread; installTap's hand-off establishes happens-before, and nothing
        // mutates it afterwards. The closure captures `generation` by value —
        // its main hop below re-checks it on main, unchanged from before.
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
            // Does this chunk contain anything but digital silence? On a cold
            // Bluetooth route the answer is no until the HFP switch lands.
            let hasAudio = chunk.contains { abs($0) > Self.silenceEpsilon }

            DispatchQueue.main.async {
                // Drop a straggler from a previous recording (removeTap can return
                // while a callback is still in flight on the render thread).
                guard self.recordingGeneration == generation else { return }
                self.samples.append(contentsOf: chunk)
                if hasAudio { self.sawNonSilentAudio = true }
                self.levelCallback?(level)
            }
        }

        // Pre-warm the route so CoreAudio wakes the (possibly Bluetooth) input
        // device before we call start(). Helps the "first AirPods record does
        // nothing" glitch.
        engine.prepare()

        do {
            // THE blocker: ~790 ms measured on a cold Bluetooth route (this
            // call is what drives the A2DP→HFP switch). It burns audioQueue's
            // thread, not the main actor — the whole point of this design.
            try engine.start()
            // IO is now running. Hand off to the main-owned warm-up state
            // machine, which decides when the route is actually live and fires
            // onReady. Generation-checked: a stop()/newer start() that landed
            // on main while we were blocking must not get a stale warm-up.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.recordingGeneration == generation else { return }
                self.beginWarmUpIfNeeded()
            }
        } catch {
            // Remove the tap we just installed BEFORE clearing the flag. The
            // queue invariant "tapInstalled == false ⟹ no tap on the current
            // engine" is what the delayed-retry guard relies on; leaving an
            // orphaned tap here would let a same-generation retry re-install on
            // a bus that already has one — an NSException → SIGABRT. (Newly
            // reachable now that error delivery hops async to main: the old
            // synchronous path always tore down before a retry could fire.)
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
            print("[Shhhcribble] AVAudioEngine start failed: \(error.localizedDescription)")
            failOnMain(generation: generation, "Couldn't start microphone")
        }
    }

    // MARK: - Route warm-up

    /// Begin polling the HAL for input-route readiness, if a caller asked to be
    /// told when it's live. Runs on main (called via the generation-checked hop
    /// after `engine.start()` succeeds on audioQueue). Idempotent across
    /// `handleConfigurationChange()` engine rebuilds: the poll queries the
    /// hardware, not any engine instance, so one poll spans the whole switch —
    /// including windows where the queue is still rebuilding the engine.
    private func beginWarmUpIfNeeded() {
        guard onReadyCallback != nil, !didFireReady else { return }
        // Already polling? This is a `handleConfigurationChange()` rebuild — on a
        // cold Bluetooth route the config-change notification IS the HFP switch,
        // and it can arrive late and more than once. Refresh the clock and the
        // transport rather than letting the original deadline expire mid-switch
        // (which would `removeAll()` the very samples the rebuild preserved).
        if warmUpPolling {
            refreshWarmUpRoute()
            return
        }
        warmUpPolling = true
        warmUpHardDeadline = .now() + warmUpHardCeiling
        refreshWarmUpRoute()
        let dev = Self.defaultInputDeviceID()
        Self.log.notice("Warm-up start: input \"\(Self.deviceName(dev), privacy: .public)\" reports \(Self.inputChannelCount(of: dev)) ch, transport \(self.warmUpRouteIsBluetooth ? "Bluetooth" : "wired/built-in", privacy: .public)")
        pollWarmUp()
    }

    private func pollWarmUp() {
        // Torn down mid-warm-up? `levelCallback` is the cancellation flag.
        guard warmUpPolling, levelCallback != nil else { warmUpPolling = false; return }

        let dev = Self.defaultInputDeviceID()
        let channels = Self.inputChannelCount(of: dev)
        let now = DispatchTime.now()
        // Either the (re-armable) per-route deadline or the absolute backstop.
        let expired = (warmUpDeadline.map { now >= $0 } ?? true)
            || (warmUpHardDeadline.map { now >= $0 } ?? false)

        let dwelled = warmUpStartedAt.map { now >= $0 + btMinDwell } ?? true
        let ready = Self.warmUpIsReady(isBluetooth: warmUpRouteIsBluetooth,
                                       channels: channels,
                                       sawAudio: sawNonSilentAudio,
                                       dwellElapsed: dwelled)

        if ready {
            Self.log.notice("Warm-up ready: \(channels) ch on \"\(Self.deviceName(dev), privacy: .public)\" (audio seen: \(self.sawNonSilentAudio, privacy: .public)) — trimming silent pre-roll, going live")
            finishWarmUp(sawAudio: sawNonSilentAudio)
        } else if expired {
            Self.log.error("Warm-up timed out after \(self.warmUpDeadlineBudget, format: .fixed(precision: 2))s (\(channels) ch, audio seen: \(self.sawNonSilentAudio, privacy: .public)) — going live anyway (may capture silence)")
            finishWarmUp(sawAudio: sawNonSilentAudio)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + warmUpPollInterval) { [weak self] in
                self?.pollWarmUp()
            }
        }
    }

    /// (Re-)evaluate the transport and (re-)arm the warm-up clock against the
    /// device that is current *now*. Called at warm-up start and again on every
    /// `handleConfigurationChange()` rebuild, because the route can change
    /// underneath us mid-warm-up (AirPods yanked → built-in mic, or the HFP
    /// switch landing late). Latching either value once would judge the new
    /// device by the old device's rules.
    private func refreshWarmUpRoute() {
        let nowBluetooth = Self.isBluetoothDevice(Self.defaultInputDeviceID())
        // Swapped transport mid-warm-up? Evidence gathered from the OLD device
        // says nothing about the new one — e.g. built-in room tone must not
        // certify a freshly-attached, still-cold Bluetooth mic as live.
        if nowBluetooth != warmUpRouteIsBluetooth { sawNonSilentAudio = false }
        warmUpRouteIsBluetooth = nowBluetooth
        let now = DispatchTime.now()
        warmUpStartedAt = now
        warmUpDeadline = now + (warmUpRouteIsBluetooth ? btWarmUpBudget : warmUpBudget)
    }

    /// The transport-branched readiness rule. Pure and `internal` so it can be
    /// unit-tested; `pollWarmUp` owns the side effects.
    ///
    /// On Bluetooth the channel count lies: a cold AirPods route reports 1 ch
    /// instantly while the mic still delivers digital zero through the
    /// A2DP→HFP switch (proven by capture diagnostics 2026-07-20). So require
    /// real audio too — OR that the route has had `btMinDwell` to settle, so a
    /// silent user isn't held waiting for a sound they haven't made. On
    /// wired/built-in the channel count is trustworthy and this stays a
    /// first-tick, zero-cost check.
    static func warmUpIsReady(isBluetooth: Bool, channels: Int,
                              sawAudio: Bool, dwellElapsed: Bool) -> Bool {
        isBluetooth ? (channels > 0 && (sawAudio || dwellElapsed))
                    : channels > 0
    }

    /// How many leading samples are digital silence — i.e. how much of a cold
    /// route's dead pre-roll to drop. Returns 0 when the very first sample is
    /// already audible, and `count` when the whole buffer is silent.
    /// Pure and `internal` so it can be unit-tested.
    static func leadingSilenceCount(_ s: [Float], epsilon: Float = AudioRecorder.silenceEpsilon) -> Int {
        s.firstIndex { abs($0) > epsilon } ?? s.count
    }

    /// The ceiling actually in force for this warm-up, for logging.
    private var warmUpDeadlineBudget: TimeInterval {
        warmUpRouteIsBluetooth ? btWarmUpBudget : warmUpBudget
    }

    /// - Parameter sawAudio: whether real (non-silent) audio was observed. When
    ///   true we trim only the leading silence, preserving anything the user
    ///   already said; when false (dead mic / timed out) the whole pre-roll is
    ///   silence and gets dropped, as before.
    private func finishWarmUp(sawAudio: Bool) {
        warmUpPolling = false
        didFireReady = true
        warmUpDeadline = nil
        warmUpHardDeadline = nil
        warmUpStartedAt = nil
        // Drop the silent pre-roll captured while the route was waking so it
        // doesn't dilute the level meter or the final transcript. Crucially,
        // trim ONLY the leading silence rather than everything: on a cold
        // Bluetooth route the user may have started speaking during the dwell,
        // and those words are real audio we can still keep. (A fixed warm-up
        // dwell would have thrown them away — this is why we wait on the audio
        // itself rather than on a timer.)
        if sawAudio {
            samples.removeFirst(Self.leadingSilenceCount(samples))
        } else {
            samples.removeAll(keepingCapacity: true)
        }
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

    /// Whether the device sits on a Bluetooth transport. Deliberately duplicated
    /// from `MusicPauser` (which asks the same of the *output* device) rather
    /// than shared — ~10 lines is cheaper than coupling two audio subsystems.
    private static func isBluetoothDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID != 0 else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &transport)
        guard status == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth
            || transport == kAudioDeviceTransportTypeBluetoothLE
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
    /// default input switches). Runs on main (observer queue .main); the actual
    /// engine rebuild is enqueued async onto audioQueue — the SDK header for
    /// this notification explicitly warns against synchronous engine teardown
    /// in the handler (internal-queue deadlock).
    ///
    /// Samples and callbacks are main-owned and the queue-side rebuild never
    /// touches them, so the old "preserve and restore samples across the
    /// restart" dance is gone by construction — the rebuild *cannot* lose them.
    /// The generation is deliberately NOT bumped: this is the same recording,
    /// and pre-rebuild tap stragglers must still land.
    private func handleConfigurationChange() {
        // "Is a recording wanted" is the main-owned levelCallback (tapInstalled
        // is queue-owned now). Deliberately wider than the old tapInstalled
        // check: a config change arriving before the bring-up completes should
        // still schedule a rebuild — FIFO orders it after the bring-up.
        guard levelCallback != nil else { return }
        print("[Shhhcribble] Audio configuration changed — restarting engine")

        // Re-arm the warm-up clock NOW, on main, before the rebuild queues.
        // On a cold Bluetooth route this notification IS the HFP switch; with
        // main no longer blocked during the rebuild, the re-armable deadline
        // could otherwise expire while the rebuild is still waiting behind a
        // blocking engine.start() — and finishWarmUp would discard the very
        // samples this rebuild exists to preserve. (warmUpHardDeadline is
        // NOT re-armed — the flapping-route backstop stays absolute.)
        if warmUpPolling { refreshWarmUpRoute() }

        let generation = recordingGeneration
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.activeQueueGeneration = generation
            self.tearDownEngineBody()
            // Tolerate a brief device gap during the handoff rather than
            // aborting a live dictation (see the retry note on bringUpEngineBody).
            self.bringUpEngineBody(generation: generation, retriesLeft: 6)
        }
    }
}
