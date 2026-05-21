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

    /// Default true — strip um/uh/hmm/er and parenthetical fillers before pasting.
    static var fillerFilterEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: "fillerFilterEnabled") != nil else { return true }
            return UserDefaults.standard.bool(forKey: "fillerFilterEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "fillerFilterEnabled") }
    }

    // MARK: - Transcription history

    struct TranscriptionEntry: Codable {
        let text: String
        let date: Date

        /// Truncated title for display in menus (max 60 chars).
        var menuTitle: String {
            let prefix = String(text.prefix(60))
            return text.count > 60 ? "\(prefix)…" : prefix
        }
    }

    private static let historyKey = "transcriptionHistory"
    private static let historyCap = 10

    /// Persisted across launches via UserDefaults (JSON-encoded). The cap is
    /// kept at historyCap items; adding past that drops the oldest.
    private(set) static var history: [TranscriptionEntry] = {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let decoded = try? JSONDecoder().decode([TranscriptionEntry].self, from: data)
        else { return [] }
        return Array(decoded.prefix(historyCap))
    }()

    static func addToHistory(_ text: String) {
        history.insert(TranscriptionEntry(text: text, date: Date()), at: 0)
        if history.count > historyCap { history = Array(history.prefix(historyCap)) }
        persistHistory()
    }

    static func clearHistory() {
        history.removeAll()
        persistHistory()
    }

    private static func persistHistory() {
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }
}
