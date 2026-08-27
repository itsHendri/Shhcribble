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
    /// Which faithfulness check guards this style's output. **Code-owned** — set
    /// only here in `seededPresets`, never written by `updateStyle`, and with no
    /// UI, so a user-authored style always gets the strict default. See
    /// `StyleGuard.Profile`.
    var guardProfile: StyleGuard.Profile = .reshape

    init(id: UUID = UUID(),
         name: String,
         prompt: String,
         activationApps: [String] = [],
         isBuiltIn: Bool = false,
         guardProfile: StyleGuard.Profile = .reshape) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.activationApps = activationApps
        self.isBuiltIn = isBuiltIn
        self.guardProfile = guardProfile
    }

    /// The editable presets seeded into an empty styles table on first launch
    /// (`TranscriptStore.seedBuiltInStylesIfNeeded`). Activation bundle IDs are
    /// best-effort defaults the user can change.
    ///
    /// **These prompts carry ONLY shape and register — deliberately (2026-08-11).**
    /// Everything shared (filler removal, grammar/punctuation, keep-the-content,
    /// add-nothing, identifier casing, output-only-text) now lives once in
    /// `TranscriptCleaner.transformInstructions`, and the injection framing lives
    /// there too. Before that hoist, one Email dictation carried **~35 distinct
    /// directives** — ≈30 from this prompt plus ≈5 from the preamble — against
    /// published evidence that *state-of-the-art* models start failing to satisfy
    /// all of them at around **ten**, decaying roughly exponentially past that
    /// ([arXiv 2510.14842](https://arxiv.org/pdf/2510.14842)). This app runs on a
    /// ~3B model. The same twelve rules were also restated *differently* in each
    /// of the four presets, which is why they drifted.
    ///
    /// **So: when editing a preset, do not re-add a shared rule here.** If a rule
    /// belongs to every style it belongs in the preamble; if it belongs to one
    /// style it belongs here. Keep each prompt to roughly 3–6 lines, and check
    /// the directive count the bench prints (`Testing/prompts/README.md`) before
    /// concluding that a wording change is what fixed or broke something.
    static let seededPresets: [Style] = [
        Style(
            name: "Email",
            prompt: """
            Reformat the transcript as a professional email body: short paragraphs grouped by topic, \
            polite and businesslike rather than flowery.

            - Add a greeting only if the speaker named a recipient, and a sign-off only if \
            they gave their name.
            - Never insert a placeholder such as "[Name]", "[Recipient]", or "[Your Name]". \
            If the speaker didn't say it, leave it out.
            - Match the speaker's length — a one-line request stays one line.
            """,
            activationApps: ["com.apple.mail", "com.microsoft.Outlook"],
            isBuiltIn: true
        ),
        Style(
            name: "Message",
            prompt: """
            Reformat the transcript as a casual chat message: sentence case, light punctuation, no \
            greeting or sign-off.

            - Keep it conversational, in the speaker's own voice, and about as long as what \
            they said — don't pad it or make it corporate.
            - Use a few short lines, or a short list, only if they listed several things.
            - Add no emoji, hashtags, or @-mentions unless they said them.
            """,
            activationApps: ["com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.apple.MobileSMS"],
            isBuiltIn: true
        ),
        Style(
            name: "Agent",
            // The imperative rule is first because the bench measured it as the
            // difference that matters. An earlier version of this prompt led with
            // "Lead with the outcome the speaker wants", and across 12 generations
            // it restated the speaker in first person — "I want to pull the
            // pattern into a helper function" — in **9 of them**. That is the
            // dictation preserved, not an instruction a coding agent can act on.
            // The prompt it replaced never did it once. See PromptVariants.
            prompt: """
            Reformat the transcript as an instruction to a coding agent.

            - Write every line as a direct instruction in the imperative — "Add…", \
            "Update…", "Keep…". Never narrate what the speaker wants ("I want…", \
            "I need…", "The speaker would like…").
            - Lead with the outcome. Then the constraints they gave, then the files, \
            symbols, or areas they named.
            - Leave the approach to the agent: never spell out the steps to get there.
            - Do not write code, propose a solution, or add a requirement they didn't state.
            """,
            activationApps: ["com.apple.dt.Xcode", "com.microsoft.VSCode",
                             "com.todesktop.230313mzl4w4u92", "com.apple.Terminal",
                             "com.googlecode.iterm2"],
            isBuiltIn: true
        ),
        Style(
            name: "Bullets",
            prompt: """
            Reformat the transcript as bullet-point notes: one point per line starting with "- ", in the \
            order spoken.

            - Keep every distinct point they made. Never merge two points into one bullet, \
            and never drop one.
            - Within a bullet, cut only padding words — a rambling point becomes a long \
            bullet rather than a shortened one.
            - Indent a sub-bullet only where the speaker clearly nested one point under another.
            """,
            activationApps: [],
            isBuiltIn: true
        ),
        Style(
            name: "Action items",
            prompt: """
            From the transcript, extract only the commitments — things the speaker, or someone in the transcript, \
            said would be done.

            - One per line starting with "- ", each beginning with a verb, in the order spoken.
            - Drop everything that is not an action: background, opinions, questions, and \
            anything explicitly decided against.
            - A complaint, a problem, or an observation is not a commitment. Someone \
            disliking how something works is not a promise to change it — do not turn one \
            into an item.
            - Build each item from the speaker's own words. Never invent an owner, a date, or \
            a task that wasn't stated, and leave a hedge hedged — "we could probably do \
            Friday" is not a commitment to Friday.
            - If nothing was committed to, output nothing at all.
            """,
            activationApps: [],
            isBuiltIn: true,
            // A filter, not a reshape: on a real standup this legitimately drops
            // 70–80% of the words, which the default coverage floor would reject
            // every time. See StyleGuard.Profile.
            guardProfile: .extract
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
        // Unknown/absent → the strict profile. A row that predates the column,
        // or one carrying a value a future build wrote, must never decode into
        // the *looser* guard.
        guardProfile   = try c.decodeIfPresent(StyleGuard.Profile.self, forKey: .guardProfile) ?? .reshape
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
