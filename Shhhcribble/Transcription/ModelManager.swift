import Foundation
import Carbon.HIToolbox

/// Central registry for available Whisper model variants and hotkey options.
enum ModelManager {

    // MARK: - Parakeet models

    struct ModelInfo {
        let id: String
        let displayName: String
    }

    // To add a new model: append an entry here. `id` is the persisted UserDefaults
    // value; `displayName` is shown in Settings. The id must match a case handled
    // by TranscriptionEngine.reloadModel(variant:) (currently mapped to FluidAudio's
    // AsrModels.Version — "parakeet-v3" → .v3, "parakeet-v2" → .v2).
    static let availableModels: [ModelInfo] = [
        ModelInfo(id: "parakeet-v3", displayName: "Parakeet V3 (~494 MB) – Multilingual ✦"),
        ModelInfo(id: "parakeet-v2", displayName: "Parakeet V2 (~476 MB) – English-optimized"),
    ]

    private static let modelKey    = "selectedParakeetModel"
    private static let defaultModel = "parakeet-v3"

    static var selectedModel: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }

    // MARK: - Hotkey presets

    struct HotkeyOption: Identifiable {
        let id:        String    // stable key for UserDefaults
        let label:     String    // shown in Settings UI (full description)
        let symbol:    String    // short symbol for menu hint
        let keyCode:   UInt32
        let modifiers: UInt32
    }

    static let availableHotkeys: [HotkeyOption] = [
        HotkeyOption(id: "optSpace",  label: "⌥Space  (Option+Space)",    symbol: "⌥Space",  keyCode: UInt32(kVK_Space),      modifiers: UInt32(optionKey)),
        HotkeyOption(id: "ctrlSpace", label: "⌃Space  (Control+Space)",   symbol: "⌃Space",  keyCode: UInt32(kVK_Space),      modifiers: UInt32(controlKey)),
        HotkeyOption(id: "optGrave",  label: "⌥`       (Option+Backtick)", symbol: "⌥`",      keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(optionKey)),
        HotkeyOption(id: "ctrlOpt",   label: "⌃⌥Space (Ctrl+Opt+Space)",  symbol: "⌃⌥Space", keyCode: UInt32(kVK_Space),      modifiers: UInt32(controlKey | optionKey)),
    ]

    private static let hotkeyKey     = "selectedHotkeyID"
    private static let defaultHotkey = "optSpace"

    static var selectedHotkeyID: String {
        get { UserDefaults.standard.string(forKey: hotkeyKey) ?? defaultHotkey }
        set { UserDefaults.standard.set(newValue, forKey: hotkeyKey) }
    }

    static var selectedHotkey: HotkeyOption {
        availableHotkeys.first(where: { $0.id == selectedHotkeyID }) ?? availableHotkeys[0]
    }

    // MARK: - Activation mode

    enum ActivationMode: String {
        case pushToTalk   // hold hotkey to record, release to transcribe
        case toggle       // tap to start, tap again to stop & transcribe
    }

    private static let activationModeKey = "activationMode"

    static var activationMode: ActivationMode {
        get {
            ActivationMode(rawValue: UserDefaults.standard.string(forKey: activationModeKey) ?? "")
                ?? .pushToTalk
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: activationModeKey) }
    }

    // MARK: - Feature flags

    /// Default true — strip um/uh/hmm/er and parenthetical fillers before pasting.
    static var fillerFilterEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: "fillerFilterEnabled") != nil else { return true }
            return UserDefaults.standard.bool(forKey: "fillerFilterEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "fillerFilterEnabled") }
    }

    /// Default true — stream live transcription text in the soundwave pill while recording.
    /// When false, the 3s snapshot loop is skipped and the pill shows only the waveform.
    static var showLiveTranscription: Bool {
        get {
            guard UserDefaults.standard.object(forKey: "showLiveTranscription") != nil else { return true }
            return UserDefaults.standard.bool(forKey: "showLiveTranscription")
        }
        set { UserDefaults.standard.set(newValue, forKey: "showLiveTranscription") }
    }

    /// Whether the user has completed the first-run onboarding flow.
    static var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    /// Preferred microphone device UID (matches AVCaptureDevice.uniqueID).
    /// nil means "follow system default input".
    static var preferredInputDeviceUID: String? {
        get { UserDefaults.standard.string(forKey: "preferredInputDeviceUID") }
        set { UserDefaults.standard.set(newValue, forKey: "preferredInputDeviceUID") }
    }

    /// Default true — play a short sound when the app launches.
    static var playLaunchSound: Bool {
        get {
            guard UserDefaults.standard.object(forKey: "playLaunchSound") != nil else { return true }
            return UserDefaults.standard.bool(forKey: "playLaunchSound")
        }
        set { UserDefaults.standard.set(newValue, forKey: "playLaunchSound") }
    }

    // MARK: - Transcription history

    struct TranscriptionEntry {
        let text: String
        let date: Date

        /// Truncated title for display in menus (max 60 chars).
        var menuTitle: String {
            let prefix = String(text.prefix(60))
            return text.count > 60 ? "\(prefix)…" : prefix
        }
    }

    private(set) static var history: [TranscriptionEntry] = []

    static func addToHistory(_ text: String) {
        history.insert(TranscriptionEntry(text: text, date: Date()), at: 0)
        if history.count > 20 { history = Array(history.prefix(20)) }
    }

    static func clearHistory() {
        history.removeAll()
    }
}
