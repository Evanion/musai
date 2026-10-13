import Foundation
import SQLite3
import Testing
@testable import MusaiCore

/// The one-sided entries a corpus recorded, arriving as proposals the person confirms: claude-mem's
/// `decision`-typed observations and a summary's `next_steps`. They are filed in `MIGRATED`, so ~7 000
/// imported entries never sit in the live review list, and `settle`/`drop` act on them exactly as on a live
/// proposal — which is why the correction signal survives filing them without asking a model.
///
/// Nothing here ever opens `~/.claude-mem/claude-mem.db`: every corpus is a temp file this suite makes and
/// removes. The store is always in memory.
@Suite struct ImportProposalTests {
    /// A throwaway claude-mem corpus: the tables the import reads, and an insert per row. Removed when the
    /// test's scope ends.
    private final class Corpus {
        enum Failure: Error, Equatable { case open(String), exec(String) }

        let url: URL
        private var db: OpaquePointer?

        init() throws {
            url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appending(path: "musai-proposals-\(UUID().uuidString).db")
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
            id: Int, memory: String?, host: String, label: String = "musai", cwd: String? = nil
        ) throws -> Corpus {
            try exec("""
            INSERT INTO sdk_sessions(
                id, memory_session_id, content_session_id, platform_source, project, custom_title,
                started_at_epoch, completed_at_epoch, status, cwd)
            VALUES (\(id), \(Self.literal(memory)), \(Self.literal(host)), 'claude', \(Self.literal(label)),
                NULL, 1_700_000_000, NULL, 'completed', \(Self.literal(cwd)));
            """)
            return self
        }

        @discardableResult
        func observation(
            id: Int, memory: String, type: String = "decision", title: String? = nil, facts: String? = nil,
            narrative: String? = nil
        ) throws -> Corpus {
            try exec("""
            INSERT INTO observations(
                id, memory_session_id, project, text, type, title, facts, narrative, concepts,
                created_at_epoch)
            VALUES (\(id), \(Self.literal(memory)), 'claude-mem', NULL, \(Self.literal(type)),
                \(Self.literal(title)), \(Self.literal(facts)), \(Self.literal(narrative)), NULL,
                1_700_000_000);
            """)
            return self
        }

        @discardableResult
        func summary(id: Int, memory: String, nextSteps: String?) throws -> Corpus {
            try exec("""
            INSERT INTO session_summaries(
                id, memory_session_id, project, request, next_steps, created_at_epoch)
            VALUES (\(id), \(Self.literal(memory)), 'claude-mem', 'a request',
                \(Self.literal(nextSteps)), 1_700_000_000);
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

    /// A proposal as the import filed it, in the shape these tests read it back.
    private struct Migrated: Equatable {
        let id: UUID
        let origin: String?
        let title: String
        let rationale: String?
        let act: ActKind
        let slug: String?
    }

    /// A throwaway directory that is a working tree as far as `ProjectBinder` is concerned: a `.git/config`
    /// carrying an `origin`. Temp only — no repository of the person's is read.
    private func makeWorkingTree() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-proposals-tree-\(UUID().uuidString)")
        let git = root.appending(path: ".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "[remote \"origin\"]\n\turl = git@github.com:evanion/musai-fixture.git\n".write(
            to: git.appending(path: "config"), atomically: true, encoding: .utf8)
        return root
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

    /// The migration view, as this suite reads it.
    private func migrated(_ lib: MusaiLibrary) async throws -> [Migrated] {
        try await lib.db.query(MigratedDecisionsQuery()).decisions.map {
            Migrated(
                id: $0.id, origin: $0.origin, title: $0.title, rationale: $0.rationale, act: $0.act,
                slug: $0.project?.slug)
        }
    }

    private func migrated(_ lib: MusaiLibrary, origin: String) async throws -> Migrated? {
        try await migrated(lib).first { $0.origin == origin }
    }

    /// The origins the migration view holds, as a set: the rows are ordered by `createdAt`, and two rows
    /// written in one run can share an instant.
    private func migratedOrigins(_ lib: MusaiLibrary) async throws -> Set<String> {
        Set(try await migrated(lib).compactMap(\.origin))
    }

    @Test func oneSidedDecisionsBecomeMigratedProposals() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let root = try makeWorkingTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let slug = ProjectBinder.slugBase(root.lastPathComponent)
        let corpus = try Corpus()
        try corpus
            .session(id: 1, memory: "cm-1", host: "host-1", label: root.lastPathComponent, cwd: root.path)
            .observation(
                id: 1, memory: "cm-1", type: "decision", title: "One Norvo file",
                narrative: "Anti-clunk, and one process owns the file.")
            .observation(
                id: 2, memory: "cm-1", type: "decision", title: "Yarn is the package manager",
                facts: "[\"pnpm is not used\",\"npm is not used\"]")
            .summary(
                id: 1, memory: "cm-1",
                nextSteps: "Awaiting user decision on which issue to tackle next:\n#84, #83 or #82")
            // A session with no working tree, like 838 of the real corpus's: its entry has no project to live
            // on, and the unbound twin is the only operation that can file it.
            .session(id: 2, memory: "cm-2", host: "host-2", label: "a-thread", cwd: nil)
            .observation(id: 3, memory: "cm-2", type: "decision", title: "Never a repository")
        let driver = try makeImport(lib, corpus)

        // A dry run proposes the same four and writes none of them — nor a cursor.
        let dry = try await driver.run(dryRun: true)
        #expect(dry.proposals == 4)
        #expect(try await migratedOrigins(lib).isEmpty)

        let report = try await driver.run()

        #expect(report.proposals == 4)
        #expect(
            try await migratedOrigins(lib) == [
                "claude-mem:observation:1", "claude-mem:observation:2", "claude-mem:observation:3",
                "claude-mem:summary:1",
            ])
        // Each carries the corpus's own headline, the reason behind it, and the project its session bound to.
        let first = try #require(try await migrated(lib, origin: "claude-mem:observation:1"))
        #expect(first.title == "One Norvo file")
        #expect(first.rationale == "Anti-clunk, and one process owns the file.")
        #expect(first.act == .decision)
        #expect(first.slug == slug)
        let second = try #require(try await migrated(lib, origin: "claude-mem:observation:2"))
        #expect(second.title == "Yarn is the package manager")
        #expect(second.rationale == "- pnpm is not used\n- npm is not used")
        // A summary has a title and no `type` of its own: its proposal is the corpus's `next_steps`, and its
        // act is the default — an unconfirmed one-sided entry is a decision nobody has confirmed.
        let summary = try #require(try await migrated(lib, origin: "claude-mem:summary:1"))
        #expect(summary.title == "Awaiting user decision on which issue to tackle next:")
        #expect(summary.rationale == "#84, #83 or #82")
        #expect(summary.act == .decision)
        #expect(summary.slug == slug)
        // And the entry under the project-less session is filed unbound rather than lost or mis-bound.
        #expect(try #require(try await migrated(lib, origin: "claude-mem:observation:3")).slug == nil)
    }

    @Test func liveReviewIsNeverBuried() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let root = try makeWorkingTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let slug = ProjectBinder.slugBase(root.lastPathComponent)
        let corpus = try Corpus()
        try corpus.session(id: 1, memory: "cm-1", host: "host-1", label: root.lastPathComponent, cwd: root.path)
        for id in 1...200 {
            try corpus.observation(id: id, memory: "cm-1", type: "decision", title: "Imported decision \(id)")
        }

        #expect(try await makeImport(lib, corpus).run().proposals == 200)

        // One proposal live capture really saw, filed the way the curator files one.
        let said = try await MusaiCapture(db: lib.db).captureUserTurn(
            text: "we will use one Norvo file", at: Date(timeIntervalSince1970: 1_700_100_000),
            origin: "claude", session: "live-1", cwd: root.path, as: MusaiActors.curator)
        _ = try await lib.db.mutate(
            RecordProposalMutation(.init(
                title: "One Norvo file", rationale: "Anti-clunk", act: .decision, utterance: said,
                project: slug)),
            as: MusaiActors.curator)

        // The live list is what it always was: `state eq PROPOSED`, and nothing imported is in it.
        let review = ReviewSession(db: lib.db)
        #expect(try await review.pending().map(\.title) == ["One Norvo file"])
        // The migration view is its own bounded list — the 200 do not crowd it, either.
        #expect(try await lib.db.query(MigratedDecisionsQuery()).decisions.count == 50)
        #expect(try await lib.db.query(PendingDecisionsQuery()).decisions.count == 1)
    }

    @Test func aMigratedProposalIsSettledByTheSameAct() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let root = try makeWorkingTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let corpus = try Corpus()
        try corpus
            .session(id: 1, memory: "cm-1", host: "host-1", label: root.lastPathComponent, cwd: root.path)
            .observation(id: 1, memory: "cm-1", type: "decision", title: "One Norvo file")
        #expect(try await makeImport(lib, corpus).run().proposals == 1)
        let id = try #require(try await migrated(lib, origin: "claude-mem:observation:1")).id

        // The same act the person applies to a live proposal, unchanged: `settle` reads a `Decision` by id.
        try await ReviewSession(db: lib.db).apply(.settle, to: id, as: MusaiActors.user)

        let row = try await lib.db.query(DecisionByIDQuery(.init(id: id))).decision
        #expect(row?.state == .settled)
        #expect(row?.settledAt != nil)
        #expect(try await migrated(lib, origin: "claude-mem:observation:1") == nil)
        // And it lands in the gap exactly as a live settled proposal does: one act, one behaviour.
        let gaps = try await ReviewSession(db: lib.db).unpersisted()
        #expect(gaps.map(\.title) == ["One Norvo file"])
    }

    @Test func evidenceIsNotProposedAndAProposalIsNotEvidence() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let root = try makeWorkingTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let corpus = try Corpus()
        try corpus
            .session(id: 1, memory: "cm-1", host: "host-1", label: root.lastPathComponent, cwd: root.path)
            .observation(id: 1, memory: "cm-1", type: "discovery", title: "A title", facts: "[\"f1\"]")
            .observation(id: 2, memory: "cm-1", type: "decision", title: "Use one Norvo file")

        let report = try await makeImport(lib, corpus).run()

        // Both are evidence: a `decision`-typed observation is what the corpus said, and the memory records it.
        #expect(report.evidence == 2)
        #expect(
            try await lib.db.query(MemoryByProvenanceQuery(.init(provenance: "claude-mem:observation:1")))
                .memories.first?.kind == .lesson)
        #expect(
            try await lib.db.query(MemoryByProvenanceQuery(.init(provenance: "claude-mem:observation:2")))
                .memories.first?.kind == .decision)
        // But only one side of a choice is proposed: the corpus's other 19 types are evidence only.
        #expect(report.proposals == 1)
        #expect(
            try await lib.db.query(DecisionByOriginQuery(.init(origin: "claude-mem:observation:1")))
                .decisions.isEmpty)
        #expect(
            try await lib.db.query(DecisionByOriginQuery(.init(origin: "claude-mem:observation:2")))
                .decisions.count == 1)
    }

    @Test func droppingAMigratedProposalIsNotUndoneByARerun() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let root = try makeWorkingTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let corpus = try Corpus()
        try corpus
            .session(id: 1, memory: "cm-1", host: "host-1", label: root.lastPathComponent, cwd: root.path)
            .observation(id: 1, memory: "cm-1", type: "decision", title: "One Norvo file")
            .observation(id: 2, memory: "cm-1", type: "decision", title: "Yarn is the package manager")
            .summary(id: 1, memory: "cm-1", nextSteps: "Awaiting user decision on the next issue")
        let driver = try makeImport(lib, corpus)
        #expect(try await driver.run().proposals == 3)
        // Each source's watermark is its own, and both moved past what the stage read: the cursor names are
        // what a resumed run reads, and what the drop below is protected by.
        #expect(
            try await lib.db.query(ImportCursorQuery(.init(source: "claude-mem:proposals"))).importCursor?
                .highWaterId == 2)
        #expect(
            try await lib.db.query(ImportCursorQuery(.init(source: "claude-mem:summary_proposals")))
                .importCursor?.highWaterId == 1)
        let dropped = try #require(try await migrated(lib, origin: "claude-mem:observation:1")).id

        try await ReviewSession(db: lib.db).apply(.drop, to: dropped, as: MusaiActors.user)
        #expect(try await migrated(lib, origin: "claude-mem:observation:1") == nil)

        // The re-run reads past it, so what the person dropped stays dropped.
        let second = try await driver.run()
        #expect(second.proposals == 0)
        #expect(try await migrated(lib, origin: "claude-mem:observation:1") == nil)
        #expect(try await migrated(lib, origin: "claude-mem:observation:2") != nil)

        // What holds it is the stage's own watermark: `drop` deletes the row *and* its origin, so a run that
        // had to re-read the source row would file it again. That is the reason the cursor exists.
        for source in ["claude-mem:proposals", "claude-mem:summary_proposals"] {
            _ = try await lib.db.mutate(
                SetImportCursorMutation(.init(source: source, highWaterId: 0)),
                as: MusaiActors.migrator("claude-mem"))
        }
        let third = try await driver.run()
        #expect(third.proposals == 1)
        #expect(try await migrated(lib, origin: "claude-mem:observation:1") != nil)
        // One row read again and deliberately not written: the summary, whose proposal is already filed and
        // whose table no other stage reads. The two observations re-read are not counted — the evidence stage
        // has already accounted for both.
        #expect(third.skipped == 1)
    }
}
