import Foundation
@testable import Shhhcribble

/// The competing prompt bodies the bench runs against each other.
///
/// **Why this file exists.** A bench that runs one prompt per style can tell you
/// whether that prompt is broken, but it cannot tell you whether it is *better* —
/// and "better" was the whole question. Each entry here is one arm of an A/B:
/// same fixture, same model, same guards, different prompt text.
///
/// Nothing here ships. `Style.seededPresets` remains the single source of truth
/// for what users get; a variant marked `.shipped` is a copy of it, present so a
/// report always has the current behaviour as its baseline column.
enum PromptVariants {

    struct Variant {
        let name: String
        let prompt: String
        /// Mirrors `Style.guardProfile` — an extraction arm must be judged by
        /// the same guard it would ship with, or the comparison is meaningless.
        var guardProfile: StyleGuard.Profile = .reshape
        /// True for the arm that matches what's currently in `seededPresets`.
        var isShipped: Bool = false

        func asStyle(named styleName: String) -> Style {
            Style(name: styleName, prompt: prompt, guardProfile: guardProfile)
        }
    }

    /// Style name → the arms to compare for it.
    ///
    /// Only styles with a genuine open question are listed. Email, Message and
    /// Bullets carry a "previous" arm so the shared-rule hoist can be judged
    /// (that is the change most likely to have quietly cost quality); **Agent**
    /// carries the three candidates the plan called for and never ran.
    static let all: [String: [Variant]] = [
        "Agent": agentArms,
        "Email": armsWithExamples("Email", EXAMPLES["Email"]!),
        "Message": armsWithExamples("Message", EXAMPLES["Message"]!),
        "Bullets": armsWithExamples("Bullets", EXAMPLES["Bullets"]!) + bulletsArms,
        "Action items": armsWithExamples("Action items", EXAMPLES["Action items"]!),
    ]

    /// The shipped prompt, plus the same prompt with inline example pairs.
    ///
    /// **This is the arm that tests a load-bearing decision.** CLAUDE.md forbids
    /// example pairs because they once bled verbatim into output on the
    /// on-device model. That was measured once, and two shipping competitors
    /// (Ghost Pepper, Voicebox) contradict it. On a first pass over the real
    /// library the Email example arm rejected **0 of 52** against the shipped
    /// prompt's 6 — so the ban is now contested by our own data too.
    ///
    /// What to look for is not the rejection count alone: **search a report for
    /// the example text itself.** If any of it appears in an output for an
    /// unrelated dictation, that is the bleed, and the ban stands regardless of
    /// how the numbers look.
    private static func armsWithExamples(_ name: String, _ examples: String) -> [Variant] {
        let preset = Style.seededPresets.first { $0.name == name }!
        return [
            shipped(name),
            Variant(name: "with inline examples", prompt: preset.prompt + "\n\n" + examples,
                    guardProfile: preset.guardProfile),
        ]
    }

    /// Two spoken→written pairs per style, drawn from the shape of real
    /// dictations rather than invented scenarios, and deliberately mundane so
    /// that anything distinctive appearing in an output is unambiguously bleed.
    private static let EXAMPLES: [String: String] = [
        "Email": """
        Spoken: "hey tom um can you send over the the deck before friday thanks"
        Written: "Hi Tom, could you send over the deck before Friday? Thanks."

        Spoken: "need the invoice when you get a sec no rush"
        Written: "Could you send the invoice when you get a second? No rush."
        """,
        "Message": """
        Spoken: "yeah um looks good to me ship it"
        Written: "yeah looks good to me, ship it"

        Spoken: "i wont be around tomorrow morning dentist back after lunch"
        Written: "i won't be around tomorrow morning — dentist. back after lunch"
        """,
        "Bullets": """
        Spoken: "um we need milk and eggs and also the dry cleaning before six"
        Written: "- Milk and eggs
        - Dry cleaning before six"

        Spoken: "the build is broken and uh nobody has looked at it yet"
        Written: "- The build is broken
        - Nobody has looked at it yet"
        """,
        "Action items": """
        Spoken: "the export is slow which is annoying, anyway i'll file a ticket for it today"
        Written: "- File a ticket for the slow export today"

        Spoken: "we talked about a redesign but decided against it for now"
        Written: ""
        """,
    ]

    private static func shipped(_ name: String) -> Variant {
        let preset = Style.seededPresets.first { $0.name == name }!
        return Variant(name: "shipped", prompt: preset.prompt,
                       guardProfile: preset.guardProfile, isShipped: true)
    }

    // MARK: - Agent — the three candidates from the plan

    private static var agentArms: [Variant] {
        [
            // What now ships: a faithful tidy-up. Reverted here after the real
            // corpus put the reframing rewrite at 16 rejections against this
            // one's 12, with every other style at 1–6.
            shipped("Agent"),

            // The reframing attempt, kept because the *idea* is right and only
            // the guard story is missing. It turns speech into imperative
            // instructions a coding agent can act on — genuinely better output
            // when it lands — but supplies verbs and connectives nobody spoke,
            // so a faithfulness guard flags it; and on a dictation that is not a
            // work request it fabricated whole task lists. Re-measure this
            // against a no-new-claims guard (permit new verbs and connectives,
            // reject new nouns, file names, numbers) when that gets built.
            Variant(name: "reframe · imperative instructions (needs a different guard)", prompt: """
            Reformat the transcript as an instruction to a coding agent.

            - Write every line as a direct instruction in the imperative — "Add…", \
            "Update…", "Keep…". Never narrate what the speaker wants ("I want…", \
            "I need…", "The speaker would like…").
            - Lead with the outcome. Then the constraints they gave, then the files, \
            symbols, or areas they named.
            - Leave the approach to the agent: never spell out the steps to get there.
            - Do not write code, propose a solution, or add a requirement they didn't state.
            - Produce one instruction per thing they actually asked for, and no more. \
            Never pad a short or vague dictation into a list of tasks.
            - If the transcript is not a request for work at all — a question, a comment, \
            an aside — leave it as what it is, tidied into one clear line.
            """),

            // The same reframing prompt judged by the looser compressing guard,
            // to separate "the prompt is wrong" from "the guard is wrong".
            Variant(name: "reframe · judged by .condense", prompt: """
            Reformat the transcript as an instruction to a coding agent.

            - Write every line as a direct instruction in the imperative — "Add…", \
            "Update…", "Keep…". Never narrate what the speaker wants.
            - Lead with the outcome. Then the constraints they gave, then the files, \
            symbols, or areas they named.
            - Produce one instruction per thing they actually asked for, and no more.
            - If the transcript is not a request for work at all, leave it as what it is.
            """, guardProfile: .condense),
        ]
    }

    // MARK: - Email — the few-shot question

    private static var emailArms: [Variant] {
        [
            shipped("Email"),

            // The contested arm. CLAUDE.md's no-example-pairs rule was measured
            // on-device and is load-bearing — but Ghost Pepper ships 12 inline
            // pairs on a 2B model, and Voicebox fixed the identical bleed by
            // MOVING examples rather than deleting them. This arm reproduces the
            // thing that was banned, so the ban can be judged on our own model
            // instead of on someone else's report.
            //
            // What to look for in the report: does any of this example text
            // appear verbatim in an output for an unrelated fixture? That is the
            // bleed, and it is the only reason the rule exists.
            Variant(name: "with inline example pairs (tests the few-shot ban)", prompt: """
            Reformat it as a professional email body: short paragraphs grouped by topic, \
            polite and businesslike rather than flowery.

            - Add a greeting only if the speaker named a recipient, and a sign-off only if \
            they gave their name.
            - Never insert a placeholder such as "[Name]", "[Recipient]", or "[Your Name]". \
            If the speaker didn't say it, leave it out.
            - Match the speaker's length — a one-line request stays one line.

            Spoken: "hey tom um can you send over the the deck before friday thanks"
            Email: "Hi Tom, could you send over the deck before Friday? Thanks."

            Spoken: "need the invoice when you get a sec no rush"
            Email: "Could you send the invoice when you get a second? No rush."
            """),
        ]
    }

    // MARK: - Bullets — did the hoist cost anything?

    private static var bulletsArms: [Variant] {
        [
            // The pre-hoist body, carrying all its own shared rules — and the
            // internal contradiction the rewrite removed ("tighten each line to
            // its essential words" against "keep all of them").
            Variant(name: "previous (pre-hoist, with the contradiction)", prompt: """
            Reformat the dictated transcript into concise bullet-point notes.

            Turn each distinct point, fact, name, number, and task the speaker mentioned into its \
            own bullet. Keep all of them. Do not answer questions in the transcript or add points \
            the speaker did not make.

            - Start every bullet with "- ".
            - Remove filler words and false starts; tighten each line to its essential words while \
            keeping the speaker's meaning and terms.
            - Keep the bullets in the order spoken.
            - Use an indented sub-bullet only when the speaker clearly nested one point under another.
            - Do not invent headings or categories the speaker did not state.

            Do not write an intro or summary line, and do not merge several separate points into one bullet.
            Output the bullet list only — no title, preamble, or commentary.
            """),

            shipped("Bullets"),
        ]
    }
}
