import Foundation

/// A user-selectable transform "Style" — a prompt fed into the on-device model
/// to reshape a transcript for its destination (an email, a Slack message, code,
/// bullet notes …). Modeled on `DictionaryEntry`: `Codable, Identifiable,
/// Equatable` with a tolerant `init(from:)` so one malformed stored row can't
/// wipe the whole set on decode.
///
/// A `Style` is always a **transform** — it may freely add, remove, and
/// restructure words (unlike the faithful default clean-up, which is not a
/// `Style` at all — see `ActiveStyle`). Because transforms legitimately rewrite,
/// their output is guarded by the lighter `StyleGuard` rather than `CleanupGuard`.
struct Style: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// The tone/transform instruction handed to the model (as data-framed
    /// instructions, never obeyed literally — see `TranscriptCleaner.transform`).
    var prompt: String
    /// Bundle IDs of apps that auto-select this style when frontmost during
    /// dictation (empty = manual selection only). See `StyleResolver`.
    var activationApps: [String] = []
    /// Seeded preset (`true`) vs. user-authored (`false`). Presets are still
    /// fully editable and deletable; this only distinguishes their origin.
    var isBuiltIn: Bool = false

    init(id: UUID = UUID(),
         name: String,
         prompt: String,
         activationApps: [String] = [],
         isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.activationApps = activationApps
        self.isBuiltIn = isBuiltIn
    }

    /// The editable presets seeded into an empty styles table on first launch
    /// (`TranscriptStore.seedBuiltInStylesIfNeeded`). Activation bundle IDs are
    /// best-effort defaults the user can change. Prompts describe only the desired
    /// format — the injection-defense framing is added by `TranscriptCleaner
    /// .transform`, which treats the transcript as content to reformat.
    static let seededPresets: [Style] = [
        Style(
            name: "Email",
            prompt: """
            Rewrite the transcript as a clear, polite email body. Fix grammar and \
            punctuation, use complete sentences and short paragraphs, and keep a warm \
            but professional tone. Keep any greeting or sign-off the speaker actually \
            said, but never invent one. Preserve all facts, names, numbers, and intent.
            """,
            activationApps: ["com.apple.mail", "com.microsoft.Outlook"],
            isBuiltIn: true
        ),
        Style(
            name: "Slack / Chat message",
            prompt: """
            Rewrite the transcript as a concise, casual chat message. Use natural \
            punctuation and capitalization, keep it friendly and direct, and use no \
            greeting or sign-off. Keep it short and skimmable. Preserve the meaning, \
            names, and any questions asked.
            """,
            activationApps: ["com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.apple.MobileSMS"],
            isBuiltIn: true
        ),
        Style(
            name: "Code / vibe-coding",
            prompt: """
            Rewrite the transcript as a precise, technical instruction suitable for a \
            coding assistant or a code comment. Use exact, unambiguous phrasing, keep \
            technical terms, symbols, and identifiers verbatim, drop conversational \
            filler, and prefer imperative phrasing. Preserve the intent exactly.
            """,
            activationApps: ["com.apple.dt.Xcode", "com.microsoft.VSCode",
                             "com.todesktop.230313mzl4w4u92", "com.apple.Terminal",
                             "com.googlecode.iterm2"],
            isBuiltIn: true
        ),
        Style(
            name: "Bullet notes",
            prompt: """
            Rewrite the transcript as a concise bulleted list. Put each distinct point, \
            task, or idea on its own line starting with "- ". Keep bullets short, fix \
            grammar, and preserve every point the speaker made without adding new ones.
            """,
            activationApps: [],
            isBuiltIn: true
        ),
    ]

    // Tolerant decoding — synthesized Codable ignores property defaults, so a
    // stored row missing `id`/`activationApps`/`isBuiltIn` would otherwise fail
    // to decode. Decode optionals with defaults instead (mirrors DictionaryEntry).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id             = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name           = try c.decode(String.self, forKey: .name)
        prompt         = try c.decode(String.self, forKey: .prompt)
        activationApps = try c.decodeIfPresent([String].self, forKey: .activationApps) ?? []
        isBuiltIn      = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
    }
}

/// What actually shapes a given dictation, resolved from `ModelManager
/// .activeStyleID` + the stored styles (and, for per-app auto, the frontmost
/// app). The pipeline switches on this; the picker/menu present it. Only the
/// `.custom` case carries a stored `Style` — `.off` and `.defaultCleanup` are
/// synthetic, always-present entries that are never stored in SQLite.
enum ActiveStyle: Equatable {
    /// No AI: raw transcript + the always-on `FillerWordFilter` floor.
    case off
    /// Today's faithful cleaner (unchanged `TranscriptCleaner.clean` + the strong
    /// `CleanupGuard`). The default selection.
    case defaultCleanup
    /// A user/seeded transform style.
    case custom(Style)

    /// Stable id used in UserDefaults and the picker/menu tags.
    var id: String {
        switch self {
        case .off:            return Self.offID
        case .defaultCleanup: return Self.defaultCleanupID
        case .custom(let s):  return s.id.uuidString
        }
    }

    static let offID = "off"
    static let defaultCleanupID = "default-cleanup"
}
