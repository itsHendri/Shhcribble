import Foundation

/// What the Notes shelf is selecting — a note or a document.
///
/// **An enum rather than two optionals** (`noteID` + `documentID`), because two
/// optionals need a third bit saying which one is current and can silently
/// disagree with each other. Here the illegal state can't be written down, and
/// search's two jump destinations set it directly.
enum NoteListSelection: Hashable {
    case note(UUID)
    case document(UUID)

    /// The underlying row id, for `.id(...)` keying and comparisons.
    var id: UUID {
        switch self {
        case .note(let id), .document(let id): return id
        }
    }
}

/// One row of the merged shelf.
///
/// The two halves of the app used to be two rail items with two identical
/// master-details. They are one list now (2026-08-28): a written note and a
/// transcribed document differ in how they were made and how they're read, not
/// in what they're *for* — both are things you keep and come back to. What
/// still differs is the detail pane, which is why the row carries its case
/// rather than being flattened into a common struct.
enum NoteOrDocument: Identifiable, Equatable {
    case note(Note)
    case document(Transcript)

    var id: NoteListSelection {
        switch self {
        case .note(let n):     return .note(n.id)
        case .document(let t): return .document(t.id)
        }
    }

    /// When it landed — what the shelf sorts and groups by.
    var date: Date {
        switch self {
        case .note(let n):     return n.createdAt
        case .document(let t): return t.createdAt
        }
    }

    var isDocument: Bool {
        if case .document = self { return true }
        return false
    }

    /// On screen as a sticky right now — true for either kind since 2026-08-30.
    var isOnScreen: Bool {
        switch self {
        case .note(let n):     return n.stuck
        case .document(let t): return t.stuck
        }
    }

    /// The one-line title a row shows.
    var title: String {
        switch self {
        case .note(let n):     return NotesView.preview(n.text)
        case .document(let t): return t.menuTitle
        }
    }
}

/// Pure assembly of the Notes shelf, kept out of the view so "what order is the
/// list in" is a tested question rather than an inline sort.
enum NotesLibrary {

    /// Notes and documents interleaved, newest first.
    ///
    /// Tie-broken on the id so equal timestamps can't reorder between renders
    /// and churn `ForEach` identity — the same reason `Timeline.items` does it,
    /// and more likely here, since a note created from a document's action item
    /// can share its second.
    static func merged(notes: [Note], documents: [Transcript]) -> [NoteOrDocument] {
        let rows = notes.map(NoteOrDocument.note) + documents.map(NoteOrDocument.document)
        return rows.sorted {
            ($0.date, $0.id.id.uuidString) > ($1.date, $1.id.id.uuidString)
        }
    }

    /// The shelf split into its two groups: what's on your screen right now,
    /// then everything else in date order.
    ///
    /// **Exhaustive by construction** — `onScreen` and `rest` are exact
    /// complements, so no row can be dropped or shown twice. That is the
    /// assertion the merged list rests on, which is why it's here and tested
    /// rather than a pair of inline filters.
    ///
    /// **Documents can be on screen too** as of 2026-08-30 (Hendri's ruling that
    /// a document can be pinned) — this used to test only notes.
    static func partitioned(_ rows: [NoteOrDocument])
    -> (onScreen: [NoteOrDocument], rest: [NoteOrDocument]) {
        var onScreen: [NoteOrDocument] = []
        var rest: [NoteOrDocument] = []
        for row in rows {
            if row.isOnScreen { onScreen.append(row) } else { rest.append(row) }
        }
        return (onScreen, rest)
    }
}

/// One tab in the sticky panel.
///
/// Parallel to `NoteOrDocument` but deliberately a separate type: the shelf row
/// and the sticky tab answer different questions (a row needs a list title and a
/// group; a tab needs what to render and whether it can be edited), and folding
/// them together would put list concerns inside the panel.
///
/// The asymmetry that matters: **a note tab is editable, a document tab is
/// not.** Everything in `StickyTabsModel` about saving, debouncing and pending
/// edits applies only to the note case.
enum StickyItem: Identifiable, Equatable {
    case note(Note)
    case document(Transcript)

    var id: UUID {
        switch self {
        case .note(let n):     return n.id
        case .document(let t): return t.id
        }
    }

    var createdAt: Date {
        switch self {
        case .note(let n):     return n.createdAt
        case .document(let t): return t.createdAt
        }
    }

    /// Tab label. A note has no title of its own, so it borrows its first line.
    var tabTitle: String {
        switch self {
        case .note(let n):     return NotesView.preview(n.text)
        case .document(let t): return t.menuTitle
        }
    }

    var isDocument: Bool {
        if case .document = self { return true }
        return false
    }

    /// What a stuck document puts on screen: its **summary**, falling back to
    /// the transcript when none has been generated yet.
    ///
    /// Ruled with Hendri 2026-08-30. A 40-minute transcript is unreadable in a
    /// small card, and the summary is the part worth having in front of you —
    /// but falling back matters, because summaries are generated on demand and
    /// most documents won't have one when they're first put on screen.
    var documentBody: String? {
        guard case .document(let t) = self else { return nil }
        if let summary = t.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return summary
        }
        return t.text
    }

    /// Whether the body above is the summary rather than the raw transcript —
    /// the card says which, so a fallback never reads as a failed summary.
    var isShowingSummary: Bool {
        guard case .document(let t) = self else { return false }
        guard let summary = t.summary else { return false }
        return !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
