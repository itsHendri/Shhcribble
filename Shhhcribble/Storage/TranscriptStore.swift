import Foundation
import SQLite3
import os

/// Where a transcript came from — a live hotkey dictation, or a file the user
/// dropped/opened. Drives the icon in the Transcriptions list and whether a
/// source file exists on disk.
enum TranscriptSource: String, Codable, Equatable {
    case dictation
    case file
}

/// One stored transcript. `text` is the cleaned/final version (what Copy and
/// Save write); `rawText` is the pre-cleanup transcript kept separately so the
/// original is never lost (Granola's raw-vs-enhanced split — see ROADMAP Phase B).
struct Transcript: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    var source: TranscriptSource
    var title: String
    var text: String
    var rawText: String
    var fileName: String?
    var sourcePath: String?
    var durationSec: Double?

    /// On-device AI summary of `text`, generated on demand from the Studio
    /// Summary tab. `nil` until the user generates one. `actionItems` is the
    /// parallel list of extracted to-dos (empty when there are none), and
    /// `summaryGeneratedAt` timestamps the current summary (Regenerate replaces
    /// all three). Full version history is deferred — see CLAUDE.md.
    var summary: String? = nil
    var actionItems: [String] = []
    var summaryGeneratedAt: Date? = nil

    /// Free-text notes the user writes themselves in the Studio Notes tab.
    /// Empty string = no notes. Independent of `summary` (AI) and `rawText`.
    var notes: String = ""

    /// The transform style that shaped this dictation. `styleID` is the live link
    /// (the UI shows the style's *current* name, so a rename propagates to old
    /// tags); `styleName` is a snapshot fallback for when the style is later
    /// deleted. Both `nil` for Default clean-up / Off / file transcripts — so a
    /// tag shows only when a real style was applied.
    var styleName: String? = nil
    var styleID: String? = nil

    /// Menu / list title, truncated for one-line display.
    var menuTitle: String {
        let base = title.isEmpty ? text : title
        let prefix = String(base.prefix(60))
        return base.count > 60 ? "\(prefix)…" : prefix
    }
}

/// One note — the Notes module's single entity (2026-07-23).
///
/// `text` is the **plain-text mirror** (search, list previews, copy, .txt
/// export); `richText` is the RTF blob carrying bold/italic/underline and link
/// runs, `nil` until the note is saved from the rich editor. `text` is always
/// kept in sync with the rich content, so every read-only surface can ignore
/// `richText` entirely.
///
/// A **sticky** is a note with `pinned` (floating panel at `pinX`/`pinY`, sized
/// `pinW`/`pinH`). A note added from a transcript's AI action items carries
/// `sourceTranscriptID` + the verbatim `sourceActionItem` string, which is how
/// the Summary tab resolves "already added" even after the note's `text` is
/// edited. CloudKit-migration friendly by design: every column optional or
/// defaulted, no unique constraints beyond the PK.
///
/// **Tasks + reminders were cut from the UI 2026-07-23** (human's call — "let's
/// just make these notes for now"). Their columns (`isTask`, `done`,
/// `completedAt`, `dueAt`, `reminderFiredAt`) stay in the table, unread and
/// unwritten, so restoring them is a UI-only change and no existing row was
/// destroyed. See the CLAUDE.md deferred-features entry for the commit to port.
struct Note: Identifiable, Equatable {
    let id: UUID
    let createdAt: Date
    var modifiedAt: Date
    var text: String
    /// RTF encoding of the styled body — see `RichText`.
    var richText: Data? = nil
    var pinned: Bool = false
    /// Persisted sticky-panel origin (bottom-left, screen coordinates) and
    /// size (the sticky is user-resizable; nil = default size).
    var pinX: Double? = nil
    var pinY: Double? = nil
    var pinW: Double? = nil
    var pinH: Double? = nil
    var sourceTranscriptID: UUID? = nil
    var sourceActionItem: String? = nil

    init(id: UUID = UUID(), createdAt: Date = Date(), modifiedAt: Date = Date(), text: String) {
        self.id = id
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.text = text
    }
}

/// SQLite-backed store for all transcripts (dictation + file), replacing the
/// cap-10 UserDefaults history. Deliberately a thin wrapper over the system
/// `libsqlite3` (imported via the `SQLite3` module, which auto-links the system
/// dylib through its module map) — **no external dependency and no embedded
/// dynamic framework**, which is what keeps the ad-hoc DMG shippable without a
/// Developer ID cert (see CLAUDE.md "Sparkle auto-update"). Search is `LIKE`
/// today; FTS5 is a cheap later upgrade.
///
/// `@MainActor` + `ObservableObject`: the whole store lives on the main thread
/// (inserts are sub-millisecond) and publishes `transcripts` for SwiftUI. File
/// transcription does its heavy work off-main and hops back here only to persist.
@MainActor
final class TranscriptStore: ObservableObject {

    /// Newest first. The single source of truth the UI binds to.
    @Published private(set) var transcripts: [Transcript] = []

    /// Personal Dictionary entries, in apply order (position ascending). The
    /// dictation / file / live-preview paths snapshot this on the main actor and
    /// pass it into the off-main `TranscriptPipeline`; Settings binds to it live.
    @Published private(set) var dictionaryEntries: [DictionaryEntry] = []

    /// User/seeded transform styles. The Styles UI binds to this live; the
    /// dictation path snapshots it to resolve the active/per-app style. The
    /// synthetic Off + Default clean-up entries are NOT in here (see `ActiveStyle`).
    @Published private(set) var styles: [Style] = []

    /// Notes/tasks/stickies, in position order (creation order; dense, like the
    /// dictionary). The Notes tab, sticky panels, and reminder scheduler all
    /// bind to this.
    @Published private(set) var notes: [Note] = []

    /// Styles in case-insensitive alphabetical order — the display order for the
    /// picker, the Styles list, and the menu-bar quick-pick. (Ordering is purely a
    /// display choice; the stored array is unordered as far as the UI is concerned.)
    var stylesAlphabetical: [Style] {
        styles.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var db: OpaquePointer?
    private let log = Logger(subsystem: "com.shhhcribble.app", category: "store")

    /// SQLite wants a copy of bound strings — its default is to reference the
    /// caller's buffer, which is freed before `step`. Force a transient copy.
    private static let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// - Parameter path: on-disk DB location. Pass `":memory:"` (the default in
    ///   tests) for an ephemeral DB; production uses `defaultDatabaseURL`.
    init(path: String) {
        openDatabase(at: path)
        createSchema()
        migrateSchema()
        reload()
        reloadDictionary()
        reloadStyles()
        reloadNotesTable()
    }

    /// Production store at Application Support/Shhhcribble/transcripts.sqlite,
    /// migrating any legacy UserDefaults history on first run.
    static func makeDefault() -> TranscriptStore {
        let store = TranscriptStore(path: defaultDatabaseURL().path)
        store.migrateLegacyHistoryIfNeeded()
        store.migrateLegacyDictionaryIfNeeded()
        store.migrateTranscriptNotesIfNeeded()
        store.seedExampleDictionaryIfNeeded()
        store.seedBuiltInStylesIfNeeded()
        store.refreshBuiltInStylePromptsIfNeeded()
        return store
    }

    static func defaultDatabaseURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Shhhcribble", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("transcripts.sqlite")
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    // MARK: - Public API

    /// Insert a new transcript at the top and persist it.
    func add(_ t: Transcript) {
        guard insert(t) else { return }
        transcripts.insert(t, at: 0)
    }

    /// Convenience for the dictation path: build a `.dictation` transcript from
    /// cleaned + raw text and store it. Returns the stored record.
    @discardableResult
    func addDictation(text: String, rawText: String, styleName: String? = nil, styleID: String? = nil, date: Date = Date()) -> Transcript {
        var t = Transcript(
            id: UUID(), createdAt: date, source: .dictation,
            title: Self.title(from: text), text: text, rawText: rawText,
            fileName: nil, sourcePath: nil, durationSec: nil
        )
        t.styleName = styleName
        t.styleID = styleID
        add(t)
        return t
    }

    func delete(_ id: UUID) {
        exec("DELETE FROM transcripts WHERE id = ?;") { stmt in
            sqlite3_bind_text(stmt, 1, id.uuidString, -1, Self.SQLITE_TRANSIENT)
        }
        transcripts.removeAll { $0.id == id }
    }

    func clearAll() {
        exec("DELETE FROM transcripts;", bind: nil)
        transcripts.removeAll()
    }

    /// Persist a generated (or regenerated) summary + action items for a
    /// transcript and update the in-memory copy so the UI refreshes. No-op if the
    /// id isn't found.
    func updateSummary(id: UUID, summary: String, actionItems: [String], generatedAt: Date = Date()) {
        guard let idx = transcripts.firstIndex(where: { $0.id == id }) else { return }
        exec("UPDATE transcripts SET summary = ?, actionItems = ?, summaryGeneratedAt = ? WHERE id = ?;") { stmt in
            sqlite3_bind_text(stmt, 1, summary, -1, Self.SQLITE_TRANSIENT)
            self.bindOptionalText(stmt, 2, Self.encodeActionItems(actionItems))
            sqlite3_bind_double(stmt, 3, generatedAt.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 4, id.uuidString, -1, Self.SQLITE_TRANSIENT)
        }
        transcripts[idx].summary = summary
        transcripts[idx].actionItems = actionItems
        transcripts[idx].summaryGeneratedAt = generatedAt
    }

    /// Persist the user's free-text notes for a transcript and update the
    /// in-memory copy so the UI refreshes. No-op if the id isn't found.
    func updateNotes(id: UUID, notes: String) {
        guard let idx = transcripts.firstIndex(where: { $0.id == id }) else { return }
        exec("UPDATE transcripts SET notes = ? WHERE id = ?;") { stmt in
            self.bindOptionalText(stmt, 1, notes.isEmpty ? nil : notes)
            sqlite3_bind_text(stmt, 2, id.uuidString, -1, Self.SQLITE_TRANSIENT)
        }
        transcripts[idx].notes = notes
    }

    // MARK: - Personal Dictionary
    //
    // Mirrors the `updateNotes` template: every mutation does a SQL write plus an
    // in-memory `@Published` mutation so the Settings UI refreshes. `position` is
    // kept equal to the array index (0-based, dense) — the simplest robust scheme
    // for small lists, and `reloadDictionary`'s `ORDER BY position ASC` reproduces
    // the array exactly.

    /// Append a new entry at the end of the list. Guards the INSERT before the
    /// in-memory mutation so we never show a row the DB doesn't have.
    func addDictionaryEntry(_ entry: DictionaryEntry) {
        let position = dictionaryEntries.count
        guard exec("""
        INSERT INTO dictionary_entries (id, phrase, replacement, caseSensitive, position)
        VALUES (?, ?, ?, ?, ?);
        """, bind: { stmt in
            sqlite3_bind_text(stmt, 1, entry.id.uuidString, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, entry.phrase, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, entry.replacement, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 4, entry.caseSensitive ? 1 : 0)
            sqlite3_bind_int(stmt, 5, Int32(position))
        }) else { return }
        dictionaryEntries.append(entry)
    }

    /// Bulk-append entries in order (the "paste a word list" import). Each goes
    /// through `addDictionaryEntry`, so positions stay dense and the `@Published`
    /// array updates per row.
    func addDictionaryEntries(_ entries: [DictionaryEntry]) {
        for entry in entries { addDictionaryEntry(entry) }
    }

    private static let dictionarySeedFlagKey = "didSeedExampleDictionary"

    /// One-shot on first launch: drop a few starter entries into an *empty*
    /// dictionary so the feature isn't a blank slate. Runs once ever (flag) and
    /// only while empty, so a returning user (or the legacy migration) keeps their
    /// own entries and nothing is re-seeded after they delete the examples. These
    /// are ordinary entries — real mis-hearings the model tends to produce, plus a
    /// couple of names — meant to be edited or removed freely.
    func seedExampleDictionaryIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.dictionarySeedFlagKey) else { return }
        guard db != nil else { return }   // DB not open — retry next launch
        defer { defaults.set(true, forKey: Self.dictionarySeedFlagKey) }
        guard dictionaryEntries.isEmpty else { return }

        let examples: [(String, String)] = [
            ("scribble, shribble, shcribble", "Shhhcribble"),
            ("henry, hendry, henri", "Hendri"),
            ("tury, turi, tewri", "Tiuri"),
        ]
        addDictionaryEntries(examples.map {
            DictionaryEntry(phrase: $0.0, replacement: $0.1, caseSensitive: false)
        })
        log.notice("Seeded \(examples.count) example dictionary entries.")
    }

    /// Update an existing entry's editable fields (id + position unchanged).
    func updateDictionaryEntry(id: UUID, phrase: String, replacement: String, caseSensitive: Bool) {
        guard let idx = dictionaryEntries.firstIndex(where: { $0.id == id }) else { return }
        exec("UPDATE dictionary_entries SET phrase = ?, replacement = ?, caseSensitive = ? WHERE id = ?;") { stmt in
            sqlite3_bind_text(stmt, 1, phrase, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, replacement, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 3, caseSensitive ? 1 : 0)
            sqlite3_bind_text(stmt, 4, id.uuidString, -1, Self.SQLITE_TRANSIENT)
        }
        dictionaryEntries[idx].phrase = phrase
        dictionaryEntries[idx].replacement = replacement
        dictionaryEntries[idx].caseSensitive = caseSensitive
    }

    /// Delete an entry, then renumber the remaining rows so positions stay a
    /// dense 0..<count sequence (no gaps).
    func deleteDictionaryEntry(id: UUID) {
        guard let idx = dictionaryEntries.firstIndex(where: { $0.id == id }) else { return }
        exec("DELETE FROM dictionary_entries WHERE id = ?;") { stmt in
            sqlite3_bind_text(stmt, 1, id.uuidString, -1, Self.SQLITE_TRANSIENT)
        }
        dictionaryEntries.remove(at: idx)
        renumberDictionaryPositions(from: idx)
    }

    /// Move an entry up (`offset == -1`) or down (`offset == +1`), matching the
    /// Settings up/down buttons. No-op if the target index is out of range.
    func moveDictionaryEntry(at index: Int, by offset: Int) {
        let target = index + offset
        guard dictionaryEntries.indices.contains(index),
              dictionaryEntries.indices.contains(target) else { return }
        dictionaryEntries.swapAt(index, target)
        persistDictionaryPosition(at: index)
        persistDictionaryPosition(at: target)
    }

    /// Write one array slot's index as its stored `position`.
    private func persistDictionaryPosition(at index: Int) {
        guard dictionaryEntries.indices.contains(index) else { return }
        let entry = dictionaryEntries[index]
        exec("UPDATE dictionary_entries SET position = ? WHERE id = ?;") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(index))
            sqlite3_bind_text(stmt, 2, entry.id.uuidString, -1, Self.SQLITE_TRANSIENT)
        }
    }

    /// After a delete, rewrite `position` = array index for every entry from
    /// `start` onward so stored positions stay contiguous and match array order.
    private func renumberDictionaryPositions(from start: Int) {
        guard start < dictionaryEntries.count else { return }
        for i in start..<dictionaryEntries.count { persistDictionaryPosition(at: i) }
    }

    // MARK: - Custom Styles
    //
    // Mirrors the Personal Dictionary CRUD template exactly: guard the SQL write,
    // then mutate the `@Published styles` array; `position` == array index
    // (0-based, dense); `reloadStyles`' `ORDER BY position ASC` reproduces the
    // array. Only difference is `activationApps`, serialized as a JSON string.

    /// Append a new style at the end of the list.
    func addStyle(_ style: Style) {
        let position = styles.count
        guard exec("""
        INSERT INTO styles (id, name, prompt, activationApps, isBuiltIn, position)
        VALUES (?, ?, ?, ?, ?, ?);
        """, bind: { stmt in
            sqlite3_bind_text(stmt, 1, style.id.uuidString, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, style.name, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, style.prompt, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, Self.encodeApps(style.activationApps), -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_int(stmt, 5, style.isBuiltIn ? 1 : 0)
            sqlite3_bind_int(stmt, 6, Int32(position))
        }) else { return }
        styles.append(style)
    }

    /// Update an existing style's editable fields (id + position unchanged).
    func updateStyle(id: UUID, name: String, prompt: String, activationApps: [String]) {
        guard let idx = styles.firstIndex(where: { $0.id == id }) else { return }
        exec("UPDATE styles SET name = ?, prompt = ?, activationApps = ? WHERE id = ?;") { stmt in
            sqlite3_bind_text(stmt, 1, name, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, prompt, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 3, Self.encodeApps(activationApps), -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, id.uuidString, -1, Self.SQLITE_TRANSIENT)
        }
        styles[idx].name = name
        styles[idx].prompt = prompt
        styles[idx].activationApps = activationApps
    }

    /// Delete a style, then renumber remaining rows so positions stay dense.
    func deleteStyle(id: UUID) {
        guard let idx = styles.firstIndex(where: { $0.id == id }) else { return }
        exec("DELETE FROM styles WHERE id = ?;") { stmt in
            sqlite3_bind_text(stmt, 1, id.uuidString, -1, Self.SQLITE_TRANSIENT)
        }
        styles.remove(at: idx)
        renumberStylePositions(from: idx)
    }

    /// Move a style up (`offset == -1`) or down (`offset == +1`).
    func moveStyle(at index: Int, by offset: Int) {
        let target = index + offset
        guard styles.indices.contains(index), styles.indices.contains(target) else { return }
        styles.swapAt(index, target)
        persistStylePosition(at: index)
        persistStylePosition(at: target)
    }

    private func persistStylePosition(at index: Int) {
        guard styles.indices.contains(index) else { return }
        let style = styles[index]
        exec("UPDATE styles SET position = ? WHERE id = ?;") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(index))
            sqlite3_bind_text(stmt, 2, style.id.uuidString, -1, Self.SQLITE_TRANSIENT)
        }
    }

    private func renumberStylePositions(from start: Int) {
        guard start < styles.count else { return }
        for i in start..<styles.count { persistStylePosition(at: i) }
    }

    private static let stylesSeedFlagKey = "didSeedBuiltInStyles"

    /// One-shot on first launch: drop the editable preset styles into an *empty*
    /// styles table. Runs once ever (flag) and only while empty, so a returning
    /// user keeps their own styles and nothing is re-seeded after they delete a
    /// preset. Presets are ordinary rows (`isBuiltIn = true`) — fully editable
    /// and deletable. Prompts frame the transcript as content to reformat.
    func seedBuiltInStylesIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.stylesSeedFlagKey) else { return }
        guard db != nil else { return }   // DB not open — retry next launch
        defer { defaults.set(true, forKey: Self.stylesSeedFlagKey) }
        guard styles.isEmpty else { return }

        for style in Style.seededPresets { addStyle(style) }
        log.notice("Seeded \(Style.seededPresets.count) built-in styles.")
    }

    private static let stylesPromptRefreshFlagKey = "didRefreshBuiltInStylePromptsV2"

    /// One-shot: upgrade the *prompt text* of the built-in preset styles to the
    /// current `Style.seededPresets` bodies (matched by name), in place. Lets an
    /// existing install pick up improved preset prompts without re-seeding or
    /// disturbing positions, activation apps, or the user's own custom styles
    /// (only `isBuiltIn` rows are touched). Runs once (flag); a fresh seed already
    /// has the latest text, so this is then a no-op.
    func refreshBuiltInStylePromptsIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.stylesPromptRefreshFlagKey) else { return }
        guard db != nil else { return }
        defer { defaults.set(true, forKey: Self.stylesPromptRefreshFlagKey) }

        let byName = Dictionary(uniqueKeysWithValues: Style.seededPresets.map { ($0.name, $0.prompt) })
        var updated = 0
        for (idx, style) in styles.enumerated() where style.isBuiltIn {
            guard let prompt = byName[style.name], prompt != style.prompt else { continue }
            exec("UPDATE styles SET prompt = ? WHERE id = ?;") { stmt in
                sqlite3_bind_text(stmt, 1, prompt, -1, Self.SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, style.id.uuidString, -1, Self.SQLITE_TRANSIENT)
            }
            styles[idx].prompt = prompt
            updated += 1
        }
        if updated > 0 { log.notice("Refreshed \(updated) built-in style prompts.") }
    }

    // MARK: - Notes / Tasks / Stickies
    //
    // Mirrors the dictionary/styles CRUD template: guard the SQL write, then
    // mutate the `@Published notes` array; `position` == array index (0-based,
    // dense); `reloadNotesTable`'s `ORDER BY position ASC` reproduces the array.
    // Dates are stored as epoch REALs, matching the transcripts table.

    /// Append a new note at the end of the list.
    func addNote(_ note: Note) {
        let position = notes.count
        guard exec("""
        INSERT INTO notes
        (id, createdAt, modifiedAt, text, richText,
         pinned, pinX, pinY, pinW, pinH, sourceTranscriptID, sourceActionItem, position)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, bind: { stmt in
            sqlite3_bind_text(stmt, 1, note.id.uuidString, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, note.createdAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 3, note.modifiedAt.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 4, note.text, -1, Self.SQLITE_TRANSIENT)
            self.bindOptionalBlob(stmt, 5, note.richText)
            sqlite3_bind_int(stmt, 6, note.pinned ? 1 : 0)
            self.bindOptionalDouble(stmt, 7, note.pinX)
            self.bindOptionalDouble(stmt, 8, note.pinY)
            self.bindOptionalDouble(stmt, 9, note.pinW)
            self.bindOptionalDouble(stmt, 10, note.pinH)
            self.bindOptionalText(stmt, 11, note.sourceTranscriptID?.uuidString)
            self.bindOptionalText(stmt, 12, note.sourceActionItem)
            sqlite3_bind_int(stmt, 13, Int32(position))
        }) else { return }
        notes.append(note)
    }

    /// Persist every mutable field of an existing note (id, createdAt, position
    /// unchanged) and stamp `modifiedAt`. The one write path for edits from the
    /// Notes tab, stickies, check-offs, and the reminder scheduler — a whole-row
    /// update is simpler and safer here than per-field variants, because callers
    /// hold a full `Note` value anyway.
    func updateNote(_ note: Note, modifiedAt: Date = Date()) {
        guard let idx = notes.firstIndex(where: { $0.id == note.id }) else { return }
        var updated = note
        updated.modifiedAt = modifiedAt
        // Guarded like `addNote`: if the write fails (full disk, locked DB) the
        // in-memory row must NOT change, or the editor would keep showing text
        // that is already gone from disk and the loss would only surface at the
        // next launch.
        guard exec("""
        UPDATE notes SET modifiedAt = ?, text = ?, richText = ?,
        pinned = ?, pinX = ?, pinY = ?, pinW = ?, pinH = ?,
        sourceTranscriptID = ?, sourceActionItem = ? WHERE id = ?;
        """, bind: { stmt in
            sqlite3_bind_double(stmt, 1, updated.modifiedAt.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, updated.text, -1, Self.SQLITE_TRANSIENT)
            self.bindOptionalBlob(stmt, 3, updated.richText)
            sqlite3_bind_int(stmt, 4, updated.pinned ? 1 : 0)
            self.bindOptionalDouble(stmt, 5, updated.pinX)
            self.bindOptionalDouble(stmt, 6, updated.pinY)
            self.bindOptionalDouble(stmt, 7, updated.pinW)
            self.bindOptionalDouble(stmt, 8, updated.pinH)
            self.bindOptionalText(stmt, 9, updated.sourceTranscriptID?.uuidString)
            self.bindOptionalText(stmt, 10, updated.sourceActionItem)
            sqlite3_bind_text(stmt, 11, updated.id.uuidString, -1, Self.SQLITE_TRANSIENT)
        }) else { return }
        notes[idx] = updated
    }

    /// Delete a note, then renumber remaining rows so positions stay dense.
    func deleteNote(id: UUID) {
        guard let idx = notes.firstIndex(where: { $0.id == id }) else { return }
        exec("DELETE FROM notes WHERE id = ?;") { stmt in
            sqlite3_bind_text(stmt, 1, id.uuidString, -1, Self.SQLITE_TRANSIENT)
        }
        notes.remove(at: idx)
        renumberNotePositions(from: idx)
    }

    /// Pin/unpin a note to the screen. Pinning may carry an initial origin
    /// (bottom-left screen coords); unpinning keeps the last origin so re-pinning
    /// restores the old spot.
    ///
    /// `modifiedAt` is preserved: where a note is displayed is not a change to
    /// what it says, and bumping it would label an untouched note "Edited" just
    /// for being pinned (`updateNotePinFrame` preserves it for the same reason).
    func setNotePinned(id: UUID, pinned: Bool, origin: CGPoint? = nil) {
        guard var note = notes.first(where: { $0.id == id }) else { return }
        note.pinned = pinned
        if let origin {
            note.pinX = origin.x
            note.pinY = origin.y
        }
        updateNote(note, modifiedAt: note.modifiedAt)
    }

    /// Persist a sticky's dragged/resized frame without touching `modifiedAt`
    /// semantics elsewhere (it's still an update; frame moves aren't edits
    /// worth surfacing, but the single write path keeps the code simple).
    func updateNotePinFrame(id: UUID, frame: CGRect) {
        guard var note = notes.first(where: { $0.id == id }) else { return }
        note.pinX = frame.origin.x
        note.pinY = frame.origin.y
        note.pinW = frame.size.width
        note.pinH = frame.size.height
        updateNote(note, modifiedAt: note.modifiedAt)
    }

    /// The note previously added from this transcript action item, if any.
    /// Matches on the *verbatim* item string captured at the time, so the link
    /// survives later edits of the note's own `text`.
    func noteForActionItem(transcriptID: UUID, item: String) -> Note? {
        notes.first { $0.sourceTranscriptID == transcriptID && $0.sourceActionItem == item }
    }

    /// Add a transcript action item to Notes. Idempotent: if the item was
    /// already added, returns the existing note untouched.
    @discardableResult
    func promoteActionItem(transcriptID: UUID, item: String) -> Note {
        if let existing = noteForActionItem(transcriptID: transcriptID, item: item) {
            return existing
        }
        var note = Note(text: item)
        note.sourceTranscriptID = transcriptID
        note.sourceActionItem = item
        addNote(note)
        return note
    }

    private func persistNotePosition(at index: Int) {
        guard notes.indices.contains(index) else { return }
        let note = notes[index]
        exec("UPDATE notes SET position = ? WHERE id = ?;") { stmt in
            sqlite3_bind_int(stmt, 1, Int32(index))
            sqlite3_bind_text(stmt, 2, note.id.uuidString, -1, Self.SQLITE_TRANSIENT)
        }
    }

    private func renumberNotePositions(from start: Int) {
        guard start < notes.count else { return }
        for i in start..<notes.count { persistNotePosition(at: i) }
    }

    /// Case-insensitive substring match over title + text, newest first.
    /// Empty query returns everything (already newest-first in `transcripts`).
    ///
    /// `notes` is deliberately **not** searched: per-transcript notes moved out
    /// into the Notes module (which has its own search), so matching a
    /// transcript on text the reader no longer shows would be a dead end.
    func matching(_ query: String) -> [Transcript] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return transcripts }
        let needle = q.lowercased()
        return transcripts.filter {
            $0.title.lowercased().contains(needle) || $0.text.lowercased().contains(needle)
        }
    }

    /// Transcripts that belong in the **Documents** tab — long-form material you
    /// keep, as opposed to the quick dictations that pass through Today.
    ///
    /// Today that means file imports only. Call captures still store as
    /// `.dictation` with a "Call —" title (the v1 gap), so they don't qualify
    /// yet; **redesign phase 3 gives them a real source category, and this
    /// method is where that change lands** — one tested place, rather than a
    /// predicate spread across the views.
    func documents(matching query: String) -> [Transcript] {
        matching(query).filter { $0.source == .file }
    }

    /// Notes the user pinned. Pin (importance) and stick (urgency) are still the
    /// one flag; **redesign phase 2 splits them here**, at which point this gains
    /// a `stuckNotes` sibling and the callers keep working.
    var pinnedNotes: [Note] {
        // Tie-break on id: `sorted(by:)` isn't stable, so equal timestamps could
        // otherwise reorder between renders and churn `ForEach` identity.
        notes.filter(\.pinned).sorted {
            ($0.modifiedAt, $0.id.uuidString) > ($1.modifiedAt, $1.id.uuidString)
        }
    }

    /// First ~60 chars of the first line, for use as a dictation title.
    static func title(from text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
        let prefix = String(trimmed.prefix(60))
        return trimmed.count > 60 ? "\(prefix)…" : prefix
    }

    // MARK: - Migration

    private static let migrationFlagKey = "didMigrateHistoryToSQLite"

    /// One-shot import of the legacy `transcriptionHistory` UserDefaults JSON
    /// (`[{text,date}]`) into the DB as `.dictation` rows. The old key is left
    /// in place (harmless) so a rollback build still finds its history.
    func migrateLegacyHistoryIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.migrationFlagKey) else { return }
        // If the DB failed to open, don't mark migrated — retry next launch so
        // the legacy history isn't silently marked done and lost.
        guard db != nil else { return }
        defer { defaults.set(true, forKey: Self.migrationFlagKey) }

        guard let data = defaults.data(forKey: "transcriptionHistory"),
              let legacy = try? JSONDecoder().decode([LegacyEntry].self, from: data),
              !legacy.isEmpty else { return }

        // Legacy stored newest-first; insert oldest-first so the newest ends up
        // at the top of `transcripts` after each prepend.
        for entry in legacy.reversed() {
            let t = Transcript(
                id: UUID(), createdAt: entry.date, source: .dictation,
                title: Self.title(from: entry.text), text: entry.text, rawText: entry.text,
                fileName: nil, sourcePath: nil, durationSec: nil
            )
            add(t)
        }
        log.notice("Migrated \(legacy.count) legacy history entries into SQLite.")
    }

    private struct LegacyEntry: Codable {
        let text: String
        let date: Date
    }

    private static let transcriptNotesMigrationFlagKey = "didMigrateTranscriptNotesToNotes"

    /// One-shot: lift any per-transcript notes (the retired third tab in the
    /// transcript reader) out into standalone `Note` rows, linked back by
    /// `sourceTranscriptID`. Notes became their own module 2026-07-23, so
    /// leaving this text reachable only through a tab that no longer exists
    /// would silently hide it.
    ///
    /// The `transcripts.notes` column is **not** cleared — same rollback
    /// discipline as the legacy UserDefaults keys, and it's what makes a
    /// re-run harmless: the flag plus the `sourceActionItem` sentinel below
    /// keep an interrupted-then-retried migration from duplicating rows.
    func migrateTranscriptNotesIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.transcriptNotesMigrationFlagKey) else { return }
        guard db != nil else { return }   // DB not open — retry next launch
        defer { defaults.set(true, forKey: Self.transcriptNotesMigrationFlagKey) }

        let withNotes = transcripts.filter { !$0.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !withNotes.isEmpty else { return }

        // Oldest first so the resulting notes read in the same order as the
        // transcripts they came from.
        for transcript in withNotes.reversed() {
            // Sentinel marks "this came from the transcript notes tab", and
            // doubles as the idempotency key if this ever runs twice.
            let sentinel = "__transcriptNotes__"
            guard noteForActionItem(transcriptID: transcript.id, item: sentinel) == nil else { continue }
            var note = Note(createdAt: transcript.createdAt, modifiedAt: transcript.createdAt,
                            text: transcript.notes)
            note.sourceTranscriptID = transcript.id
            note.sourceActionItem = sentinel
            addNote(note)
        }
        log.notice("Migrated \(withNotes.count) transcript notes into standalone notes.")
    }

    private static let dictionaryMigrationFlagKey = "didMigrateDictionaryToSQLite"

    /// One-shot import of the legacy `dictionaryEntries` UserDefaults JSON
    /// (`[DictionaryEntry]`) into the `dictionary_entries` table, order preserved.
    /// The old key is left in place (harmless) so a rollback build still finds it.
    ///
    /// Unlike history migration (which mints fresh UUIDs each attempt), dictionary
    /// entries carry stable ids from the JSON, so a retried-after-interruption
    /// import would hit PRIMARY KEY conflicts. Clearing the table (+ the in-memory
    /// array) first makes a retry start clean — safe because this only runs before
    /// the dictionary is ever used.
    func migrateLegacyDictionaryIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.dictionaryMigrationFlagKey) else { return }
        // If the DB failed to open, don't mark migrated — retry next launch.
        guard db != nil else { return }
        defer { defaults.set(true, forKey: Self.dictionaryMigrationFlagKey) }

        guard let data = defaults.data(forKey: "dictionaryEntries"),
              let legacy = try? JSONDecoder().decode([DictionaryEntry].self, from: data),
              !legacy.isEmpty else { return }

        // Start clean so an interrupted-then-retried import can't collide on ids.
        exec("DELETE FROM dictionary_entries;", bind: nil)
        dictionaryEntries.removeAll()

        // Legacy JSON is already in apply-order; insert in order so position = index.
        for entry in legacy { addDictionaryEntry(entry) }
        log.notice("Migrated \(legacy.count) legacy dictionary entries into SQLite.")
    }

    // MARK: - SQLite plumbing

    private func openDatabase(at path: String) {
        if sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            log.error("Failed to open SQLite DB at \(path, privacy: .public): \(String(cString: sqlite3_errmsg(self.db)))")
            sqlite3_close(db)
            db = nil
        }
    }

    private func createSchema() {
        exec("""
        CREATE TABLE IF NOT EXISTS transcripts (
            id TEXT PRIMARY KEY,
            createdAt REAL NOT NULL,
            source TEXT NOT NULL,
            title TEXT NOT NULL,
            text TEXT NOT NULL,
            rawText TEXT NOT NULL,
            fileName TEXT,
            sourcePath TEXT,
            durationSec REAL
        );
        """, bind: nil)
        exec("CREATE INDEX IF NOT EXISTS idx_transcripts_createdAt ON transcripts(createdAt DESC);", bind: nil)

        // Personal Dictionary lives in its own table (position-ordered). Created
        // idempotently here so a fresh DB and an upgraded one take the same path;
        // `migrateSchema` only records the version bump (see v3 there).
        exec("""
        CREATE TABLE IF NOT EXISTS dictionary_entries (
            id TEXT PRIMARY KEY,
            phrase TEXT NOT NULL,
            replacement TEXT NOT NULL,
            caseSensitive INTEGER NOT NULL DEFAULT 0,
            position INTEGER NOT NULL
        );
        """, bind: nil)
        exec("CREATE INDEX IF NOT EXISTS idx_dictionary_position ON dictionary_entries(position ASC);", bind: nil)

        // Custom Styles live in their own table (position-ordered), created
        // idempotently here for the same reason as dictionary_entries; the v4
        // `migrateSchema` step only records the version bump. `activationApps`
        // is a JSON array of bundle IDs in one TEXT column.
        exec("""
        CREATE TABLE IF NOT EXISTS styles (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            prompt TEXT NOT NULL,
            activationApps TEXT NOT NULL DEFAULT '[]',
            isBuiltIn INTEGER NOT NULL DEFAULT 0,
            position INTEGER NOT NULL
        );
        """, bind: nil)
        exec("CREATE INDEX IF NOT EXISTS idx_styles_position ON styles(position ASC);", bind: nil)

        // Notes/tasks/stickies live in their own table (position-ordered),
        // created idempotently here like dictionary_entries and styles; the v7
        // `migrateSchema` step only records the version bump. Dates are epoch
        // REALs; every column beyond the PK is optional or defaulted (CloudKit-
        // migration friendly — see ROADMAP Phase B).
        exec("""
        CREATE TABLE IF NOT EXISTS notes (
            id TEXT PRIMARY KEY,
            createdAt REAL NOT NULL,
            modifiedAt REAL NOT NULL,
            text TEXT NOT NULL,
            isTask INTEGER NOT NULL DEFAULT 0,
            done INTEGER NOT NULL DEFAULT 0,
            completedAt REAL,
            dueAt REAL,
            reminderFiredAt REAL,
            richText BLOB,
            pinned INTEGER NOT NULL DEFAULT 0,
            pinX REAL,
            pinY REAL,
            pinW REAL,
            pinH REAL,
            sourceTranscriptID TEXT,
            sourceActionItem TEXT,
            position INTEGER NOT NULL
        );
        """, bind: nil)
        exec("CREATE INDEX IF NOT EXISTS idx_notes_position ON notes(position ASC);", bind: nil)
    }

    /// Additive schema migrations, versioned via `PRAGMA user_version`. Runs on
    /// every launch but is a no-op once the DB is up to date. A fresh DB starts
    /// at version 0, so it takes the same `ALTER TABLE` path as an upgrade —
    /// one code path, no CREATE/ALTER divergence.
    ///
    /// Each column is added only if it's missing (checked via `PRAGMA
    /// table_info`), and `user_version` is bumped **only once every required
    /// column is present**. So a migration interrupted partway (e.g. an `ALTER`
    /// failing on a full disk) leaves the version unbumped and *heals* on the
    /// next launch instead of either deadlocking on "duplicate column name" or
    /// marking a half-migrated DB done — which would break every later
    /// insert/reload with "no such column".
    ///
    /// v1: summary columns (summary, actionItems JSON, summaryGeneratedAt).
    /// v2: notes column.
    /// v3: dictionary_entries table (created in `createSchema`; this step only
    ///     records the version bump — the data import is a separate one-shot
    ///     UserDefaults flag, see `migrateLegacyDictionaryIfNeeded`).
    /// v4: styles table (created in `createSchema`; bump-only, like v3; presets
    ///     are seeded via a separate one-shot flag, see `seedBuiltInStylesIfNeeded`).
    ///
    /// Each version is an independent, self-committing step: it adds only its
    /// missing columns, then bumps `user_version` **only once they're all
    /// present** — a step interrupted partway (e.g. an `ALTER` failing on a full
    /// disk) leaves the version unbumped and `return`s, so the whole sequence
    /// retries and heals on the next launch instead of half-migrating.
    private func migrateSchema() {
        guard db != nil else { return }
        var version: Int32 = 0
        forEachRow("PRAGMA user_version;") { stmt in version = sqlite3_column_int(stmt, 0) }

        if version < 1 {
            guard addColumns([("summary", "TEXT"), ("actionItems", "TEXT"), ("summaryGeneratedAt", "REAL")]) else {
                log.error("Schema v1 migration incomplete; leaving user_version at \(version) to retry next launch.")
                return
            }
            exec("PRAGMA user_version = 1;", bind: nil)
            log.notice("Migrated schema to v1 (summary columns).")
            version = 1
        }

        if version < 2 {
            guard addColumns([("notes", "TEXT")]) else {
                log.error("Schema v2 migration incomplete; leaving user_version at \(version) to retry next launch.")
                return
            }
            exec("PRAGMA user_version = 2;", bind: nil)
            log.notice("Migrated schema to v2 (notes column).")
            version = 2
        }

        if version < 3 {
            // No DDL: `dictionary_entries` is created idempotently in
            // `createSchema`. This step only records the version so the
            // migration sequence stays monotonic for future changes.
            exec("PRAGMA user_version = 3;", bind: nil)
            log.notice("Migrated schema to v3 (dictionary_entries table).")
            version = 3
        }

        if version < 4 {
            // No DDL: `styles` is created idempotently in `createSchema`. Like
            // v3, this step only records the version bump.
            exec("PRAGMA user_version = 4;", bind: nil)
            log.notice("Migrated schema to v4 (styles table).")
            version = 4
        }

        if version < 5 {
            guard addColumns([("styleName", "TEXT")]) else {
                log.error("Schema v5 migration incomplete; leaving user_version at \(version) to retry next launch.")
                return
            }
            exec("PRAGMA user_version = 5;", bind: nil)
            log.notice("Migrated schema to v5 (styleName column).")
            version = 5
        }

        if version < 6 {
            guard addColumns([("styleID", "TEXT")]) else {
                log.error("Schema v6 migration incomplete; leaving user_version at \(version) to retry next launch.")
                return
            }
            exec("PRAGMA user_version = 6;", bind: nil)
            log.notice("Migrated schema to v6 (styleID column).")
            version = 6
        }

        if version < 7 {
            // No DDL: `notes` is created idempotently in `createSchema`. Like
            // v3/v4, this step only records the version bump.
            exec("PRAGMA user_version = 7;", bind: nil)
            log.notice("Migrated schema to v7 (notes table).")
            version = 7
        }

        if version < 8 {
            // Sticky size columns. A fresh DB already has them from
            // `createSchema`; a v7 DB (the notes table's first cut) gets them
            // ALTERed in here.
            guard addColumns([("pinW", "REAL"), ("pinH", "REAL")], to: "notes") else {
                log.error("Schema v8 migration incomplete; leaving user_version at \(version) to retry next launch.")
                return
            }
            exec("PRAGMA user_version = 8;", bind: nil)
            log.notice("Migrated schema to v8 (sticky size columns).")
            version = 8
        }

        if version < 9 {
            // Rich-text blob for notes (bold/italic/underline + link runs).
            guard addColumns([("richText", "BLOB")], to: "notes") else {
                log.error("Schema v9 migration incomplete; leaving user_version at \(version) to retry next launch.")
                return
            }
            exec("PRAGMA user_version = 9;", bind: nil)
            log.notice("Migrated schema to v9 (note rich text).")
            version = 9
        }
    }

    /// Add each column to `table` only if it's missing (idempotent, so a
    /// retried migration doesn't fail on "duplicate column name"). Returns true
    /// only when every requested column is present afterward. Names/types are
    /// code literals, not user input — safe to inline.
    private func addColumns(_ columns: [(name: String, type: String)], to table: String = "transcripts") -> Bool {
        let existing = existingColumns(of: table)
        var allAdded = true
        for column in columns where !existing.contains(column.name) {
            if !exec("ALTER TABLE \(table) ADD COLUMN \(column.name) \(column.type);", bind: nil) {
                allAdded = false
            }
        }
        return allAdded
    }

    /// Column names currently present on a table, via `PRAGMA table_info` (name
    /// is column index 1). Used to make `ALTER TABLE ADD COLUMN` idempotent.
    private func existingColumns(of table: String) -> Set<String> {
        var names: Set<String> = []
        forEachRow("PRAGMA table_info(\(table));") { stmt in
            if let name = Self.columnText(stmt, 1) { names.insert(name) }
        }
        return names
    }

    // NOTE: `INSERT OR REPLACE` writes all 13 columns, so calling this with an
    // already-stored `id` would overwrite its summary AND notes columns with the
    // passed Transcript's values (nil/empty for a freshly built one). Safe today
    // — every `add()` path mints a new UUID, and summary/notes are written via
    // `updateSummary` / `updateNotes` (UPDATE, not insert). A future "edit/re-save"
    // path must NOT round-trip an existing row through `add()`/`insert()` or it
    // will wipe both; add a dedicated update instead.
    @discardableResult
    private func insert(_ t: Transcript) -> Bool {
        exec("""
        INSERT OR REPLACE INTO transcripts
        (id, createdAt, source, title, text, rawText, fileName, sourcePath, durationSec, summary, actionItems, summaryGeneratedAt, notes, styleName, styleID)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """) { stmt in
            sqlite3_bind_text(stmt, 1, t.id.uuidString, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, t.createdAt.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, t.source.rawValue, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, t.title, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 5, t.text, -1, Self.SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 6, t.rawText, -1, Self.SQLITE_TRANSIENT)
            self.bindOptionalText(stmt, 7, t.fileName)
            self.bindOptionalText(stmt, 8, t.sourcePath)
            if let d = t.durationSec { sqlite3_bind_double(stmt, 9, d) } else { sqlite3_bind_null(stmt, 9) }
            self.bindOptionalText(stmt, 10, t.summary)
            self.bindOptionalText(stmt, 11, Self.encodeActionItems(t.actionItems))
            if let g = t.summaryGeneratedAt { sqlite3_bind_double(stmt, 12, g.timeIntervalSince1970) } else { sqlite3_bind_null(stmt, 12) }
            self.bindOptionalText(stmt, 13, t.notes.isEmpty ? nil : t.notes)
            self.bindOptionalText(stmt, 14, t.styleName)
            self.bindOptionalText(stmt, 15, t.styleID)
        }
    }

    private func reload() {
        var rows: [Transcript] = []
        forEachRow("""
        SELECT id, createdAt, source, title, text, rawText, fileName, sourcePath, durationSec, summary, actionItems, summaryGeneratedAt, notes, styleName, styleID
        FROM transcripts ORDER BY createdAt DESC;
        """) { stmt in
            guard let idStr = Self.columnText(stmt, 0), let id = UUID(uuidString: idStr) else { return }
            let source = TranscriptSource(rawValue: Self.columnText(stmt, 2) ?? "") ?? .dictation
            let duration: Double? = sqlite3_column_type(stmt, 8) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 8)
            let generatedAt: Date? = sqlite3_column_type(stmt, 11) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11))
            rows.append(Transcript(
                id: id,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                source: source,
                title: Self.columnText(stmt, 3) ?? "",
                text: Self.columnText(stmt, 4) ?? "",
                rawText: Self.columnText(stmt, 5) ?? "",
                fileName: Self.columnText(stmt, 6),
                sourcePath: Self.columnText(stmt, 7),
                durationSec: duration,
                summary: Self.columnText(stmt, 9),
                actionItems: Self.decodeActionItems(Self.columnText(stmt, 10)),
                summaryGeneratedAt: generatedAt,
                notes: Self.columnText(stmt, 12) ?? "",
                styleName: Self.columnText(stmt, 13),
                styleID: Self.columnText(stmt, 14)
            ))
        }
        transcripts = rows
    }

    /// Hydrate `dictionaryEntries` from the `dictionary_entries` table in apply
    /// order. `position` drives the ORDER BY; the array index is the effective
    /// position afterward (see the CRUD note), so it isn't read into the struct.
    private func reloadDictionary() {
        var rows: [DictionaryEntry] = []
        forEachRow("""
        SELECT id, phrase, replacement, caseSensitive
        FROM dictionary_entries ORDER BY position ASC;
        """) { stmt in
            guard let idStr = Self.columnText(stmt, 0), let id = UUID(uuidString: idStr) else { return }
            rows.append(DictionaryEntry(
                id: id,
                phrase: Self.columnText(stmt, 1) ?? "",
                replacement: Self.columnText(stmt, 2) ?? "",
                caseSensitive: sqlite3_column_int(stmt, 3) != 0
            ))
        }
        dictionaryEntries = rows
    }

    /// Hydrate `notes` from the `notes` table in position order. (Named
    /// `reloadNotesTable` to avoid colliding with the transcript-notes column
    /// vocabulary — `updateNotes(id:notes:)` writes a transcript's free-text
    /// notes, an unrelated concept.)
    private func reloadNotesTable() {
        var rows: [Note] = []
        forEachRow("""
        SELECT id, createdAt, modifiedAt, text, richText,
               pinned, pinX, pinY, pinW, pinH, sourceTranscriptID, sourceActionItem
        FROM notes ORDER BY position ASC;
        """) { stmt in
            guard let idStr = Self.columnText(stmt, 0), let id = UUID(uuidString: idStr) else { return }
            var note = Note(
                id: id,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                text: Self.columnText(stmt, 3) ?? ""
            )
            note.richText = Self.columnBlob(stmt, 4)
            note.pinned = sqlite3_column_int(stmt, 5) != 0
            note.pinX = Self.columnDouble(stmt, 6)
            note.pinY = Self.columnDouble(stmt, 7)
            note.pinW = Self.columnDouble(stmt, 8)
            note.pinH = Self.columnDouble(stmt, 9)
            note.sourceTranscriptID = Self.columnText(stmt, 10).flatMap(UUID.init(uuidString:))
            note.sourceActionItem = Self.columnText(stmt, 11)
            rows.append(note)
        }
        notes = rows
    }

    /// Hydrate `styles` from the `styles` table in display order.
    private func reloadStyles() {
        var rows: [Style] = []
        forEachRow("""
        SELECT id, name, prompt, activationApps, isBuiltIn
        FROM styles ORDER BY position ASC;
        """) { stmt in
            guard let idStr = Self.columnText(stmt, 0), let id = UUID(uuidString: idStr) else { return }
            rows.append(Style(
                id: id,
                name: Self.columnText(stmt, 1) ?? "",
                prompt: Self.columnText(stmt, 2) ?? "",
                activationApps: Self.decodeApps(Self.columnText(stmt, 3)),
                isBuiltIn: sqlite3_column_int(stmt, 4) != 0
            ))
        }
        styles = rows
    }

    // MARK: - Low-level helpers

    /// Prepare, bind, step-to-done, finalize. Returns true on SQLITE_DONE.
    @discardableResult
    private func exec(_ sql: String, bind: ((OpaquePointer?) -> Void)?) -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log.error("prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        defer { sqlite3_finalize(stmt) }
        bind?(stmt)
        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE {
            log.error("step failed (rc \(rc)): \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        return true
    }

    private func forEachRow(_ sql: String, _ handle: (OpaquePointer?) -> Void) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log.error("prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW { handle(stmt) }
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value { sqlite3_bind_text(stmt, index, value, -1, Self.SQLITE_TRANSIENT) }
        else { sqlite3_bind_null(stmt, index) }
    }

    private func bindOptionalDouble(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value { sqlite3_bind_double(stmt, index, value) }
        else { sqlite3_bind_null(stmt, index) }
    }

    private func bindOptionalBlob(_ stmt: OpaquePointer?, _ index: Int32, _ value: Data?) {
        if let value, !value.isEmpty {
            _ = value.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, index, raw.baseAddress, Int32(value.count), Self.SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private static func columnBlob(_ stmt: OpaquePointer?, _ index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        guard count > 0 else { return nil }
        return Data(bytes: bytes, count: count)
    }

    private static func columnDouble(_ stmt: OpaquePointer?, _ index: Int32) -> Double? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, index)
    }

    private static func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    /// Action items are stored as a JSON array of strings in one TEXT column.
    /// An empty list encodes to `nil` (stored as SQL NULL) so "no summary yet"
    /// and "summary with no action items" stay distinguishable via `summary`.
    private static func encodeActionItems(_ items: [String]) -> String? {
        guard !items.isEmpty, let data = try? JSONEncoder().encode(items) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeActionItems(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let items = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return items
    }

    /// A style's activation bundle IDs are stored as a JSON array in one TEXT
    /// column. Empty encodes to `"[]"` (the column's NOT NULL default), so an
    /// empty list and a missing value both decode to `[]`.
    private static func encodeApps(_ apps: [String]) -> String {
        guard let data = try? JSONEncoder().encode(apps),
              let s = String(data: data, encoding: .utf8) else { return "[]" }
        return s
    }

    private static func decodeApps(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let apps = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return apps
    }
}
