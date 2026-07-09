import Foundation

/// A single phrase→replacement substitution in the user's personal dictionary
/// (names, jargon — terms Parakeet reliably mishears).
struct DictionaryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var phrase: String
    var replacement: String
    var caseSensitive: Bool = false

    // Tolerant decoding: synthesized Codable ignores property defaults, so a
    // stored entry missing `id` or `caseSensitive` (hand-edited defaults, or a
    // future schema change) would otherwise fail decode — and because the
    // store decodes all-or-nothing, one bad entry would silently wipe the
    // whole dictionary. Decode optionals with defaults instead.
    init(id: UUID = UUID(), phrase: String, replacement: String, caseSensitive: Bool = false) {
        self.id = id
        self.phrase = phrase
        self.replacement = replacement
        self.caseSensitive = caseSensitive
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id            = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        phrase        = try c.decode(String.self, forKey: .phrase)
        replacement   = try c.decode(String.self, forKey: .replacement)
        caseSensitive = try c.decodeIfPresent(Bool.self, forKey: .caseSensitive) ?? false
    }
}

/// Applies the user's personal dictionary to a transcript.
///
/// Semantics (load-bearing — pinned by PersonalDictionaryTests):
/// - Entries apply **sequentially in array order**; each entry operates on the
///   previous entry's output, exactly once. Ordering *is* the overlap
///   resolution: earlier entries win on the spans they rewrite, and a later
///   entry may legally match text an earlier replacement produced.
/// - **Whole-word** matching via lookarounds (`(?<!\w) … (?!\w)`) rather than
///   `\b`, so phrases that start or end with non-word characters ("C++",
///   ".NET") still anchor correctly. Multi-word phrases need no special
///   handling — escaped spaces match literally.
/// - A single entry may list **several spoken variants separated by commas**
///   ("henry, hendry, henri"); any of them maps to the one replacement. Each
///   variant is matched as a whole word via an escaped regex alternation, so a
///   one-variant entry (no comma) behaves exactly as before.
/// - `caseSensitive == false` matches any casing; the **replacement is always
///   used verbatim** (no smart-case adaption) because the dominant use case is
///   fixing proper nouns where the replacement's own casing is the point.
enum PersonalDictionary {

    static func apply(_ entries: [DictionaryEntry], to text: String) -> String {
        guard !text.isEmpty, !entries.isEmpty else { return text }

        var s = text
        for entry in entries {
            // One entry can hold several comma-separated spoken variants, all
            // mapping to the same replacement. Split, trim, drop empties.
            let variants = entry.phrase
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !variants.isEmpty else { continue }

            // Whole-word alternation over the escaped variants.
            let alternation = variants
                .map { NSRegularExpression.escapedPattern(for: $0) }
                .joined(separator: "|")
            let pattern = "(?<!\\w)(?:" + alternation + ")(?!\\w)"
            var options: NSRegularExpression.Options = []
            if !entry.caseSensitive { options.insert(.caseInsensitive) }
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { continue }

            s = regex.stringByReplacingMatches(
                in: s,
                range: NSRange(s.startIndex..., in: s),
                withTemplate: NSRegularExpression.escapedTemplate(for: entry.replacement)
            )
        }
        return s
    }
}
