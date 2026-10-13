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

    /// `musai review --migrated` is a **confirm surface**, not a listing: the same keys the live review
    /// offers, over the imported list, acting by id. A settled entry leaves the migrated view, because it is
    /// the same act and the same move out of the list as settling a live proposal.
    @Test func reviewMigratedSettlesAnEntryThroughTheCLI() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        let id = try await backend.library.db.mutate(
            RecordMigratedProposalUnboundMutation(
                .init(title: "One Norvo file", act: .decision, origin: "claude-mem:observation:1")),
            as: MusaiActors.migrator("claude-mem")).createDecision.id
        let client = MusaiClient(record: backend.record(), token: BackendFixture.token)

        var out: [String] = []
        var err: [String] = []
        await Review(
            migrated: true, connect: { client }, read: { "y" }, write: { out.append($0) },
            diagnose: { err.append($0) }
        ).run()

        #expect(err.isEmpty)
        #expect(out.contains { $0.contains("One Norvo file") })
        #expect(
            try await backend.library.db.query(DecisionByIDQuery(.init(id: id))).decision?.state == .settled)
        #expect(try await client.migrated().proposals.isEmpty)
    }

    /// A dropped migrated entry is gone from the store, not merely hidden from the view.
    @Test func reviewMigratedDropsAnEntryThroughTheCLI() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        let id = try await backend.library.db.mutate(
            RecordMigratedProposalUnboundMutation(
                .init(title: "Never a repository", act: .decision, origin: "claude-mem:observation:2")),
            as: MusaiActors.migrator("claude-mem")).createDecision.id
        let client = MusaiClient(record: backend.record(), token: BackendFixture.token)

        var out: [String] = []
        var err: [String] = []
        await Review(
            migrated: true, connect: { client }, read: { "d" }, write: { out.append($0) },
            diagnose: { err.append($0) }
        ).run()

        #expect(err.isEmpty)
        #expect(try await backend.library.db.query(DecisionByIDQuery(.init(id: id))).decision == nil)
        #expect(try await client.migrated().proposals.isEmpty)
    }

    /// A missing backend is one diagnostic line naming `musai install`, on stderr, and nothing on stdout —
    /// the same fact every other command reports, and no crash when the agent is not running.
    @Test func reviewMigratedNeedsARunningBackendAndSaysSo() async throws {
        var out: [String] = []
        var err: [String] = []
        await Review(
            migrated: true, connect: { nil }, read: { nil }, write: { out.append($0) },
            diagnose: { err.append($0) }
        ).run()

        #expect(out.isEmpty)
        #expect(err.count == 1)
        #expect(err.first?.contains("musai install") == true)
    }

    /// `musai review --migrated` must not show a page of ~6 900 as the whole backlog: the reply carries
    /// `hasMore`, and a page says so and says how to see further. Every entry is skipped, so the page is
    /// walked without changing what is waiting.
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
            migrated: true, first: 1, connect: { client }, read: { "s" }, write: { out.append($0) },
            diagnose: { _ in }
        ).run()

        #expect(out.contains { $0.contains("Migrated 1") })
        #expect(!out.contains { $0.contains("Migrated 2") })
        #expect(out.contains { $0.contains("--migrated --first") })

        // With the whole backlog in one page, the same view says that it is all of it.
        var whole: [String] = []
        await Review(
            migrated: true, connect: { client }, read: { "s" }, write: { whole.append($0) },
            diagnose: { _ in }
        ).run()

        #expect(whole.contains { $0.contains("Migrated 2") })
        #expect(!whole.contains { $0.contains("--first") })
    }

    /// The paging advice must not dead-end at the endpoint's cap. At the ceiling the old footer kept advising
    /// `--first \(shown * 2)`, which the endpoint clamps back to the same page and the same advice — a circle.
    /// The line that `musai review --migrated` prints for a partial page is a pure function of the page size,
    /// so the ceiling is pinned here without standing up ~6 900 rows; the surface calls it for every page it
    /// shows, which `reviewMigratedSaysWhenThereIsMoreThanItShows` covers end to end.
    @Test func theMigrationFooterStopsAdvisingPastTheCap() {
        let below = Review.migratedMoreLine(shown: 50)
        #expect(below.contains("--first 100"))

        // Near the cap the advice is clamped to it, rather than naming a `--first` the endpoint would cut back.
        let near = Review.migratedMoreLine(shown: 400)
        #expect(near.contains("--first \(MusaiEndpoint.migratedFirstCap)"))
        #expect(!near.contains("--first 800"))

        // At the cap there is nothing left to ask for, so the line says what does advance the list instead.
        let atCap = Review.migratedMoreLine(shown: MusaiEndpoint.migratedFirstCap)
        #expect(!atCap.contains("--first"))
        #expect(atCap.contains("worked through"))
        #expect(atCap.contains("more than these \(MusaiEndpoint.migratedFirstCap)"))
    }
}
