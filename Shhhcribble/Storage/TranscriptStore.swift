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

    /// Menu / list title, truncated for one-line display.
    var menuTitle: String {
        let base = title.isEmpty ? text : title
        let prefix = String(base.prefix(60))
        return base.count > 60 ? "\(prefix)…" : prefix
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
    }

    /// Production store at Application Support/Shhhcribble/transcripts.sqlite,
    /// migrating any legacy UserDefaults history on first run.
    static func makeDefault() -> TranscriptStore {
        let store = TranscriptStore(path: defaultDatabaseURL().path)
        store.migrateLegacyHistoryIfNeeded()
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
    func addDictation(text: String, rawText: String, date: Date = Date()) -> Transcript {
        let t = Transcript(
            id: UUID(), createdAt: date, source: .dictation,
            title: Self.title(from: text), text: text, rawText: rawText,
            fileName: nil, sourcePath: nil, durationSec: nil
        )
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

    /// Case-insensitive substring match over title + text, newest first.
    /// Empty query returns everything (already newest-first in `transcripts`).
    func matching(_ query: String) -> [Transcript] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return transcripts }
        let needle = q.lowercased()
        return transcripts.filter {
            $0.title.lowercased().contains(needle) || $0.text.lowercased().contains(needle)
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
    private func migrateSchema() {
        guard db != nil else { return }
        var version: Int32 = 0
        forEachRow("PRAGMA user_version;") { stmt in version = sqlite3_column_int(stmt, 0) }
        guard version < 1 else { return }

        let existing = existingColumns(of: "transcripts")
        let additions: [(name: String, type: String)] = [
            ("summary", "TEXT"),
            ("actionItems", "TEXT"),
            ("summaryGeneratedAt", "REAL"),
        ]
        // Column names/types are code literals, not user input — safe to inline.
        var allAdded = true
        for column in additions where !existing.contains(column.name) {
            if !exec("ALTER TABLE transcripts ADD COLUMN \(column.name) \(column.type);", bind: nil) {
                allAdded = false
            }
        }
        guard allAdded else {
            log.error("Schema v1 migration incomplete; leaving user_version at \(version) to retry next launch.")
            return
        }
        exec("PRAGMA user_version = 1;", bind: nil)
        log.notice("Migrated schema to v1 (summary columns).")
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

    // NOTE: `INSERT OR REPLACE` writes all 12 columns, so calling this with an
    // already-stored `id` would overwrite its summary columns with the passed
    // Transcript's values (nil/empty for a freshly built one). Safe today —
    // every `add()` path mints a new UUID and summaries are written via
    // `updateSummary` (UPDATE, not insert). A future "edit/re-save" path must
    // NOT round-trip an existing row through `add()`/`insert()` or it will wipe
    // the summary; add a dedicated update instead.
    @discardableResult
    private func insert(_ t: Transcript) -> Bool {
        exec("""
        INSERT OR REPLACE INTO transcripts
        (id, createdAt, source, title, text, rawText, fileName, sourcePath, durationSec, summary, actionItems, summaryGeneratedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
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
        }
    }

    private func reload() {
        var rows: [Transcript] = []
        forEachRow("""
        SELECT id, createdAt, source, title, text, rawText, fileName, sourcePath, durationSec, summary, actionItems, summaryGeneratedAt
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
                summaryGeneratedAt: generatedAt
            ))
        }
        transcripts = rows
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
}
