import Foundation
import SQLite3

/// A throwaway claude-mem corpus: the columns the reader reads, and an insert per row so a test can say what
/// its corpus holds. Removed when the test's scope ends.
///
/// Nothing here ever opens `~/.claude-mem/claude-mem.db`: every corpus is a temp file a test makes and removes.
/// This one is deliberately the *smallest* corpus the surfaces need, so the richer fixtures the import's own
/// suites build stay theirs; it exists so the route tests and the client tests share one definition rather
/// than a third copy of the same CREATE TABLE block. Promoting those fixtures onto it is a separate change.
///
/// A class, not a struct, so that the corpus is closed and removed exactly when the test lets go of it.
final class ClaudeMemCorpus {
    enum Failure: Error, Equatable { case open(String), exec(String) }

    let url: URL
    private var db: OpaquePointer?

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-surfaces-\(UUID().uuidString).db")
        var handle: OpaquePointer?
        guard
            sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
            let handle
        else {
            throw Failure.open("could not create \(url.path)")
        }
        db = handle
        // The five tables the reader reads, and no more: a reader meets a table it reads by name, so a missing
        // one is an error rather than an empty result, and the import runs every stage.
        try exec("""
        CREATE TABLE sdk_sessions(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            memory_session_id TEXT UNIQUE,
            content_session_id TEXT NOT NULL,
            platform_source TEXT NOT NULL,
            project TEXT NOT NULL,
            custom_title TEXT,
            started_at_epoch INTEGER NOT NULL,
            completed_at_epoch INTEGER,
            status TEXT NOT NULL,
            cwd TEXT);
        CREATE TABLE observations(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            memory_session_id TEXT NOT NULL,
            project TEXT NOT NULL,
            text TEXT,
            type TEXT NOT NULL,
            title TEXT,
            facts TEXT,
            narrative TEXT,
            concepts TEXT,
            created_at_epoch INTEGER NOT NULL);
        CREATE TABLE user_prompts(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_db_id INTEGER,
            content_session_id TEXT NOT NULL,
            prompt_number INTEGER NOT NULL,
            prompt_text TEXT NOT NULL,
            created_at_epoch INTEGER NOT NULL);
        CREATE TABLE session_summaries(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            memory_session_id TEXT NOT NULL,
            project TEXT NOT NULL,
            request TEXT,
            investigated TEXT,
            learned TEXT,
            completed TEXT,
            next_steps TEXT,
            created_at_epoch INTEGER NOT NULL);
        CREATE TABLE work_state_entries(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            project TEXT NOT NULL,
            list_name TEXT NOT NULL,
            fields TEXT NOT NULL,
            created_at_epoch INTEGER NOT NULL);
        """)
    }

    deinit {
        if let db { sqlite3_close(db) }
        try? FileManager.default.removeItem(at: url)
    }

    /// The corpus the import's surface tests read: one project-less session — no `cwd`, so every row it holds
    /// lands unbound, which is the shape most of the real corpus has — two observations of *different* kinds
    /// (one of them the `decision`-typed row that becomes a migrated proposal), a real prompt and one machine
    /// payload. The label is a filing bucket, so discovery names neither a project nor an idea, which keeps
    /// the expected report small and exact.
    static func thread() throws -> ClaudeMemCorpus {
        // A strong local, not a temporary: the chain must not outlive the reference that keeps the corpus
        // open, and `deinit` is what closes it.
        let corpus = try ClaudeMemCorpus()
        try corpus
            .session(id: 1, memory: "cm-1", host: "host-1", label: "open-source", cwd: nil)
            .observation(id: 1, memory: "cm-1", type: "discovery", title: "Norvo keeps one file")
            .observation(id: 2, memory: "cm-1", type: "decision", narrative: "One file, not a server")
            .prompt(id: 1, host: "host-1", text: "please read the corpus", at: 1_700_000_100)
            .prompt(
                id: 2, host: "host-1",
                text: "<task-notification>\n{\"hook\":\"Stop\"}\n</task-notification>", at: 1_700_000_200)
        return corpus
    }

    @discardableResult
    func session(
        id: Int, memory: String?, host: String, label: String = "open-source", cwd: String? = nil,
        title: String? = nil, status: String = "completed", started: Int = 1_700_000_000, ended: Int? = nil
    ) throws -> ClaudeMemCorpus {
        try exec("""
        INSERT INTO sdk_sessions(
            id, memory_session_id, content_session_id, platform_source, project, custom_title,
            started_at_epoch, completed_at_epoch, status, cwd)
        VALUES (\(id), \(Self.literal(memory)), \(Self.literal(host)), 'claude', \(Self.literal(label)),
            \(Self.literal(title)), \(started), \(ended.map(String.init) ?? "NULL"), \(Self.literal(status)),
            \(Self.literal(cwd)));
        """)
        return self
    }

    @discardableResult
    func observation(
        id: Int, memory: String, type: String = "discovery", title: String? = nil, facts: String? = nil,
        narrative: String? = nil, concepts: String? = nil
    ) throws -> ClaudeMemCorpus {
        try exec("""
        INSERT INTO observations(
            id, memory_session_id, project, text, type, title, facts, narrative, concepts,
            created_at_epoch)
        VALUES (\(id), \(Self.literal(memory)), 'claude-mem', NULL, \(Self.literal(type)),
            \(Self.literal(title)), \(Self.literal(facts)), \(Self.literal(narrative)),
            \(Self.literal(concepts)), 1_700_000_000);
        """)
        return self
    }

    @discardableResult
    func prompt(id: Int, host: String, text: String, at: Int) throws -> ClaudeMemCorpus {
        try exec("""
        INSERT INTO user_prompts(
            id, session_db_id, content_session_id, prompt_number, prompt_text, created_at_epoch)
        VALUES (\(id), NULL, \(Self.literal(host)), \(id), \(Self.literal(text)), \(at));
        """)
        return self
    }

    /// A SQL literal, or `NULL` for a column the corpus left empty.
    private static func literal(_ text: String?) -> String {
        guard let text else { return "NULL" }
        return "'\(text.replacingOccurrences(of: "'", with: "''"))'"
    }

    private func exec(_ sql: String) throws {
        guard let db else { throw Failure.exec("the corpus is closed") }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "sqlite3_exec failed"
            sqlite3_free(error)
            throw Failure.exec(message)
        }
    }
}
