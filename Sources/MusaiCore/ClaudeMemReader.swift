import Foundation
import SQLite3

/// Reads an existing claude-mem corpus **read-only** and hands back source-neutral rows.
///
/// claude-mem is a *source*, not a host, so `MusaiCore` is allowed to know its SQL — and this is the one
/// file that does. The corpus is opened `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX` on every call: it is a
/// WAL database with a live writer behind it, so a reader must never take a write lock, and an import must
/// be unable to damage what it replaces. One connection per batch is nothing at this scale, and opening
/// inside each method is what keeps this type honestly `Sendable` instead of needing `@unchecked`.
///
/// The reader is deliberately dumb about emptiness: it returns every row it reads, and a row whose composed
/// text is empty comes back with empty text for the caller to skip and count.
public struct ClaudeMemReader: Sendable {
    private let url: URL

    public init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ClaudeMemReaderError.corpusMissing(url)
        }
        self.url = url
    }

    /// Sessions, oldest id first, after a high-water mark. `after` is the last id already read.
    public func sessions(limit: Int, after: Int) throws -> [SourceSession] {
        try run("""
        SELECT id, memory_session_id, content_session_id, platform_source, cwd, custom_title,
               status, started_at_epoch, completed_at_epoch, project
        FROM sdk_sessions
        WHERE id > ?1
        ORDER BY id ASC
        LIMIT ?2
        """, limit: limit, after: after) { row in
            let memorySessionId = row.text(1) ?? ""
            return SourceSession(
                id: row.int(0),
                // claude-mem leaves `memory_session_id` null on many sessions, and those are still
                // importable; the host's id is the only identity such a row has.
                memorySessionId: memorySessionId.isEmpty ? row.requiredText(2) : memorySessionId,
                hostSessionId: row.requiredText(2),
                platform: row.requiredText(3),
                cwd: row.text(4),
                title: row.text(5),
                status: SessionStatus(rawValue: row.requiredText(6).uppercased()),
                startedAt: Date(timeIntervalSince1970: TimeInterval(row.int(7))),
                endedAt: row.optionalInt(8).map { Date(timeIntervalSince1970: TimeInterval($0)) },
                projectLabel: row.requiredText(9))
        }
    }

    /// Observations, oldest id first, after a high-water mark.
    public func evidence(limit: Int, after: Int) throws -> [SourceEvidence] {
        try run("""
        SELECT o.id, o.type, o.text, o.title, o.facts, o.narrative, o.concepts,
               COALESCE(s.content_session_id, o.memory_session_id)
        FROM observations o
        LEFT JOIN sdk_sessions s ON s.memory_session_id = o.memory_session_id
        WHERE o.id > ?1
        ORDER BY o.id ASC
        LIMIT ?2
        """, limit: limit, after: after) { row in
            let id = row.int(0)
            let type = row.requiredText(1)
            return SourceEvidence(
                id: id,
                kind: Self.kind(forType: type),
                text: MusaiCapture.truncated(
                    Self.composed(
                        text: row.text(2), title: row.text(3), facts: row.text(4),
                        narrative: row.text(5)),
                    to: MusaiCapture.maxTextBytes),
                narrative: row.text(5),
                concepts: ["type:\(type)"] + Self.strings(from: row.text(6)),
                provenance: "claude-mem:observation:\(id)",
                hostSessionId: row.requiredText(7))
        }
    }

    /// The person's prompts, oldest id first, after a high-water mark.
    public func prompts(limit: Int, after: Int) throws -> [SourcePrompt] {
        try run("""
        SELECT id, content_session_id, prompt_text, created_at_epoch
        FROM user_prompts
        WHERE id > ?1
        ORDER BY id ASC
        LIMIT ?2
        """, limit: limit, after: after) { row in
            SourcePrompt(
                id: row.int(0),
                hostSessionId: row.requiredText(1),
                text: row.requiredText(2),
                at: Date(timeIntervalSince1970: TimeInterval(row.int(3))))
        }
    }

    /// Every work-state list. These are small and carry no cursor.
    public func workState() throws -> [SourceWorkState] {
        try run("""
        SELECT id, project, list_name, fields
        FROM work_state_entries
        ORDER BY id ASC
        """) { row in
            SourceWorkState(
                id: row.int(0), projectLabel: row.requiredText(1), listName: row.requiredText(2),
                fields: row.requiredText(3))
        }
    }

    // MARK: - The corpus's `type` values

    /// Every `type` claude-mem was measured to write. The raw type is kept as a `type:<raw>` concept, so a
    /// kind this table gets wrong is recoverable; `FACT` is the default for a type not seen before.
    static let kindsByType: [String: MemoryKind] = [
        "decision": .decision,
        "discovery": .lesson,
        "change": .fact,
        "feature": .fact,
        "bugfix": .fact,
        "refactor": .fact,
        "security_alert": .fact,
        "security_note": .fact,
        "gotcha": .lesson,
        "fix": .fact,
        "summary": .fact,
        "pattern": .lesson,
        "sensitive": .fact,
        "baseline-investigation": .lesson,
        "critical": .fact,
        "important": .fact,
        "correctness": .lesson,
        "problem-solution": .lesson,
        "task-assignment": .todo,
        "task-coordination": .todo,
    ]

    static func kind(forType type: String) -> MemoryKind { kindsByType[type] ?? .fact }

    // MARK: - Composing the prose

    /// `text` is null in every real row, so the readable text is the column when a corpus does fill it, the
    /// title plus each fact on its own `- ` line otherwise, and the narrative when there is no title and no
    /// fact. A row with none of the three composes to empty, which the caller skips and counts.
    static func composed(text: String?, title: String?, facts: String?, narrative: String?) -> String {
        if let text = cleaned(text) { return text }
        var lines: [String] = []
        if let title = cleaned(title) { lines.append(title) }
        for fact in strings(from: facts) {
            if let fact = cleaned(fact) { lines.append("- \(fact)") }
        }
        return lines.isEmpty ? (narrative ?? "") : lines.joined(separator: "\n")
    }

    /// A JSON array of strings, or nothing. claude-mem stores `facts` and `concepts` as JSON text, and a
    /// value that will not decode is not a reason to fail the read — compose what can be composed.
    static func strings(from json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return values
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - The one place a statement runs

    /// Runs one statement on a fresh read-only connection. Internal rather than private so the read-only
    /// test can try a write through the reader's own connection; every query above goes through here too.
    /// `after` binds to `?1` and `limit` to `?2`, so the SQL stays numbered and a statement with no
    /// parameters simply takes none.
    @discardableResult
    func run<T>(
        _ sql: String, limit: Int? = nil, after: Int? = nil, decode: (Row) throws -> T
    ) throws -> [T] {
        try withConnection { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw ClaudeMemReaderError.queryFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(statement) }
            if let after { sqlite3_bind_int64(statement, 1, Int64(after)) }
            if let limit { sqlite3_bind_int64(statement, 2, Int64(limit)) }
            var rows: [T] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_ROW {
                    rows.append(try decode(Row(statement)))
                } else if step == SQLITE_DONE {
                    break
                } else {
                    throw ClaudeMemReaderError.queryFailed(String(cString: sqlite3_errmsg(db)))
                }
            }
            return rows
        }
    }

    private func withConnection<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(
            url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) }
                ?? "sqlite3_open_v2 failed with code \(status)"
            if let handle { sqlite3_close(handle) }
            throw ClaudeMemReaderError.openFailed(message)
        }
        defer { sqlite3_close(handle) }
        return try body(handle)
    }
}

/// A prepared statement's current row. Columns are read by position; a column the corpus left null reads as
/// `nil` for the optional accessors and as empty for the required ones.
struct Row {
    private let statement: OpaquePointer

    init(_ statement: OpaquePointer) { self.statement = statement }

    func int(_ index: Int32) -> Int { Int(sqlite3_column_int64(statement, index)) }

    func optionalInt(_ index: Int32) -> Int? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : int(index)
    }

    func text(_ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    func requiredText(_ index: Int32) -> String { text(index) ?? "" }
}

/// The reader's failures. Nothing here is a data problem — an unreadable corpus is the only thing that
/// stops a read, and a value that will not decode inside a row never does.
public enum ClaudeMemReaderError: Error, Equatable {
    case corpusMissing(URL)
    case openFailed(String)
    case queryFailed(String)
}
