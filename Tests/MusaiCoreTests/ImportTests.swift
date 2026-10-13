import Foundation
import SQLite3
import Testing
@testable import MusaiCore

/// The import driver, end to end: a corpus the test builds, and the store an in-memory `MusaiLibrary` gives
/// it. What these tests pin is the whole contract — the history written, the drop rule for machine prompts,
/// project-less history written rather than skipped, one session for a conversation both tools saw, a run
/// that resumes at its cursor, and a dry run that reports everything and writes nothing.
///
/// Nothing here ever opens `~/.claude-mem/claude-mem.db`: every corpus is a temp file this suite makes and
/// removes. The store is always in memory.
@Suite struct ImportTests {
    /// A throwaway claude-mem corpus: the columns the reader reads, and an insert per row so a test can say
    /// what its corpus holds. Removed when the test's scope ends.
    private final class Corpus {
        enum Failure: Error, Equatable { case open(String), exec(String) }

        let url: URL
        private var db: OpaquePointer?

        init() throws {
            url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "musai-import-\(UUID().uuidString).db")
            var handle: OpaquePointer?
            guard
                sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
                let handle
            else {
                throw Failure.open("could not create \(url.path)")
            }
            db = handle
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

        @discardableResult
        func session(
            id: Int, memory: String?, host: String, label: String = "open-source", cwd: String? = nil,
            title: String? = nil, status: String = "completed", started: Int = 1_700_000_000, ended: Int? = nil
        ) throws -> Corpus {
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
        ) throws -> Corpus {
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
        func prompt(id: Int, host: String, text: String, at: Int) throws -> Corpus {
            try exec("""
            INSERT INTO user_prompts(
                id, session_db_id, content_session_id, prompt_number, prompt_text, created_at_epoch)
            VALUES (\(id), NULL, \(Self.literal(host)), \(id), \(Self.literal(text)), \(at));
            """)
            return self
        }

        @discardableResult
        func workState(id: Int, project: String, list: String, fields: String) throws -> Corpus {
            try exec("""
            INSERT INTO work_state_entries(id, project, list_name, fields, created_at_epoch)
            VALUES (\(id), \(Self.literal(project)), \(Self.literal(list)), \(Self.literal(fields)),
                1_700_000_000);
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

    /// A throwaway directory that is a working tree as far as `ProjectBinder` is concerned: a `.git/config`
    /// carrying an `origin`. Temp only — no repository of the person's is read.
    private func makeWorkingTree() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-import-tree-\(UUID().uuidString)")
        let git = root.appending(path: ".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "[remote \"origin\"]\n\turl = git@github.com:evanion/musai-fixture.git\n".write(
            to: git.appending(path: "config"), atomically: true, encoding: .utf8)
        return root
    }

    /// The corpus three of these tests import: one project-bound session, two observations of *different*
    /// kinds — so a duplicate is visible in a kind's own list, which is the only way to count memories
    /// without a whole-table query — three real prompts, and two *revisions* of one work-state list, because
    /// the real corpus's 18 entries are 18 revisions and only the newest belongs in the graph.
    private func historyCorpus(root: URL) throws -> Corpus {
        let corpus = try Corpus()
        try corpus
            .session(
                id: 1, memory: "cm-1", host: "host-1", label: root.lastPathComponent, cwd: root.path,
                title: "A thread", status: "completed", started: 1_700_000_000, ended: 1_700_000_600)
            .observation(
                id: 1, memory: "cm-1", type: "discovery", title: "A title", facts: "[\"f1\",\"f2\"]",
                concepts: "[\"what-changed\"]")
            .observation(id: 2, memory: "cm-1", type: "decision", narrative: "Only narrative")
            .prompt(id: 1, host: "host-1", text: "please read the corpus", at: 1_700_000_100)
            .prompt(id: 2, host: "host-1", text: "and then write the graph", at: 1_700_000_200)
            .prompt(id: 3, host: "host-1", text: "yes", at: 1_700_000_300)
            .workState(
                id: 1, project: root.lastPathComponent, list: "musai-backend",
                fields: "{\"status\":\"doing\"}")
            .workState(
                id: 2, project: root.lastPathComponent, list: "musai-backend",
                fields: "{\"status\":\"doing\",\"task\":\"the import\"}")
        return corpus
    }

    /// The driver under test: a temp corpus, an in-memory store, writing as the migrator.
    private func makeImport(_ lib: MusaiLibrary, _ corpus: Corpus, batch: Int = 500) throws -> MusaiImport {
        MusaiImport(
            db: lib.db,
            reader: try ClaudeMemReader(url: corpus.url),
            discovery: ImportDiscovery(db: lib.db),
            batch: batch,
            as: MusaiActors.migrator("claude-mem"))
    }

    @Test func theImportWritesTheHistoryItReads() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let root = try makeWorkingTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let slug = ProjectBinder.slugBase(root.lastPathComponent)
        let corpus = try historyCorpus(root: root)

        let report = try await makeImport(lib, corpus).run()

        #expect(report.dryRun == false)
        #expect(report.sessions == 1)
        #expect(report.evidence == 2)
        #expect(report.prompts == 3)
        #expect(report.workStates == 1)
        #expect(report.proposals == 0)
        #expect(report.projects == [slug])
        #expect(report.ideas.isEmpty)
        #expect(report.buckets.isEmpty)
        #expect(report.unbound == 0)
        #expect(report.machinePrompts == 0)
        #expect(report.skipped == 0)

        // The session, keyed on the host's id — never claude-mem's own.
        let session = try await lib.db.query(SessionByMemoryIdQuery(.init(memorySessionId: "host-1"))).session
        #expect(session != nil)
        #expect(session?.project?.slug == slug)
        #expect(session?.title == "A thread")
        #expect(session?.status == .completed)
        #expect(session?.startedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(session?.endedAt == Date(timeIntervalSince1970: 1_700_000_600))
        #expect(try await lib.db.query(SessionByMemoryIdQuery(.init(memorySessionId: "cm-1"))).session == nil)

        // Both observations, as migrated evidence, with their composed prose and their provenance.
        let first = try await lib.db.query(
            MemoryByProvenanceQuery(.init(provenance: "claude-mem:observation:1"))).memories.first
        #expect(first?.kind == .lesson)
        #expect(first?.origin == .migrated)
        #expect(first?.text == "A title\n- f1\n- f2")
        #expect(first?.concepts == ["type:discovery", "what-changed"])
        #expect(first?.project?.slug == slug)
        #expect(first?.session?.memorySessionId == "host-1")
        let second = try await lib.db.query(
            MemoryByProvenanceQuery(.init(provenance: "claude-mem:observation:2"))).memories.first
        #expect(second?.kind == .decision)
        #expect(second?.text == "Only narrative")
        // Nothing landed project-less: every session of this corpus resolved to a working tree.
        #expect(try await lib.db.query(MemoriesWithoutProjectQuery()).memories.isEmpty)

        // The conversation, as the person's own turns.
        let utterances = try await lib.db.query(UtterancesForSessionQuery(.init(session: "host-1"))).utterances
        #expect(utterances.map(\.text) == ["please read the corpus", "and then write the graph", "yes"])
        #expect(utterances.allSatisfy { $0.speaker == .user })
        #expect(utterances.first?.at == Date(timeIntervalSince1970: 1_700_000_100))
        #expect(utterances.first?.origin == "claude-mem:prompt:1")

        // The work state: latest-only, so the second revision of the list is what one row holds, not both.
        let lists = try await lib.db.query(WorkStateListsQuery(.init(slug: slug))).workStates
        #expect(lists.map(\.listName) == ["musai-backend"])
        #expect(lists.first?.fields == .object(["status": .string("doing"), "task": .string("the import")]))
        #expect(lists.first?.origin == "claude-mem:work_state:2")

        // The cursors name their stages explicitly: these strings are what a resumed run reads.
        #expect(
            try await lib.db.query(ImportCursorQuery(.init(source: "claude-mem:sessions"))).importCursor?
                .highWaterId == 1)
        #expect(
            try await lib.db.query(ImportCursorQuery(.init(source: "claude-mem:observations"))).importCursor?
                .highWaterId == 2)
        #expect(
            try await lib.db.query(ImportCursorQuery(.init(source: "claude-mem:prompts"))).importCursor?
                .highWaterId == 3)
    }

    @Test func anImportNeverWritesTheSameRowTwice() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let root = try makeWorkingTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let slug = ProjectBinder.slugBase(root.lastPathComponent)
        let corpus = try historyCorpus(root: root)
        let driver = try makeImport(lib, corpus)

        let first = try await driver.run()
        #expect(first.evidence == 2)

        // The second run reads nothing — the cursors are past the corpus — so every count is zero: the report
        // is this run's numbers, not the import's.
        let second = try await driver.run()
        #expect(second == ImportReport())

        // And the store still holds one of each, not two.
        #expect(try await lib.db.query(MemoriesOfKindQuery(.init(kind: .lesson))).memories.count == 1)
        #expect(try await lib.db.query(MemoriesOfKindQuery(.init(kind: .decision))).memories.count == 1)
        #expect(try await lib.db.query(UtterancesForSessionQuery(.init(session: "host-1"))).utterances.count == 3)
        #expect(try await lib.db.query(WorkStateListsQuery(.init(slug: slug))).workStates.count == 1)
        #expect(try await lib.db.query(AllProjectsQuery()).projects.count == 1)

        // A cursor can be lost — a store restored without its bookkeeping — and the writes must then land on
        // the rows already there rather than beside them, because `provenance` and `origin` are the keys.
        for source in ["claude-mem:sessions", "claude-mem:observations", "claude-mem:prompts"] {
            _ = try await lib.db.mutate(
                SetImportCursorMutation(.init(source: source, highWaterId: 0)),
                as: MusaiActors.migrator("claude-mem"))
        }
        let third = try await driver.run()
        #expect(third.sessions == 1)
        #expect(third.evidence == 0)
        #expect(third.prompts == 0)
        #expect(third.workStates == 0)
        #expect(third.skipped == 5)
        #expect(try await lib.db.query(MemoriesOfKindQuery(.init(kind: .lesson))).memories.count == 1)
        #expect(try await lib.db.query(MemoriesOfKindQuery(.init(kind: .decision))).memories.count == 1)
        #expect(try await lib.db.query(UtterancesForSessionQuery(.init(session: "host-1"))).utterances.count == 3)

        // claude-mem keeps recording: a newer revision of the list moves the one row rather than adding
        // another, which is what `workStates` counts as a write.
        try corpus.workState(
            id: 3, project: root.lastPathComponent, list: "musai-backend", fields: "{\"status\":\"done\"}")
        let fourth = try await driver.run()
        #expect(fourth.workStates == 1)
        let lists = try await lib.db.query(WorkStateListsQuery(.init(slug: slug))).workStates
        #expect(lists.count == 1)
        #expect(lists.first?.fields == .object(["status": .string("done")]))
    }

    @Test func aConversationBothToolsSawIsOneSession() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let root = try makeWorkingTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let slug = ProjectBinder.slugBase(root.lastPathComponent)

        // Live capture saw the conversation first and bound its session to the project, keyed on the host's id.
        _ = try await ProjectBinder(db: lib.db).bind(
            cwd: root, memorySessionId: "host-1", platform: "claude-code",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), as: MusaiActors.user)

        // claude-mem saw the same conversation, gave it an id of its own, and recorded no `cwd` at all.
        let corpus = try Corpus()
        try corpus
            .session(id: 1, memory: "cm-1", host: "host-1", label: root.lastPathComponent, cwd: nil)
            .observation(id: 1, memory: "cm-1", type: "discovery", title: "A title")

        let report = try await makeImport(lib, corpus).run()

        #expect(report.sessions == 1)
        // One session: claude-mem's own id is not a key Musai writes.
        let session = try await lib.db.query(SessionByMemoryIdQuery(.init(memorySessionId: "host-1"))).session
        #expect(session != nil)
        #expect(try await lib.db.query(SessionByMemoryIdQuery(.init(memorySessionId: "cm-1"))).session == nil)
        // Still bound: a corpus row with no `cwd` must not unbind a session live capture bound.
        #expect(session?.project?.slug == slug)
        #expect(report.unbound == 0)

        // And its evidence landed on that one session, still bound.
        let memory = try await lib.db.query(
            MemoryByProvenanceQuery(.init(provenance: "claude-mem:observation:1"))).memories.first
        #expect(memory?.session?.memorySessionId == "host-1")
        #expect(memory?.project?.slug == slug)
    }

    @Test func machinePromptsAreDroppedAndCounted() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let corpus = try Corpus()
        try corpus
            .session(id: 1, memory: "cm-1", host: "host-1", label: "open-source", cwd: nil)
            .prompt(id: 1, host: "host-1", text: "please read the corpus", at: 1_700_000_100)
            .prompt(
                id: 2, host: "host-1",
                text: "<task-notification>\n{\"hook\":\"Stop\"}\n</task-notification>", at: 1_700_000_200)
            .prompt(id: 3, host: "host-1", text: "ok", at: 1_700_000_300)
            // A tool result the host echoed. In the real corpus every such row is inside a
            // `<task-notification>` payload; it stands alone here so its own branch is pinned.
            .prompt(id: 4, host: "host-1", text: "toolu_01A09q90qw90lq917835lq9 read the file", at: 1_700_000_400)

        let report = try await makeImport(lib, corpus).run()

        #expect(report.prompts == 1)
        #expect(report.machinePrompts == 2)
        #expect(report.skipped == 1)
        let utterances = try await lib.db.query(UtterancesForSessionQuery(.init(session: "host-1"))).utterances
        #expect(utterances.map(\.text) == ["please read the corpus"])

        // The rule, at the one place it lives: apparatus is the machine's, a row with no words is dropped.
        #expect(MusaiImport.verdict(forPrompt: "<task-notification>…") == .machine)
        #expect(MusaiImport.verdict(forPrompt: "toolu_01A09q90qw90lq917835lq9") == .machine)
        #expect(MusaiImport.verdict(forPrompt: "ok") == .skipped)
        #expect(MusaiImport.verdict(forPrompt: "  ") == .skipped)
        #expect(MusaiImport.verdict(forPrompt: "do it") == .utterance)
    }

    @Test func aSessionWithNoProjectIsStillImported() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let corpus = try Corpus()
        try corpus
            .session(id: 1, memory: "cm-1", host: "host-1", label: "some-thread", cwd: nil)
            .observation(id: 1, memory: "cm-1", type: "gotcha", title: "The schema compiles")
            // An observation with no title, no facts and no narrative composes to no prose at all; and a work
            // state's label names no project here, and a `WorkState` has nowhere to live without one. Both are
            // counted rather than written, and neither is silently dropped.
            .observation(id: 2, memory: "cm-1", type: "fact")
            .workState(id: 1, project: "some-thread", list: "the-thread", fields: "{\"status\":\"doing\"}")

        let report = try await makeImport(lib, corpus).run()

        // 838 of the real corpus's 956 importable sessions carry no `cwd`: written, not skipped.
        #expect(report.sessions == 1)
        #expect(report.evidence == 1)
        #expect(report.workStates == 0)
        #expect(report.skipped == 2)
        #expect(report.unbound == 1)
        #expect(report.projects.isEmpty)
        // The label was a thread that never was a working tree, so discovery made it an idea.
        #expect(report.ideas == ["some-thread"])

        let session = try await lib.db.query(SessionByMemoryIdQuery(.init(memorySessionId: "host-1"))).session
        #expect(session != nil)
        #expect(session?.project == nil)

        let memory = try await lib.db.query(
            MemoryByProvenanceQuery(.init(provenance: "claude-mem:observation:1"))).memories.first
        #expect(memory?.project == nil)
        #expect(memory?.session?.memorySessionId == "host-1")
        let projectless = try await lib.db.query(MemoriesWithoutProjectQuery()).memories
        #expect(projectless.map(\.provenance) == ["claude-mem:observation:1"])
    }

    @Test func anInterruptedImportResumesAtItsCursor() async throws {
        let lib = try await MusaiLibrary.inMemory()
        // One batch at a time. Four source rows, not three: the second session is what pins that the sessions
        // stage runs to its end before anything connects through a session — a batch boundary must never
        // strand evidence behind a cursor that has already passed it.
        let corpus = try Corpus()
        try corpus
            .session(id: 1, memory: "cm-1", host: "host-1", label: "open-source", cwd: nil)
            .session(id: 2, memory: "cm-2", host: "host-2", label: "open-source", cwd: nil)
            .observation(id: 1, memory: "cm-1", type: "discovery", title: "The first")
            .observation(id: 2, memory: "cm-2", type: "decision", narrative: "The second")
        let driver = try makeImport(lib, corpus, batch: 1)

        // The first run takes every session — both, though the batch is one — and one observation, and leaves
        // its cursors exactly where it stopped.
        let first = try await driver.run()
        #expect(first.sessions == 2)
        #expect(first.evidence == 1)
        #expect(
            try await lib.db.query(ImportCursorQuery(.init(source: "claude-mem:sessions"))).importCursor?
                .highWaterId == 2)
        #expect(
            try await lib.db.query(ImportCursorQuery(.init(source: "claude-mem:observations"))).importCursor?
                .highWaterId == 1)

        // The second run imports exactly the remainder, not the first row again.
        let second = try await driver.run()
        #expect(second.sessions == 0)
        #expect(second.evidence == 1)
        #expect(
            try await lib.db.query(ImportCursorQuery(.init(source: "claude-mem:observations"))).importCursor?
                .highWaterId == 2)
        let lessons = try await lib.db.query(MemoriesOfKindQuery(.init(kind: .lesson))).memories
        let decisions = try await lib.db.query(MemoriesOfKindQuery(.init(kind: .decision))).memories
        #expect(lessons.count == 1)
        #expect(decisions.count == 1)
        #expect(decisions.first?.session?.memorySessionId == "host-2")

        // And a third run has nothing left to do.
        let third = try await driver.run()
        #expect(third == ImportReport())
    }

    @Test func aDryRunReportsEverythingAndWritesNothing() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let root = try makeWorkingTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let slug = ProjectBinder.slugBase(root.lastPathComponent)
        let corpus = try historyCorpus(root: root)
        let driver = try makeImport(lib, corpus)

        let dry = try await driver.run(dryRun: true)

        #expect(dry.dryRun)
        // Nothing at all: no session, no memory, no utterance, no work state, no project, no idea, no cursor.
        try await expectNothingWritten(lib, slug: slug)

        let real = try await driver.run()

        // The same numbers — including discovery's verdict, which a dry run has to name before it is kept —
        // and only then are they in the store.
        #expect(
            dry == ImportReport(
                dryRun: true, sessions: real.sessions, evidence: real.evidence, prompts: real.prompts,
                workStates: real.workStates, proposals: real.proposals, projects: real.projects,
                ideas: real.ideas, buckets: real.buckets, unbound: real.unbound,
                machinePrompts: real.machinePrompts, skipped: real.skipped))
        #expect(real.sessions == 1)
        #expect(real.evidence == 2)
        #expect(real.prompts == 3)
        #expect(real.workStates == 1)
        #expect(real.projects == [slug])
        #expect(
            try await lib.db.query(SessionByMemoryIdQuery(.init(memorySessionId: "host-1"))).session != nil)
    }

    /// The store as a fresh install has it, and as a dry run must leave it.
    private func expectNothingWritten(_ lib: MusaiLibrary, slug: String) async throws {
        #expect(try await lib.db.query(SessionByMemoryIdQuery(.init(memorySessionId: "host-1"))).session == nil)
        #expect(
            try await lib.db.query(MemoryByProvenanceQuery(.init(provenance: "claude-mem:observation:1")))
                .memories.isEmpty)
        #expect(try await lib.db.query(MemoriesWithoutProjectQuery()).memories.isEmpty)
        #expect(try await lib.db.query(UtterancesForSessionQuery(.init(session: "host-1"))).utterances.isEmpty)
        #expect(try await lib.db.query(WorkStateListsQuery(.init(slug: slug))).workStates.isEmpty)
        #expect(try await lib.db.query(ProjectBySlugQuery(.init(slug: slug))).project == nil)
        #expect(try await lib.db.query(AllProjectsQuery()).projects.isEmpty)
        #expect(try await lib.db.query(AllIdeasQuery()).ideas.isEmpty)
        for source in ["claude-mem:sessions", "claude-mem:observations", "claude-mem:prompts"] {
            #expect(try await lib.db.query(ImportCursorQuery(.init(source: source))).importCursor == nil)
        }
    }
}
