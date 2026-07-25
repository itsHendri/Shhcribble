import Foundation

/// A run of text with the matched part called out, so a result can show *why*
/// it matched rather than just its first line.
///
/// Split into three plain strings rather than an `AttributedString` so the
/// windowing and ellipsis logic — the part that's easy to get wrong around the
/// start and end of a body — is testable without touching SwiftUI.
struct SearchSnippet: Equatable {
    /// Text before the match. Starts with an ellipsis when the window was cut.
    var leading: String
    /// The match, verbatim from the source (so its own casing shows).
    /// Empty when this field didn't match at all.
    var match: String
    /// Text after the match. Ends with an ellipsis when the window was cut.
    var trailing: String

    var isMatch: Bool { !match.isEmpty }
    /// The whole snippet as one string — what a copy or an accessibility label
    /// should read.
    var plain: String { leading + match + trailing }
}

/// Which shelf of the library a result came from. Results are grouped by this,
/// in this order — notes first because they're the things you deliberately
/// wrote, dictations next because they're what you search most, documents last
/// because they're the fewest and the easiest to find by name.
enum SearchCategory: String, CaseIterable, Identifiable {
    case notes, dictations, documents

    var id: String { rawValue }

    var title: String {
        switch self {
        case .notes:      return "Notes"
        case .dictations: return "Dictations"
        case .documents:  return "Documents"
        }
    }

    var icon: String {
        switch self {
        case .notes:      return "note.text"
        case .dictations: return "mic"
        case .documents:  return "doc.text"
        }
    }
}

/// One row of the cross-category results view.
struct SearchResult: Identifiable, Equatable {
    let id: UUID
    let category: SearchCategory
    let date: Date
    /// The item's name — a note's first line, a document's title. Carries its
    /// own snippet so a title match is highlighted where it happened.
    let title: SearchSnippet
    /// The matching part of the body. A dictation has no separate title, so
    /// this is the whole of what it shows.
    let body: SearchSnippet
    /// Cards for notes and documents, a bare line for dictations — the same two
    /// weights the Today stream uses, so results read like the stream does.
    let isAnchored: Bool
}

/// Cross-category search over the whole library.
///
/// **Only Today searches across categories.** The Notes and Documents pills
/// filter their own lists inline, because there a result you can't see the
/// category of is just a missing row; here the category *is* the structure.
enum Search {

    /// Everything matching `query`, grouped by category and newest-first within
    /// each. An empty or whitespace-only query returns nothing — the caller
    /// shows the day's stream instead of an empty results view.
    static func results(for query: String,
                        transcripts: [Transcript],
                        notes: [Note]) -> [SearchCategory: [SearchResult]] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [:] }

        var grouped: [SearchCategory: [SearchResult]] = [:]

        for note in notes {
            let first = firstLine(of: note.text)
            let title = snippet(in: first, query: needle)
            // Search the note *past* its first line, since that line is already
            // the title above it — otherwise a match in the title (the common
            // case, it being the note's name) is windowed twice and the result
            // card shows it twice.
            let body = snippet(in: bodyAfterFirstLine(of: note.text), query: needle)
            guard title.isMatch || body.isMatch else { continue }
            grouped[.notes, default: []].append(
                SearchResult(id: note.id, category: .notes, date: note.createdAt,
                             title: title, body: body, isAnchored: true))
        }

        for t in transcripts {
            let title = snippet(in: t.title, query: needle)
            let body = snippet(in: t.text, query: needle)
            guard title.isMatch || body.isMatch else { continue }
            let category: SearchCategory = t.source.isDocument ? .documents : .dictations
            grouped[category, default: []].append(
                SearchResult(id: t.id, category: category, date: t.createdAt,
                             title: title, body: body, isAnchored: t.source.isDocument))
        }

        // `grouped.keys` holds a reference to the dictionary, so mutating
        // through it while iterating copies on every step — snapshot first.
        for key in Array(grouped.keys) {
            // Tie-break on id for a stable order under equal timestamps, same
            // as the timeline.
            grouped[key]?.sort { ($0.date, $0.id.uuidString) > ($1.date, $1.id.uuidString) }
        }
        return grouped
    }

    /// Total across every category — the count shown beside the query.
    static func total(_ grouped: [SearchCategory: [SearchResult]]) -> Int {
        grouped.values.reduce(0) { $0 + $1.count }
    }

    /// A window of `text` around its first case-insensitive match for `query`.
    ///
    /// Windows around the match rather than truncating from the start, because
    /// the useful thing to show is the sentence the word is in — a match 400
    /// characters into a transcript is invisible if you always show the head.
    static func snippet(in text: String, query: String, window: Int = 42) -> SearchSnippet {
        // Every newline the platform recognises, not just \n — a snippet
        // promised to be one line shouldn't break on a stray \r or U+2028.
        let flattened = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard !query.isEmpty,
              let range = flattened.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
        else {
            // No match: show the head, so a result matched on its *other* field
            // still says something about itself.
            let head = String(flattened.prefix(window * 2))
            return SearchSnippet(leading: head.count < flattened.count ? head + "…" : head,
                                 match: "", trailing: "")
        }

        let leadingSource = flattened[flattened.startIndex..<range.lowerBound]
        let trailingSource = flattened[range.upperBound...]

        var leading = String(leadingSource.suffix(window))
        if leading.count < leadingSource.count { leading = "…" + leading }
        var trailing = String(trailingSource.prefix(window * 2))
        if trailing.count < trailingSource.count { trailing += "…" }

        return SearchSnippet(leading: leading,
                             match: String(flattened[range]),
                             trailing: trailing)
    }

    /// First line, for a note's stand-in title.
    private static func firstLine(of text: String) -> String {
        let line = text.prefix { !$0.isNewline }.trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? "New note" : line
    }

    /// Everything after the first line — the part a title doesn't already show.
    private static func bodyAfterFirstLine(of text: String) -> String {
        String(text.drop { !$0.isNewline }.drop { $0.isNewline })
    }
}
