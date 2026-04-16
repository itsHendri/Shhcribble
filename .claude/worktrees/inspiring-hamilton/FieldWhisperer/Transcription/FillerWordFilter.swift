import Foundation

/// Strips unambiguous spoken filler words from transcribed text.
/// Conservative by design — only removes patterns that are unambiguously filler
/// to avoid corrupting legitimate sentences.
enum FillerWordFilter {

    static func filter(_ text: String) -> String {
        var s = text

        // 1. Definite fillers — safe to remove in all contexts.
        //    Captures optional trailing comma to avoid orphaned punctuation.
        let definite = [
            "\\b[Uu]m+h?\\b,?",  // um, umm, umh
            "\\b[Uu]h+\\b,?",     // uh, uhh
            "\\b[Hh]m+\\b,?",     // hm, hmm
            "\\b[Ee]r+\\b,?",     // er, err
            "\\b[Ee]rm+\\b,?",    // erm
        ]
        for pattern in definite {
            s = s.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }

        // 2. Contextual fillers — only removed when clearly parenthetical.

        // "you know" sandwiched by commas: "I, you know, think" → "I think"
        s = s.replacingOccurrences(of: ",\\s*[Yy]ou know,\\s*",
                                   with: " ", options: .regularExpression)
        // "you know" at sentence end: "I think, you know." → "I think."
        s = s.replacingOccurrences(of: ",?\\s*[Yy]ou know\\.?$",
                                   with: "", options: .regularExpression)
        // "You know, ..." at sentence start
        s = s.replacingOccurrences(of: "^[Yy]ou know,\\s*",
                                   with: "", options: .regularExpression)

        // "Like, ..." only at the very start of the text (clear filler opener)
        s = s.replacingOccurrences(of: "^[Ll]ike,\\s+",
                                   with: "", options: .regularExpression)

        // 3. Clean up artifacts left by removed words.
        s = s.replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove leading comma/semicolon left by a stripped opener
        s = s.replacingOccurrences(of: "^[,;]+\\s*", with: "", options: .regularExpression)

        return s
    }
}
