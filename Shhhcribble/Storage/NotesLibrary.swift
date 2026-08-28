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
}
