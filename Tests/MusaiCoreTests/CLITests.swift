import Foundation
import Testing
@testable import MusaiCore
@testable import musai

/// The first run's commands — `musai import` and `musai recall`, and the migration view of `musai review` —
/// driven in-process with the client injected. Nothing here spawns the built executable: a `musai import` that
/// finds no record asks launchd to start the agent *by name*, and the machine this suite runs on may have a
/// live agent behind that name, whose store a test must not import into.
@Suite struct CLITests {
    private let at = Date(timeIntervalSince1970: 1_700_000_000)

    /// One migrated memory, written the way the import writes one: keyed on its provenance, and unbound
    /// unless the test names a project — the shape most of an imported corpus has.
    @discardableResult
    private func migrated(
        _ backend: BackendFixture, text: String, project: String? = nil, n: Int = 1
    ) async throws -> UUID {
        let session = "host-\(n)"
        if let project {
            _ = try await backend.library.db.mutate(
                CreateProjectMutation(.init(name: project, slug: project)), as: MusaiActors.user)
            _ = try await backend.library.db.mutate(
                UpsertSessionMutation(
                    .init(memorySessionId: session, platform: "claude-code", startedAt: at, slug: project)),
                as: MusaiActors.user)
            return try await backend.library.db.mutate(
                RecordMemoryForSessionMutation(
                    .init(
                        kind: .fact, origin: .migrated, text: text,
                        provenance: "claude-mem:observation:\(n)", slug: project, memorySessionId: session)),
                as: MusaiActors.migrator("claude-mem")).createMemory.id
        }
        _ = try await backend.library.db.mutate(
            UpsertSessionUnboundMutation(
                .init(memorySessionId: session, platform: "claude-code", startedAt: at)),
            as: MusaiActors.migrator("claude-mem"))
        return try await backend.library.db.mutate(
            RecordMemoryUnboundMutation(
                .init(
                    kind: .fact, origin: .migrated, text: text,
                    provenance: "claude-mem:observation:\(n)", memorySessionId: session)),
            as: MusaiActors.migrator("claude-mem")).createMemory.id
    }

    /// A missing backend is one diagnostic line naming `musai install`, on stderr, and nothing on stdout: the
    /// person is told what to run, and the shell sees success — this is the same executable a hook calls.
    @Test func importNeedsARunningBackendAndSaysSo() async throws {
        var out: [String] = []
        var err: [String] = []
        let command = Import(
            arguments: ["--from", "/tmp/musai-cli-nowhere.db"], connect: { nil },
            write: { out.append($0) }, diagnose: { err.append($0) })

        await command.run()

        #expect(out.isEmpty)
        #expect(err.count == 1)
        #expect(err.first?.contains("musai install") == true)
    }

    /// A live in-process listener and a temp corpus: the counts reach stdout, the loop stops on the pass that
    /// imports nothing left, and the person is told the corpus was read only and that this resumes.
    @Test func importPrintsTheReport() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        let corpus = try ClaudeMemCorpus.thread()
        let client = MusaiClient(record: backend.record(), token: BackendFixture.token)

        // `--dry-run` first, as the README's first run does. It reports what a run would do and writes none of
        // it — including no cursor, which the real run below proves: it still does the corpus's whole work.
        var dry: [String] = []
        await Import(
            arguments: ["--from", corpus.url.path, "--dry-run"], connect: { client },
            write: { dry.append($0) }, diagnose: { _ in }
        ).run()
        #expect(dry.contains { $0.contains("would import") })
        #expect(dry.contains { $0.contains("nothing was written") })
        #expect(
            try await backend.library.db.query(
                MemoryByProvenanceQuery(.init(provenance: "claude-mem:observation:1"))).memories.isEmpty)
        #expect(
            try await backend.library.db.query(ImportCursorQuery(.init(source: "claude-mem:sessions")))
                .importCursor == nil)

        var out: [String] = []
        var err: [String] = []
        let command = Import(
            arguments: ["--from", corpus.url.path], connect: { client },
            write: { out.append($0) }, diagnose: { err.append($0) })

        await command.run()

        #expect(err.isEmpty)
        // The whole thing, exactly: the corpus was read only, one pass did the work and the next found nothing
        // left (the endpoint's empty report is the stop signal, so exactly one pass line was printed), and the
        // person is told what was discovered and that this resumes.
        #expect(
            out == [
                "musai: importing \(corpus.url.path) — read only, and nothing is ever written back to it",
                "musai: pass 1: 1 session, 2 memories, 1 prompt, 0 work states, 1 proposal, "
                    + "1 machine payload dropped, 1 session with no project",
                "musai: imported 1 session, 2 memories, 1 prompt, 0 work states, 1 proposal, "
                    + "1 machine payload dropped, 1 session with no project",
                "musai: discovery names 0 projects, 0 ideas, 1 filing label (open-source)",
                "musai: stop it any time; each stage keeps a cursor, so `musai import` again resumes there",
            ])

        // And it landed: the corpus really was read, which the counts alone could not say.
        let memory = try await backend.library.db.query(
            MemoryByProvenanceQuery(.init(provenance: "claude-mem:observation:1"))).memories.first
        #expect(memory?.text == "Norvo keeps one file")
    }

    /// `musai recall <words>` joins its arguments into one query and prints what it found, one memory to a
    /// line: the text is the answer.
    @Test func recallPrintsWhatItFound() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        try await migrated(backend, text: "Norvo keeps one file")
        let client = MusaiClient(record: backend.record(), token: BackendFixture.token)

        var out: [String] = []
        var err: [String] = []
        await Recall(
            arguments: ["Norvo", "keeps"], connect: { client }, write: { out.append($0) },
            diagnose: { err.append($0) }
        ).run()

        #expect(out == ["Norvo keeps one file"])
        #expect(err.isEmpty)
    }

    /// A search that finds nothing is silence, not an error — exactly as the endpoint treats it.
    @Test func recallWithNothingFoundPrintsNothingAndExitsZero() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        try await migrated(backend, text: "Norvo keeps one file")
        let client = MusaiClient(record: backend.record(), token: BackendFixture.token)

        var out: [String] = []
        var err: [String] = []
        await Recall(
            arguments: ["nothing-matches-these-words"], connect: { client }, write: { out.append($0) },
            diagnose: { err.append($0) }
        ).run()

        #expect(out.isEmpty)
        #expect(err.isEmpty)
    }

    /// `--project` narrows the search and is not one of its words: the memory lives on the project, so it is
    /// found — and a query that had swallowed the flag would search for "musai Norvo" and find nothing.
    @Test func recallHonoursTheProjectItIsGiven() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        try await migrated(backend, text: "Norvo keeps one file", project: "musai")
        try await migrated(backend, text: "unrelated words", n: 2)
        let client = MusaiClient(record: backend.record(), token: BackendFixture.token)

        var out: [String] = []
        await Recall(
            arguments: ["--project", "musai", "Norvo"], connect: { client }, write: { out.append($0) },
            diagnose: { _ in }
        ).run()

        #expect(out == ["Norvo keeps one file"])
    }

    /// `musai review --migrated` must not show a page of ~6 900 as the whole backlog: the reply carries
    /// `hasMore`, and a page says so and says how to see further.
    @Test func reviewMigratedSaysWhenThereIsMoreThanItShows() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        for n in 1...2 {
            _ = try await backend.library.db.mutate(
                RecordMigratedProposalUnboundMutation(
                    .init(title: "Migrated \(n)", act: .decision, origin: "claude-mem:observation:\(n)")),
                as: MusaiActors.migrator("claude-mem"))
        }
        let client = MusaiClient(record: backend.record(), token: BackendFixture.token)

        var out: [String] = []
        await Review(
            client: client, migrated: true, first: 1, read: { nil }, write: { out.append($0) },
            diagnose: { _ in }
        ).run()

        #expect(out.contains { $0.contains("Migrated 1") })
        #expect(!out.contains { $0.contains("Migrated 2") })
        #expect(out.contains { $0.contains("--migrated --first") })

        // With the whole backlog in one page, the same view says that it is all of it.
        var whole: [String] = []
        await Review(
            client: client, migrated: true, read: { nil }, write: { whole.append($0) }, diagnose: { _ in }
        ).run()

        #expect(whole.contains { $0.contains("Migrated 2") })
        #expect(!whole.contains { $0.contains("--first") })
    }
}
