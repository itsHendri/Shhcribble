import Foundation
import Carbon.HIToolbox

/// Central registry for available Whisper model variants and hotkey options.
enum ModelManager {

    // MARK: - Parakeet models

    struct ModelInfo {
        let id: String
        let displayName: String
    }

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

    // MARK: - Feature flags

    // Note: the `fillerFilterEnabled` pref + its Settings toggle were removed once
    // on-device AI cleanup landed — FillerWordFilter is now an always-on fallback
    // floor applied automatically whenever AI cleanup is off/unavailable (see
    // AppDelegate.endRecording). Any leftover "fillerFilterEnabled" UserDefaults
    // key is orphaned and harmless.

    /// Default false — when enabled and the on-device model is available (macOS 26 +
    /// Apple Intelligence), clean the transcript with Apple FoundationModels instead of
    /// the regex filler filter. Falls back to FillerWordFilter on timeout/failure/unavailable.
    /// See TranscriptCleaner.
    static var transcriptCleanupEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: "transcriptCleanupEnabled") != nil else { return false }
            return UserDefaults.standard.bool(forKey: "transcriptCleanupEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "transcriptCleanupEnabled") }
    }

    // MARK: - Personal dictionary

    private static let dictionaryKey = "dictionaryEntries"

    /// Ordered phrase→replacement substitutions applied to the raw transcript
    /// BEFORE AI cleanup / filler filtering, so the LLM sees corrected terms.
    /// Order matters — see PersonalDictionary for the substitution semantics.
    /// Persisted across launches via UserDefaults (JSON-encoded), no cap.
    static var dictionaryEntries: [DictionaryEntry] = {
        guard let data = UserDefaults.standard.data(forKey: dictionaryKey),
              let decoded = try? JSONDecoder().decode([DictionaryEntry].self, from: data)
        else { return [] }
        return decoded
    }() {
        didSet { persistDictionary() }
    }

    private static func persistDictionary() {
        if let data = try? JSONEncoder().encode(dictionaryEntries) {
            UserDefaults.standard.set(data, forKey: dictionaryKey)
        }
    }

    // MARK: - Transcription history
    //
    // History moved out of UserDefaults into the SQLite-backed `TranscriptStore`
    // (see Storage/TranscriptStore.swift) when file transcription landed — it
    // unifies dictation + file transcripts, drops the cap-10, and is searchable.
    // The legacy `transcriptionHistory` UserDefaults JSON is migrated in once by
    // `TranscriptStore.migrateLegacyHistoryIfNeeded()`; the old key is left in
    // place (harmless) so a rollback build still finds it.
}
