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

    // MARK: - Activation mode

    /// How the hotkey drives recording.
    ///
    /// **Why this exists again.** It was removed in favour of `.automatic`
    /// (hold-duration auto-selects the mode), but `.automatic` has a failure
    /// mode the explicit modes don't: it can only classify a press *after* the
    /// recording has started, so anything that stalls the start — notably
    /// `engine.start()` blocking the main actor on a cold Bluetooth route —
    /// makes a normal hold arrive as an already-released key. The recording then
    /// begins and ends within ~30 ms, capturing nothing (observed 2026-07-20:
    /// a 793 ms start delay producing a 0.17 s all-silent capture).
    /// `.toggle` is structurally immune — keyUp never ends a recording — which
    /// is exactly why the pre-smart-activation builds felt reliable.
    enum ActivationMode: String, CaseIterable, Identifiable {
        /// Hold-duration decides: ≥ `holdThreshold` is push-to-talk, a quick tap toggles.
        case automatic
        /// Hold to record, release to transcribe. keyUp always ends the recording.
        case pushToTalk
        /// Tap to start, tap again to stop. keyUp is ignored entirely.
        case toggle

        var id: String { rawValue }

        var label: String {
            switch self {
            case .automatic:  return "Automatic"
            case .pushToTalk: return "Hold to talk"
            case .toggle:     return "Tap to start and stop"
            }
        }

        /// Should a hotkey *release* end the current recording?
        ///
        /// - Parameters:
        ///   - heldFor: real key-hold duration, from Carbon event times.
        ///   - holdThreshold: the `.automatic` push-to-talk cutoff.
        ///
        /// Pure so the branch can be unit-tested; `AppDelegate` owns the side effects.
        func keyUpShouldEndRecording(heldFor: TimeInterval?, holdThreshold: TimeInterval) -> Bool {
            switch self {
            case .toggle:
                return false
            case .pushToTalk:
                return true
            case .automatic:
                guard let heldFor else { return false }
                return heldFor >= holdThreshold
            }
        }

        var detail: String {
            switch self {
            case .automatic:
                return "Holding records until you let go; a quick tap starts and the next tap stops. Convenient, but a slow microphone wake-up can cut a hold short."
            case .pushToTalk:
                return "Recording runs for exactly as long as you hold the hotkey."
            case .toggle:
                return "Press once to start, press again to stop. Most reliable on Bluetooth headphones."
            }
        }
    }

    /// Deliberately NOT the legacy `"activationMode"` key. That one can still hold
    /// a `pushToTalk`/`toggle` value from the pre-smart-activation builds, and
    /// reusing it would silently resurrect a years-old preference on upgrade —
    /// and against different semantics, since `.automatic` didn't exist then.
    /// The legacy key stays orphaned and harmless.
    private static let activationModeKey = "activationModeV2"

    static var activationMode: ActivationMode {
        get {
            ActivationMode(rawValue: UserDefaults.standard.string(forKey: activationModeKey) ?? "")
                ?? .automatic
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: activationModeKey) }
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

    /// Master switch for per-app style auto-activation (default true). When off,
    /// a style's `activationApps` are ignored and the manual `activeStyleID`
    /// always decides — dictation never changes shape just because of the
    /// frontmost app.
    static var styleAppActivationEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: "styleAppActivationEnabled") != nil else { return true }
            return UserDefaults.standard.bool(forKey: "styleAppActivationEnabled")
        }
        set { UserDefaults.standard.set(newValue, forKey: "styleAppActivationEnabled") }
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
    /// - either way, upgrading users land on Default clean-up. (There is no "Off"
    ///   selection any more — Default clean-up is the always-on baseline; without
    ///   Apple Intelligence it degrades to basic filler removal regardless.)
    static func migratedActiveStyleID(legacyCleanupEnabled: Bool?, existingActiveID: String?) -> String? {
        guard existingActiveID == nil else { return nil }
        guard legacyCleanupEnabled != nil else { return nil }
        return ActiveStyle.defaultCleanupID
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
