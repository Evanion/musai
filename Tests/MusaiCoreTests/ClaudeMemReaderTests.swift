import Foundation
import SQLite3
import Testing
@testable import MusaiCore

/// The reader stands between Musai and the person's claude-mem corpus. It opens that corpus **read-only**
/// — the import must be unable to damage what it replaces — and returns source-neutral rows, so nothing
/// downstream has to know claude-mem's columns.
///
/// Every test here builds its own tiny corpus. None of them ever opens `~/.claude-mem/claude-mem.db`: a
/// test that depended on the person's 1 GB database would not be a test.
@Suite struct ClaudeMemReaderTests {
    private enum CorpusError: Error { case open(String), exec(String) }

    /// A corpus with the columns the reader uses and rows that pin the mapping: an observation whose `text`
    /// is NULL but which has a title and facts, one with only a narrative, one with nothing at all, a session
    /// whose two ids differ, a prompt, a work-state list, and a summary table the reader does not read yet.
    private func makeCorpus() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-claude-mem-\(UUID().uuidString).db")
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db else {
            throw CorpusError.open("could not create \(url.path)")
        }
        defer { sqlite3_close(db) }
        try exec(db, """
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
        CREATE TABLE user_prompts(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_db_id INTEGER,
            content_session_id TEXT NOT NULL,
            prompt_number INTEGER NOT NULL,
            prompt_text TEXT NOT NULL,
            created_at_epoch INTEGER NOT NULL);
        """)
        try exec(db, """
        INSERT INTO sdk_sessions(
            id, memory_session_id, content_session_id, platform_source, project, custom_title,
            started_at_epoch, completed_at_epoch, status, cwd)
        VALUES (1, 'cm-1', 'host-1', 'claude', 'musai', 'A thread',
            1700000000, 1700000600, 'completed', '/Volumes/projects/Personal/Musai');
        INSERT INTO sdk_sessions(
            id, memory_session_id, content_session_id, platform_source, project, custom_title,
            started_at_epoch, completed_at_epoch, status, cwd)
        VALUES (2, NULL, 'host-2', 'claude', 'musai', NULL,
            1700000700, NULL, 'active', NULL);
        INSERT INTO observations(
            id, memory_session_id, project, text, type, title, facts, narrative, concepts, created_at_epoch)
        VALUES (1, 'cm-1', 'musai', NULL, 'discovery', 'A title', '["f1","f2"]',
            'A narrative nobody should see', '["what-changed","how-it-works"]', 1700000001);
        INSERT INTO observations(
            id, memory_session_id, project, text, type, title, facts, narrative, concepts, created_at_epoch)
        VALUES (2, 'cm-1', 'musai', NULL, 'decision', NULL, NULL,
            'Only narrative', NULL, 1700000002);
        INSERT INTO observations(
            id, memory_session_id, project, text, type, title, facts, narrative, concepts, created_at_epoch)
        VALUES (3, 'cm-1', 'musai', NULL, 'gotcha', NULL, NULL, NULL, '[]', 1700000003);
        INSERT INTO work_state_entries(id, project, list_name, fields, created_at_epoch)
        VALUES (1, 'musai', 'musai-backend', '{"status":"doing"}', 1700000004);
        INSERT INTO user_prompts(id, session_db_id, content_session_id, prompt_number, prompt_text, created_at_epoch)
        VALUES (1, 1, 'host-1', 1, 'please read the corpus', 1700000005);
        INSERT INTO session_summaries(id, memory_session_id, project, request, next_steps, created_at_epoch)
        VALUES (1, 'cm-1', 'musai', 'read the corpus', 'finish the reader', 1700000006);
        """)
        return url
    }

    private func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "sqlite3_exec failed"
            sqlite3_free(error)
            throw CorpusError.exec(message)
        }
    }

    private func remove(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func evidenceTextIsComposedBecauseTheColumnIsEmpty() async throws {
        let url = try makeCorpus()
        defer { remove(url) }
        let reader = try ClaudeMemReader(url: url)

        let rows = try reader.evidence(limit: 10, after: 0)

        #expect(rows.count == 3)
        // `text` is NULL in every real row, so the prose comes from the title and the facts.
        #expect(rows[0].text == "A title\n- f1\n- f2")
        #expect(rows[0].kind == .lesson)
        #expect(rows[0].provenance == "claude-mem:observation:1")
        #expect(rows[0].concepts == ["type:discovery", "what-changed", "how-it-works"])
        #expect(rows[0].hostSessionId == "host-1")
        // When the title and the facts are both absent, the narrative is all there is.
        #expect(rows[1].text == "Only narrative")
        #expect(rows[1].kind == .decision)
        #expect(rows[1].concepts == ["type:decision"])
        // And a row with none of the three comes back with empty text, for the caller to skip and count.
        #expect(rows[2].text == "")
        #expect(rows[2].kind == .lesson)
    }

    @Test func theHostSessionIdIsNotTheMemorySessionId() async throws {
        let url = try makeCorpus()
        defer { remove(url) }
        let reader = try ClaudeMemReader(url: url)

        let sessions = try reader.sessions(limit: 10, after: 0)

        #expect(sessions.count == 2)
        // This row has both ids, and they differ; Musai's live capture writes the host's.
        #expect(sessions[0].hostSessionId == "host-1")
        #expect(sessions[0].memorySessionId == "cm-1")
        #expect(sessions[0].platform == "claude")
        #expect(sessions[0].projectLabel == "musai")
        #expect(sessions[0].cwd == "/Volumes/projects/Personal/Musai")
        #expect(sessions[0].title == "A thread")
        #expect(sessions[0].status == .completed)
        #expect(sessions[0].startedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(sessions[0].endedAt == Date(timeIntervalSince1970: 1_700_000_600))
    }

    @Test func aSessionWithNoMemorySessionIdFallsBackToTheHostId() async throws {
        let url = try makeCorpus()
        defer { remove(url) }
        let reader = try ClaudeMemReader(url: url)

        let sessions = try reader.sessions(limit: 10, after: 0)

        let lonely = try #require(sessions.last)
        #expect(sessions.count == 2)
        // claude-mem left `memory_session_id` null, so the host's id is the row's only identity — and the
        // import still gets a non-empty Musai-side key rather than losing the session.
        #expect(lonely.hostSessionId == "host-2")
        #expect(lonely.memorySessionId == lonely.hostSessionId)
        #expect(lonely.title == nil)
        #expect(lonely.cwd == nil)
        #expect(lonely.status == .active)
        #expect(lonely.endedAt == nil)
    }

    @Test func theReaderOpensTheCorpusReadOnly() async throws {
        let url = try makeCorpus()
        defer { remove(url) }
        let reader = try ClaudeMemReader(url: url)

        // Every table the reader knows reads.
        #expect(try reader.evidence(limit: 10, after: 0).count == 3)
        #expect(try reader.prompts(limit: 10, after: 0).count == 1)
        #expect(try reader.workState().count == 1)

        // A write through the reader's own connection is refused even though the file is writable — which is
        // the only way to prove the read-only flag is doing the work rather than the file's permissions.
        #expect(throws: ClaudeMemReaderError.self) {
            try reader.run("""
            INSERT INTO observations(memory_session_id, project, type, created_at_epoch)
            VALUES ('cm-1', 'musai', 'fact', 0)
            """) { _ in 0 }
        }

        // A corpus on read-only media — a copy with no write bit — is still readable.
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
        #expect(try reader.prompts(limit: 10, after: 0).count == 1)
    }
}
