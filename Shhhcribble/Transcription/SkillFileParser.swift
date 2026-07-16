import Foundation

/// Parses an imported `SKILL.md` (or any `.md`/`.txt`) into a style's name +
/// prompt. Pure and dependency-free (no YAML library) so it's unit-testable and
/// can't pull in weight.
///
/// If the file opens with a `---` fenced frontmatter block, we lift `name:` (and
/// fall back to `description:`) for the style name and use the markdown body
/// after the closing `---` as the prompt. Otherwise the whole file is the prompt
/// and `name` is `nil` (the caller defaults to the filename stem). Deliberately
/// forgiving: a malformed or absent frontmatter never fails — it just yields
/// whole-file-as-prompt.
enum SkillFileParser {

    struct Parsed: Equatable {
        var name: String?
        var prompt: String
    }

    static func parse(_ contents: String) -> Parsed {
        let normalized = contents.replacingOccurrences(of: "\r\n", with: "\n")

        guard let fm = frontmatter(normalized) else {
            return Parsed(name: nil, prompt: normalized.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let name = fm.fields["name"] ?? fm.fields["description"]
        let prompt = fm.body.trimmingCharacters(in: .whitespacesAndNewlines)
        // A frontmatter-only file (no body) still yields a usable prompt from the
        // description if present; otherwise fall back to the whole thing.
        if prompt.isEmpty {
            let fallback = (fm.fields["description"] ?? normalized).trimmingCharacters(in: .whitespacesAndNewlines)
            return Parsed(name: cleaned(name), prompt: fallback)
        }
        return Parsed(name: cleaned(name), prompt: prompt)
    }

    // MARK: - Frontmatter

    private struct Frontmatter {
        var fields: [String: String]
        var body: String
    }

    /// Recognize a leading `---\n … \n---\n` block. Returns nil when the file
    /// doesn't start with a frontmatter fence.
    private static func frontmatter(_ text: String) -> Frontmatter? {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return nil }

        // Find the closing fence.
        guard let closeIdx = lines.dropFirst().firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else { return nil }

        var fields: [String: String] = [:]
        for line in lines[1..<closeIdx] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !value.isEmpty else { continue }
            fields[key] = value
        }
        let body = lines[(closeIdx + 1)...].joined(separator: "\n")
        return Frontmatter(fields: fields, body: body)
    }

    /// Strip matching surrounding quotes YAML scalars sometimes carry.
    private static func cleaned(_ value: String?) -> String? {
        guard var v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        for quote in ["\"", "'"] where v.count >= 2 && v.hasPrefix(quote) && v.hasSuffix(quote) {
            v = String(v.dropFirst().dropLast())
        }
        return v.isEmpty ? nil : v
    }
}
