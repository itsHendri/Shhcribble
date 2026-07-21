import CoreAudio
import Foundation
import os

/// Detects when a known call app (WhatsApp, Zoom, FaceTime…) starts using the
/// microphone, so AppDelegate can offer a one-tap "transcribe this call?".
///
/// Pure detection — this class never records, never touches AVAudioEngine,
/// and never interferes with `AudioRecorder`. Two CoreAudio HAL signals:
///
/// 1. `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input
///    device fires the instant ANY process starts/stops mic IO (macOS 14.0+).
/// 2. Attribution — WHICH app — comes from the AudioProcess objects
///    (`kAudioHardwarePropertyProcessObjectList` +
///    `kAudioProcessPropertyIsRunningInput` / `BundleID`), the same API family
///    Granola-class apps use. The property constants compile everywhere; on
///    macOS < 14.4 the queries fail gracefully and detection simply never
///    fires (Settings surfaces this).
///
/// Our own process is always excluded, so Shhhcribble's own dictation can
/// never self-trigger a prompt. All callbacks fire on the main thread.
///
/// Episode semantics: one prompt per continuous mic-busy episode. The flag
/// re-arms only after the mic has been idle for `idleResetSeconds`, so a
/// dismissed prompt doesn't nag again mid-call, but the next call prompts.
final class CallDetector {

    private static let log = Logger(subsystem: "com.shhhcribble.app", category: "calldetect")

    /// Curated trigger list (design decision: known call apps only — no
    /// browser tabs, games, or screen recorders). Extend as users report apps.
    static let knownCallApps: [String: String] = [
        "net.whatsapp.WhatsApp":            "WhatsApp",
        "us.zoom.xos":                      "Zoom",
        "com.microsoft.teams2":             "Microsoft Teams",
        "com.microsoft.teams":              "Microsoft Teams",
        "com.apple.FaceTime":               "FaceTime",
        "com.tinyspeck.slackmacgap":        "Slack",
        "com.hnc.Discord":                  "Discord",
        "ru.keepcoder.Telegram":            "Telegram",
        "org.whispersystems.signal-desktop": "Signal",
        "Cisco-Systems.Spark":              "Webex",
        "com.skype.skype":                  "Skype",
    ]

    /// First known call app among the given bundle ids, or nil.
    /// Pure and `internal` so it can be unit-tested.
    static func firstKnownCallApp(in bundleIDs: [String]) -> (id: String, name: String)? {
        for id in bundleIDs {
            if let name = knownCallApps[id] { return (id, name) }
        }
        return nil
    }

    /// Fired (main thread) when a known call app starts using the mic.
    /// Argument: the app's display name.
    var onCallDetected: ((String) -> Void)?

    private(set) var isMonitoring = false
    private var promptedThisEpisode = false
    private var listeningDeviceID: AudioDeviceID = 0
    private var runningListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    /// Attribution can lag the running signal by a beat (the call app's IO
    /// registers just after the device spins up), so a miss re-checks once.
    private let recheckDelay: TimeInterval = 1.5
    private let idleResetSeconds: TimeInterval = 5
    private var idleResetWorkItem: DispatchWorkItem?

    // MARK: - Lifecycle (main thread)

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        attachToDefaultInput()
        watchDefaultInputChanges()
        Self.log.notice("Call detection started")
    }

    func stop() {
        guard isMonitoring else { return }
        isMonitoring = false
        detachRunningListener()
        if let l = defaultDeviceListener {
            var addr = Self.defaultInputAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr, .main, l)
            defaultDeviceListener = nil
        }
        idleResetWorkItem?.cancel()
        idleResetWorkItem = nil
        promptedThisEpisode = false
        Self.log.notice("Call detection stopped")
    }

    // MARK: - Listeners

    private static var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private static var runningSomewhereAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func watchDefaultInputChanges() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, self.isMonitoring else { return }
            // The default input moved (AirPods in/out) — follow it.
            self.detachRunningListener()
            self.attachToDefaultInput()
        }
        defaultDeviceListener = block
        var addr = Self.defaultInputAddress
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
    }

    private func attachToDefaultInput() {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = Self.defaultInputAddress
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
            deviceID != 0 else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.evaluateMicActivity()
        }
        runningListener = block
        listeningDeviceID = deviceID
        var runAddr = Self.runningSomewhereAddress
        AudioObjectAddPropertyListenerBlock(deviceID, &runAddr, .main, block)
        // Catch a call that is ALREADY running when monitoring starts.
        evaluateMicActivity()
    }

    private func detachRunningListener() {
        if let l = runningListener, listeningDeviceID != 0 {
            var runAddr = Self.runningSomewhereAddress
            AudioObjectRemovePropertyListenerBlock(listeningDeviceID, &runAddr, .main, l)
        }
        runningListener = nil
        listeningDeviceID = 0
    }

    // MARK: - Evaluation (main thread)

    private func evaluateMicActivity() {
        guard isMonitoring else { return }
        if !Self.deviceIsRunningSomewhere(listeningDeviceID) {
            // Mic gone idle: re-arm the per-episode prompt after a grace
            // window (call apps can briefly release/reacquire mid-call).
            idleResetWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.promptedThisEpisode = false
            }
            idleResetWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + idleResetSeconds,
                                          execute: item)
            return
        }
        idleResetWorkItem?.cancel()
        idleResetWorkItem = nil
        guard !promptedThisEpisode else { return }

        if let match = Self.firstKnownCallApp(in: Self.bundleIDsRunningInput()) {
            promptedThisEpisode = true
            Self.log.notice("Call detected: \(match.name, privacy: .public) is using the microphone")
            onCallDetected?(match.name)
        } else {
            // Mic is busy but attribution found no known app yet — the call
            // app's IO may register a beat later. One delayed re-check.
            DispatchQueue.main.asyncAfter(deadline: .now() + recheckDelay) { [weak self] in
                guard let self, self.isMonitoring, !self.promptedThisEpisode,
                      Self.deviceIsRunningSomewhere(self.listeningDeviceID) else { return }
                if let match = Self.firstKnownCallApp(in: Self.bundleIDsRunningInput()) {
                    self.promptedThisEpisode = true
                    Self.log.notice("Call detected (recheck): \(match.name, privacy: .public)")
                    self.onCallDetected?(match.name)
                }
            }
        }
    }

    // MARK: - HAL queries (pure reads, no engine, thread-safe)

    static func deviceIsRunningSomewhere(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceID != 0 else { return false }
        var addr = runningSomewhereAddress
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &running) == noErr
        else { return false }
        return running != 0
    }

    /// Bundle ids of every OTHER process currently running mic input.
    /// Empty on macOS < 14.4 (the AudioProcess queries fail) — detection is
    /// simply unavailable there.
    static func bundleIDsRunningInput() -> [String] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr,
            size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0,
                                      count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &objects) == noErr
        else { return [] }

        let ownPid = ProcessInfo.processInfo.processIdentifier
        var ids: [String] = []
        for obj in objects {
            guard processIsRunningInput(obj),
                  processPid(obj) != ownPid,
                  let bundleID = processBundleID(obj), !bundleID.isEmpty
            else { continue }
            ids.append(bundleID)
        }
        return ids
    }

    private static func processIsRunningInput(_ obj: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &running) == noErr
        else { return false }
        return running != 0
    }

    private static func processPid(_ obj: AudioObjectID) -> pid_t {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &pid) == noErr
        else { return -1 }
        return pid
    }

    private static func processBundleID(_ obj: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr
        else { return nil }
        return value as String
    }

    /// Is any known call app still running mic input? Used by AppDelegate to
    /// auto-stop a call capture when the call ends (the device-level "running"
    /// signal is useless for that while we're capturing — WE keep it busy).
    static func anyKnownCallAppRunningInput() -> Bool {
        firstKnownCallApp(in: bundleIDsRunningInput()) != nil
    }
}
