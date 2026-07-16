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
    ///
    /// **Legacy as of Custom Styles.** Replaced by `activeStyleID` — the on/off
    /// toggle became a style selection (Off / Default clean-up / a transform
    /// style). Read once by `migrateCleanupToStyleIfNeeded()` to seed the new key,
    /// then no longer read by the pipeline. The key is left in place for rollback.
    static var transcriptCleanupEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: "transcriptCleanupEnabled") != nil else { return false }
            return UserDefaults.standard.bool(forKey: "transcriptCleanupEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "transcriptCleanupEnabled") }
    }

    // MARK: - Active style

    private static let activeStyleKey = "activeStyleID"

    /// Posted whenever `activeStyleID` changes, so the Styles picker and the
    /// menu-bar quick-pick stay in sync no matter which one made the change.
    static let activeStyleDidChangeNotification = Notification.Name("com.shhhcribble.activeStyleDidChange")

    /// Which style shapes new dictations by default: `ActiveStyle.offID`,
    /// `ActiveStyle.defaultCleanupID`, or a stored `Style`'s UUID string. Per-app
    /// activation can override this per dictation (see `StyleResolver`). Defaults
    /// to the faithful clean-up (today's cleanup-on behavior).
    static var activeStyleID: String {
        get { UserDefaults.standard.string(forKey: activeStyleKey) ?? ActiveStyle.defaultCleanupID }
        set {
            UserDefaults.standard.set(newValue, forKey: activeStyleKey)
            NotificationCenter.default.post(name: Self.activeStyleDidChangeNotification, object: nil)
        }
    }

    private static let cleanupToStyleMigrationFlagKey = "didMigrateCleanupToStyle"

    /// One-shot: map the retired `transcriptCleanupEnabled` bool onto `activeStyleID`
    /// (`true` → Default clean-up, `false` → Off) so an upgrading user keeps their
    /// prior behavior. Runs once (flag); the legacy key is left in place for rollback.
    static func migrateCleanupToStyleIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: cleanupToStyleMigrationFlagKey) else { return }
        defer { defaults.set(true, forKey: cleanupToStyleMigrationFlagKey) }

        let legacyEnabled = defaults.object(forKey: "transcriptCleanupEnabled") != nil
            ? transcriptCleanupEnabled : nil
        let existing = defaults.string(forKey: activeStyleKey)
        if let id = migratedActiveStyleID(legacyCleanupEnabled: legacyEnabled, existingActiveID: existing) {
            activeStyleID = id
        }
    }

    /// Pure decision for the cleanup→style migration (extracted for testing):
    /// - already-set new key → leave unchanged (`nil`).
    /// - legacy key never set → leave at the new default (`nil`).
    /// - legacy on → Default clean-up; legacy off → Off.
    static func migratedActiveStyleID(legacyCleanupEnabled: Bool?, existingActiveID: String?) -> String? {
        guard existingActiveID == nil else { return nil }
        guard let enabled = legacyCleanupEnabled else { return nil }
        return enabled ? ActiveStyle.defaultCleanupID : ActiveStyle.offID
    }

    // MARK: - Personal dictionary
    //
    // Dictionary entries moved out of UserDefaults into the SQLite-backed
    // `TranscriptStore` (see Storage/TranscriptStore.swift) in Sprint 4d — it
    // completes the Studio data layer and the ordered CRUD lives with the store.
    // The legacy `dictionaryEntries` UserDefaults JSON is migrated in once by
    // `TranscriptStore.migrateLegacyDictionaryIfNeeded()`; the old key is left in
    // place (harmless) so a rollback build still finds it. The pipeline now
    // snapshots `store.dictionaryEntries` on the main actor and passes it into
    // `TranscriptPipeline.process(_:dictionary:)`.

    // MARK: - Transcription history
    //
    // History moved out of UserDefaults into the SQLite-backed `TranscriptStore`
    // (see Storage/TranscriptStore.swift) when file transcription landed — it
    // unifies dictation + file transcripts, drops the cap-10, and is searchable.
    // The legacy `transcriptionHistory` UserDefaults JSON is migrated in once by
    // `TranscriptStore.migrateLegacyHistoryIfNeeded()`; the old key is left in
    // place (harmless) so a rollback build still finds it.
}
