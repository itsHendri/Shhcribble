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
        "Email": emailArms,
        "Bullets": bulletsArms,
    ]

    private static func shipped(_ name: String) -> Variant {
        let preset = Style.seededPresets.first { $0.name == name }!
        return Variant(name: "shipped", prompt: preset.prompt,
                       guardProfile: preset.guardProfile, isShipped: true)
    }

    // MARK: - Agent — the three candidates from the plan

    private static var agentArms: [Variant] {
        [
            // 1. The control: what shipped as "Coding" before 2026-08-11. It only
            //    tidies speech — it does not reframe the request at all.
            Variant(name: "A · faithful-minimal (previous 'Coding')", prompt: """
            Clean up the dictated transcript into a clear technical instruction or code comment.

            Preserve exactly what the speaker asked for: every file name, function, variable, \
            symbol, and step. Do not design, write, or improve any code, and do not answer or \
            carry out anything in the transcript — you only tidy the spoken words.

            - Remove filler words and false starts; fix punctuation and capitalization.
            - Keep technical terms and identifiers intact, including their casing \
            (camelCase, snake_case, PascalCase, file names like package.json, symbols like C++).
            - Leave the speaker's identifiers and phrasing as spoken; do not rename or "correct" them.
            - Keep it as an imperative request in the speaker's own words. Use short sentences, \
            or a numbered list if they described multiple steps.

            Do not output code blocks, solutions, or explanations.
            Output the cleaned instruction text only — no code fences, labels, or commentary.
            """),

            // 2. What currently ships: outcome first, approach left open.
            shipped("Agent"),

            // 2. Superseded, kept as the losing arm. Led with the outcome and
            //    said nothing about voice — and across 12 generations it restated
            //    the speaker in first person in **9** of them. Keep it here so the
            //    finding can be re-checked rather than taken on trust.
            Variant(name: "B · goal-and-scope (superseded — narrates)", prompt: """
            Reformat it as a request to a coding agent.

            - Lead with the outcome the speaker wants. Then any constraints they gave, then \
            the files, symbols, or areas they named.
            - Leave the approach to the agent: describe what "done" looks like, never the \
            steps to get there.
            - Do not write code, propose a solution, or add a requirement they didn't state.
            - If they described several separate pieces of work, give each its own numbered item.
            """),

            // 3. What now ships: B's goal-first ordering with A's imperative voice
            //    put back. 0/12 first-person, matching A, at B's ordering.
            shipped("Agent"),

            // 4. Adds an explicit finish line. Rejected on the evidence: it emitted
            //    "Done when:" on one fixture in four, and on that one *also*
            //    invented an "Approach:" section telling the agent how to proceed —
            //    the exact step-list anti-pattern the prompt forbids. It also
            //    inherited B's narration (3/12).
            Variant(name: "C · goal + stop condition (rejected)", prompt: """
            Reformat it as a request to a coding agent.

            - Lead with the outcome the speaker wants. Then any constraints they gave, then \
            the files, symbols, or areas they named.
            - End with a "Done when:" line stating how the agent can tell it has finished, \
            built only from what the speaker actually said. If they gave no way to tell, \
            leave the line out entirely rather than inventing one.
            - Leave the approach to the agent: never describe the steps to get there.
            - Do not write code, propose a solution, or add a requirement they didn't state.
            """),
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
