import CoreAudio
import Foundation
import os

/// Runs NSAppleScript on a dedicated background thread that keeps a live run loop.
///
/// **Why a whole thread and not a GCD queue:** `NSAppleScript.executeAndReturnError`
/// sends an Apple Event to Spotify/Music and *waits for the reply*; that wait is
/// delivered through a run loop on the calling thread. A GCD queue worker has no
/// run loop, so the reply wait can stall there. The main thread *does* have a run
/// loop, but keeping the pause off it during recording start is the entire point
/// (see the MusicPauser decision in CLAUDE.md). So we own one thread with a run
/// loop. A single serial thread also preserves pause→resume ordering for free:
/// resume is always enqueued after the pause that populated the state it reads.
private final class ScriptThread: NSObject {
    private var thread: Thread!

    override init() {
        super.init()
        let t = Thread(target: self, selector: #selector(main), object: nil)
        t.name = "com.shhhcribble.musicpauser"
        t.stackSize = 1 << 20
        t.start()
        thread = t
    }

    @objc private func main() {
        // A mach port gives the run loop a source, so `run` blocks waiting for
        // input instead of returning immediately and busy-spinning the `while`.
        let rl = RunLoop.current
        rl.add(NSMachPort(), forMode: .default)
        while !Thread.current.isCancelled {
            rl.run(mode: .default, before: .distantFuture)
        }
    }

    /// Enqueue a block on the thread — FIFO, fire-and-forget.
    func async(_ block: @escaping () -> Void) {
        perform(#selector(runBox(_:)), on: thread, with: Box(block), waitUntilDone: false)
    }

    /// Enqueue a block and block the caller until it finishes. Used only on app
    /// quit, where the resume must complete before the process exits.
    func sync(_ block: @escaping () -> Void) {
        perform(#selector(runBox(_:)), on: thread, with: Box(block), waitUntilDone: true)
    }

    @objc private func runBox(_ box: Box) { box.block() }

    private final class Box: NSObject {
        let block: () -> Void
        init(_ block: @escaping () -> Void) { self.block = block }
    }
}

/// Pauses Spotify and Apple Music during recording, resumes them on stop.
/// Uses AppleScript directly to each app — no private APIs, no Bluetooth
/// audio bridge, no system-volume side effects. Works identically on
/// AirPods, built-in speakers, USB DACs, and HDMI.
///
/// **Off-main (Fix B):** every AppleScript call runs on a private `ScriptThread`,
/// never the main actor. The pause used to run synchronously inline in
/// `AppDelegate.actuallyBeginRecording()`, blocking the main thread for hundreds
/// of ms per playing app (an Apple Events round-trip each) *before* the engine
/// started and before the "Waking mic…" placeholder's timer could fire. Now the
/// public methods just enqueue work and return instantly, so recording start is
/// no longer gated on the music apps answering.
///
/// **Coverage scope:** Spotify and Apple Music only. YouTube and other
/// browser-tab audio are NOT paused — the user accepted this trade-off
/// (Spotify is the dominant use case). Layering browser-tab JS injection
/// on top is possible later without changing the Spotify path.
///
/// **Why not MediaRemote / Now Playing:** The previous iteration tried
/// `MRMediaRemoteGetNowPlayingApplicationIsPlaying`, which Apple
/// progressively locked down starting in macOS 15.4. On macOS 26 the
/// IsPlaying call returns `false` even when Spotify is actively playing,
/// making the entire pause-detection unusable. AppleScript is the
/// deterministic alternative — slightly more permission friction (one TCC
/// prompt per app first time), but it works.
///
/// **Why not just send media keys:** Sending Pause unconditionally risks
/// ambiguity on resume — if the user had paused Spotify themselves, we'd
/// send Play and start music they'd intentionally silenced. AppleScript
/// asks "are you currently playing?" first, so we only resume what we
/// paused.
final class MusicPauser {

    private static let logger = Logger(subsystem: "com.shhhcribble.app", category: "pauser")

    /// The private thread every AppleScript call runs on. Fix B: keeps the
    /// synchronous Apple Events round-trips off the main actor.
    private let scriptThread = ScriptThread()

    /// Per-app state — resume only what we paused. **Touched ONLY on
    /// `scriptThread`** (all reads and writes run inside its blocks), so it needs
    /// no extra locking. Serial ordering on that thread guarantees a resume sees
    /// the pause that preceded it.
    private var pausedApps: Set<TargetApp> = []

    /// Bumped once per recording (at pause). A *delayed* resume captures the
    /// generation it was scheduled for and skips if a newer recording has paused
    /// since — otherwise recording 1's 2100 ms resume timer could fire during
    /// recording 2 (rapid back-to-back dictation inside the BT settle window) and
    /// un-pause music mid-capture. Read/written only on `scriptThread`.
    private var generation = 0

    private enum TargetApp: String, CaseIterable {
        case spotify = "Spotify"
        case music   = "Music"
    }

    /// Pause any playing target apps. Returns immediately; the AppleScript runs
    /// on `scriptThread` so recording start is never blocked on it.
    func pauseIfPlaying() {
        scriptThread.async { [weak self] in
            guard let self else { return }
            self.generation &+= 1
            for app in TargetApp.allCases where self.pauseIfPlaying(app) {
                self.pausedApps.insert(app)
            }
        }
    }

    /// Resume what we paused, now. Used by cancel / error paths. Returns
    /// immediately; enqueued after any in-flight pause, so FIFO ordering
    /// guarantees it sees the paused set.
    func resumeIfPaused() {
        scriptThread.async { [weak self] in self?.resumeAll() }
    }

    /// Synchronous resume for app quit — the process is about to exit, so the
    /// resume must finish before we return (a fire-and-forget hop might not run
    /// in time and would strand the user's music paused).
    func resumeIfPausedSync() {
        scriptThread.sync { [weak self] in self?.resumeAll() }
    }

    /// Resume every paused app and clear the set. **Must run on `scriptThread`.**
    private func resumeAll() {
        for app in pausedApps { resume(app) }
        pausedApps.removeAll()
    }

    /// Schedules `resumeIfPaused()` to fire once the audio system has
    /// settled, so music doesn't collide with the scribble chime or — on
    /// AirPods — play briefly through the still-active mic codec (HFP)
    /// before the route switches back to A2DP.
    ///
    /// On Bluetooth outputs: 2100 ms fixed delay. Sized to clear the full
    /// HFP→A2DP transition plus buffer flush. We tried a `kAudioDevicePropertyNominalSampleRate`
    /// listener to resume early when the codec switch fires, but it never
    /// fires on AirPods in practice — the default output device swaps
    /// between A2DP and HFP virtual devices, leaving our listener attached
    /// to one that's no longer current. Fixed delay is simpler and
    /// behaviorally identical.
    ///
    /// On non-Bluetooth outputs: 700 ms — no codec switch to wait on, just
    /// the chime/paste breathing room.
    ///
    /// Fire-and-forget. Safe to call when nothing is paused — the deferred
    /// `resumeIfPaused()` is a no-op then (empty paused set).
    func scheduleResumeAfterOutputSettles() {
        let isBluetooth = Self.defaultOutputDevice().map { Self.isBluetoothDevice($0) } ?? false
        let delayMs = isBluetooth ? 2100 : 700
        Self.logger.notice("scheduleResume: \(isBluetooth ? "BT" : "non-BT", privacy: .public) output — \(delayMs)ms delay")

        // Capture this recording's generation on `scriptThread` (after its pause
        // has run), then resume only if no newer recording paused in the meantime.
        scriptThread.async { [weak self] in
            guard let self else { return }
            let scheduledGen = self.generation
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(delayMs))
                self?.resumeIfPaused(ifGeneration: scheduledGen)
            }
        }
    }

    /// Delayed-resume path: resume only if the recording that scheduled it is
    /// still the current one. A newer `pauseIfPlaying()` bumps `generation`, which
    /// supersedes this stale timer.
    private func resumeIfPaused(ifGeneration gen: Int) {
        scriptThread.async { [weak self] in
            guard let self else { return }
            guard self.generation == gen else {
                Self.logger.notice("scheduleResume: superseded by newer recording (gen \(self.generation, privacy: .public) ≠ \(gen, privacy: .public)) — skip")
                return
            }
            self.resumeAll()
        }
    }

    // MARK: - Per-app actions (run on `scriptThread`)

    /// Returns true iff the app was running, was playing, and we paused it.
    /// Returns false if the app isn't running, isn't playing, or AppleScript
    /// errored (e.g., user denied TCC).
    private func pauseIfPlaying(_ app: TargetApp) -> Bool {
        // The `running` guard avoids launching the app just to query state.
        // The `player state is playing` guard avoids the case where the user
        // has the app open but already paused — we don't want to send pause
        // again (no-op, but also nothing to track for resume).
        // `with timeout` bounds the Apple Event reply wait (default is ~60 s) so a
        // wedged music app can't hang the script thread — or, at quit, the main
        // thread via resumeIfPausedSync. On timeout, executeAndReturnError returns
        // an error → treated as "not paused", so nothing is tracked or stranded.
        let source = """
        with timeout of 5 seconds
            if application "\(app.rawValue)" is running then
                tell application "\(app.rawValue)"
                    if player state is playing then
                        pause
                        return "paused"
                    end if
                end tell
            end if
        end timeout
        return "no"
        """
        let result = run(source, label: "pause \(app.rawValue)")
        let paused = (result == "paused")
        Self.logger.notice("pause \(app.rawValue, privacy: .public): \(paused ? "paused" : "skipped", privacy: .public)")
        return paused
    }

    private func resume(_ app: TargetApp) {
        // No state check on resume: telling Spotify/Music to "play" while
        // already playing is a no-op in both apps, so we don't risk
        // double-starting anything. Keeping this simple — the per-app
        // flag in pausedApps already gates whether we attempt resume at all.
        let source = """
        with timeout of 5 seconds
            if application "\(app.rawValue)" is running then
                tell application "\(app.rawValue)" to play
            end if
        end timeout
        """
        _ = run(source, label: "resume \(app.rawValue)")
        Self.logger.notice("resume \(app.rawValue, privacy: .public): sent")
    }

    // MARK: - AppleScript runner

    /// Runs an AppleScript synchronously and returns its string result, or
    /// nil on error. **Called only on `scriptThread`**, which has a live run
    /// loop to receive the target app's Apple Event reply. Errors are logged at
    /// .error so a denied-TCC prompt or app crash shows up in `log stream`.
    @discardableResult
    private func run(_ source: String, label: String) -> String? {
        guard let script = NSAppleScript(source: source) else {
            Self.logger.error("\(label, privacy: .public): NSAppleScript init failed")
            return nil
        }
        var error: NSDictionary?
        let descriptor = script.executeAndReturnError(&error)
        if let error = error {
            // -1743 = "Not authorised" (TCC denied or not yet granted).
            // -600  = "Application isn't running" — race; treat as benign.
            // Anything else gets surfaced verbatim for debugging.
            let code = (error[NSAppleScript.errorNumber] as? Int) ?? 0
            let message = (error[NSAppleScript.errorMessage] as? String) ?? "unknown"
            Self.logger.error("\(label, privacy: .public): error \(code, privacy: .public) — \(message, privacy: .public)")
            return nil
        }
        return descriptor.stringValue
    }

    // MARK: - Core Audio: output device transport

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    private static func isBluetoothDevice(_ deviceID: AudioDeviceID) -> Bool {
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
}
