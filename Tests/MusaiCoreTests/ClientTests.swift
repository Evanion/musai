import Darwin
import Foundation
import Testing
@testable import MusaiCore

/// A port that completes the TCP handshake and then never answers a word of it: a bare listening socket whose
/// backlog absorbs the connection, with nothing ever accepting it. It is the shape of a backend that has
/// stopped answering, and it exists so the client's own bound can be measured without leaving this process.
private final class StalledEndpoint {
    let port: UInt16
    private let descriptor: Int32

    static func make() throws -> StalledEndpoint {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.noSocket }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            Darwin.close(descriptor)
            throw Failure.noSocket
        }
        var chosen = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &chosen) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else {
            Darwin.close(descriptor)
            throw Failure.noSocket
        }
        return StalledEndpoint(port: UInt16(bigEndian: chosen.sin_port), descriptor: descriptor)
    }

    private init(port: UInt16, descriptor: Int32) {
        self.port = port
        self.descriptor = descriptor
    }

    func shut() { Darwin.close(descriptor) }

    enum Failure: Error { case noSocket }
}

/// The client, over a real socket: it talks to an in-process listener (Task 2), so these tests exercise the
/// wire and not the router.
@Suite struct ClientTests {
    private let at = Date(timeIntervalSince1970: 1_700_000_000)

    private func turn(_ text: String) -> NormalizedEvent {
        NormalizedEvent(kind: .userTurn, session: "s1", cwd: "/tmp/musai-client", at: at, text: text)
    }

    @Test func aCaptureAgainstALiveListenerIsStored() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        let client = MusaiClient(record: backend.record(), token: BackendFixture.token)

        #expect(try await client.capture(turn("we will use one Norvo file")) == .created)

        let rows = try await backend.library.db.query(UtterancesForSessionQuery(.init(session: "s1"))).utterances
        #expect(rows.map(\.text) == ["we will use one Norvo file"])
    }

    @Test func theSameCaptureTwiceReportsDuplicate() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        let client = MusaiClient(record: backend.record(), token: BackendFixture.token)

        #expect(try await client.capture(turn("same words")) == .created)
        #expect(try await client.capture(turn("same words")) == .duplicate)
        let rows = try await backend.library.db.query(UtterancesForSessionQuery(.init(session: "s1"))).utterances
        #expect(rows.count == 1)
    }

    @Test func contextReturnsTheSliceTheEndpointWould() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        let cwd = "/tmp/musai-client-context"
        let said = try await MusaiCapture(db: backend.library.db).captureUserTurn(
            text: "we will use one Norvo file", at: at, origin: "claude", session: "s1", cwd: cwd,
            as: MusaiActors.curator)
        let slug = try #require(
            try await backend.library.db.query(ProjectByRootQuery(.init(root: cwd))).projects.first?.slug)
        let proposal = try await backend.library.db.mutate(
            RecordProposalMutation(
                .init(title: "One Norvo file", rationale: nil, act: .decision, utterance: said, project: slug)),
            as: MusaiActors.curator)
        try await ReviewSession(db: backend.library.db).apply(
            .settle, to: proposal.createDecision.id, as: MusaiActors.user)

        let client = MusaiClient(record: backend.record(), token: BackendFixture.token)
        #expect(try await client.context(cwd: cwd)?.contains("One Norvo file") == true)

        // A directory the backend knows nothing about has nothing to say, and says it as nil, not an error.
        #expect(try await client.context(cwd: "/tmp/musai-client-nowhere") == nil)
    }

    @Test func aStaleRecordIsReportedRatherThanUsed() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        let stale = backend.record()
        // The port is closed; the record still names it, and its pid — this very process — still looks alive.
        backend.listener.stop()
        #expect(stale.isAlive)

        let client = MusaiClient(record: stale, token: BackendFixture.token)
        // No health: the record is stale, so the caller is told to start the agent rather than post into a
        // port it does not own.
        #expect(await client.health() == nil)
        await #expect(throws: MusaiClient.Failure.unreachable) { try await client.capture(turn("never sent")) }

        let rows = try await backend.library.db.query(UtterancesForSessionQuery(.init(session: "s1"))).utterances
        #expect(rows.isEmpty)
    }

    /// The bound this fix exists to hold: a client whose endpoint accepted the connection and then stopped
    /// answering must give up inside its own timeout. The assertion is near that bound rather than merely
    /// under a minute, so it fails if nothing sets one — `URLSession` would let this run for sixty seconds,
    /// which is what CI saw, and four times the `UserPromptSubmit` hook budget the plan allows.
    @Test func aStalledEndpointIsGivenUpOnInsideTheClientsOwnTimeout() async throws {
        let stalled = try StalledEndpoint.make()
        defer { stalled.shut() }
        let record = HelperRecord(
            port: stalled.port, token: "a-token", pid: getpid(),
            protocolVersion: EndpointWire.protocolVersion, storePath: "/tmp/Musai.norvo")
        let client = MusaiClient(record: record, token: "a-token")

        let start = Date()
        // A stall is "nothing answered at the recorded port", which is the failure the caller already knows
        // how to report — never an untyped error escaping the client.
        await #expect(throws: MusaiClient.Failure.unreachable) {
            try await client.context(cwd: "/tmp/musai-stalled")
        }
        let elapsed = Date().timeIntervalSince(start)

        // Two seconds of slack is for a loaded machine's dispatch timer, not a second bound: the client's own
        // bound is pinned above, and the sixty-second default is nowhere near this.
        #expect(elapsed < MusaiClient.requestTimeout + 2)
        #expect(MusaiClient.requestTimeout <= 5)
    }

    @Test func aMajorVersionMismatchIsRefusedNotGuessed() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        let event = turn("words a helper of another major must not store")

        // A different major is refused before the post, so nothing lands in the live helper's store.
        let incompatible = MusaiClient(record: backend.record(protocolVersion: "2.0"), token: BackendFixture.token)
        await #expect(
            throws: MusaiClient.Failure.incompatibleProtocol(
                helper: "2.0", expected: EndpointWire.protocolVersion)
        ) {
            try await incompatible.capture(event)
        }
        let rows = try await backend.library.db.query(UtterancesForSessionQuery(.init(session: "s1"))).utterances
        #expect(rows.isEmpty)

        #expect(MusaiClient.accepts(protocolVersion: "2.0") == false)
        #expect(MusaiClient.accepts(protocolVersion: "1.7"))

        // A different minor is additive, because the protocol only grows: the same post goes through.
        let additive = MusaiClient(record: backend.record(protocolVersion: "1.7"), token: BackendFixture.token)
        #expect(try await additive.capture(event) == .created)
        let after = try await backend.library.db.query(UtterancesForSessionQuery(.init(session: "s1"))).utterances
        #expect(after.map(\.text) == [event.text])
    }

    @Test func proposalsAndGapRefuseAnIncompatibleHelper() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        // The gate has to hold on every route, not most of them: a listing from a helper of another major is
        // just as unreadable as a capture, so `musai review` must refuse rather than talk to it.
        let client = MusaiClient(record: backend.record(protocolVersion: "2.0"), token: BackendFixture.token)
        let refusal = MusaiClient.Failure.incompatibleProtocol(
            helper: "2.0", expected: EndpointWire.protocolVersion)
        await #expect(throws: refusal) { _ = try await client.proposals() }
        await #expect(throws: refusal) { _ = try await client.gap() }
    }

    /// `musai recall`'s read: a word in a memory finds it, even when the memory has no project — the shape most
    /// of an imported corpus has, and the reason `MemorySummary.project` is optional.
    @Test func memoriesAreFoundByTextWithNoProject() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        // Two project-less migrated memories, exactly as the import writes them: a session with no `cwd`, and
        // its evidence connected to that session rather than to a project. The second is what tells a search
        // from a listing — a `q` that found nothing and listed the project-less memories instead would return
        // both.
        _ = try await backend.library.db.mutate(
            UpsertSessionUnboundMutation(
                .init(memorySessionId: "host-1", platform: "claude-code", startedAt: at)),
            as: MusaiActors.migrator("claude-mem"))
        _ = try await backend.library.db.mutate(
            UpsertSessionUnboundMutation(
                .init(memorySessionId: "host-2", platform: "claude-code", startedAt: at)),
            as: MusaiActors.migrator("claude-mem"))
        let id = try await backend.library.db.mutate(
            RecordMemoryUnboundMutation(
                .init(
                    kind: .fact, origin: .migrated, text: "Norvo keeps one file",
                    provenance: "claude-mem:observation:1", memorySessionId: "host-1")),
            as: MusaiActors.migrator("claude-mem")).createMemory.id
        _ = try await backend.library.db.mutate(
            RecordMemoryUnboundMutation(
                .init(
                    kind: .fact, origin: .migrated, text: "unrelated words",
                    provenance: "claude-mem:observation:2", memorySessionId: "host-2")),
            as: MusaiActors.migrator("claude-mem"))

        let client = MusaiClient(record: backend.record(), token: BackendFixture.token)
        let found = try await client.memories(q: "Norvo keeps one file")

        #expect(found.map(\.id) == [id])
        #expect(found.first?.text == "Norvo keeps one file")
        #expect(found.first?.kind == .fact)
        #expect(found.first?.origin == .migrated)
        #expect(found.first?.provenance == "claude-mem:observation:1")
        #expect(found.first?.project == nil)
    }

    /// The other half of the read: a project narrows the listing, and a project with nothing in it is an empty
    /// list rather than an error.
    @Test func memoriesForAProjectComeBack() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        _ = try await backend.library.db.mutate(
            CreateProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user)
        _ = try await backend.library.db.mutate(
            UpsertSessionMutation(
                .init(memorySessionId: "host-1", platform: "claude-code", startedAt: at, slug: "musai")),
            as: MusaiActors.user)
        let id = try await backend.library.db.mutate(
            RecordMemoryForSessionMutation(
                .init(
                    kind: .decision, origin: .authored, text: "One Norvo file", slug: "musai",
                    memorySessionId: "host-1")),
            as: MusaiActors.user).createMemory.id

        let client = MusaiClient(record: backend.record(), token: BackendFixture.token)
        let found = try await client.memories(project: "musai")

        #expect(found.map(\.id) == [id])
        #expect(found.first?.project == "musai")
        #expect(found.first?.text == "One Norvo file")
        #expect(try await client.memories(project: "no-such-project").isEmpty)
    }

    /// `musai review --migrated`: the imported history has a view of its own, and the live review list is not
    /// buried under it. A migrated entry is a different type from a `Proposal` because claude-mem recorded no
    /// utterance for it, so there is no `said` to carry.
    @Test func theMigrationViewIsSeparateFromTheReviewList() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        let cwd = "/tmp/musai-client-migrated"
        let said = try await MusaiCapture(db: backend.library.db).captureUserTurn(
            text: "we will use one Norvo file", at: at, origin: "claude", session: "s1", cwd: cwd,
            as: MusaiActors.curator)
        let slug = try #require(
            try await backend.library.db.query(ProjectByRootQuery(.init(root: cwd))).projects.first?.slug)
        let live = try await backend.library.db.mutate(
            RecordProposalMutation(
                .init(title: "Live one", rationale: nil, act: .decision, utterance: said, project: slug)),
            as: MusaiActors.curator).createDecision.id
        let migrated = try await backend.library.db.mutate(
            RecordMigratedProposalUnboundMutation(
                .init(title: "Migrated one", act: .decision, origin: "claude-mem:observation:2")),
            as: MusaiActors.migrator("claude-mem")).createDecision.id

        let client = MusaiClient(record: backend.record(), token: BackendFixture.token)
        let review = try await client.proposals()
        let migration = try await client.migrated().proposals

        // The live list carries the one awaiting a decision, and never the imported one.
        #expect(review.map(\.id) == [live])
        #expect(review.map(\.title) == ["Live one"])

        // The migration view carries the imported one, with where it came from, and no `said` to fake.
        #expect(migration.map(\.id) == [migrated])
        #expect(migration.map(\.title) == ["Migrated one"])
        #expect(migration.first?.act == .decision)
        #expect(migration.first?.origin == "claude-mem:observation:2")
    }

    /// The migration view shows a page of a long import, not the whole of it: the real corpus yields ~6 900
    /// migrated proposals, so a view of 50 with nothing saying so would look like the whole backlog. The
    /// answer fetches one more than it returns — the query has no count — and says so as `hasMore`.
    @Test func theMigrationViewSaysWhenThereIsMore() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        for n in 1...2 {
            _ = try await backend.library.db.mutate(
                RecordMigratedProposalUnboundMutation(
                    .init(title: "Migrated \(n)", act: .decision, origin: "claude-mem:observation:\(n)")),
                as: MusaiActors.migrator("claude-mem"))
        }

        let client = MusaiClient(record: backend.record(), token: BackendFixture.token)

        // A bound shorter than the backlog returns exactly the bound and says there is more.
        let page = try await client.migrated(first: 1)
        #expect(page.proposals.count == 1)
        #expect(page.hasMore)

        // The default bound carries both, and says this is all of it.
        let whole = try await client.migrated()
        #expect(whole.proposals.count == 2)
        #expect(whole.hasMore == false)
    }

    /// A search narrowed to a project honours both: `?project=&q=` returns only that project's hits, rather
    /// than searching the whole store while the caller believes a filter applied.
    @Test func aSearchHonoursTheProjectItIsGiven() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        _ = try await backend.library.db.mutate(
            CreateProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user)
        _ = try await backend.library.db.mutate(
            CreateProjectMutation(.init(name: "Other", slug: "other")), as: MusaiActors.user)
        for (slug, session) in [("musai", "host-m"), ("other", "host-o")] {
            _ = try await backend.library.db.mutate(
                UpsertSessionMutation(
                    .init(memorySessionId: session, platform: "claude-code", startedAt: at, slug: slug)),
                as: MusaiActors.user)
        }
        let mine = try await backend.library.db.mutate(
            RecordMemoryForSessionMutation(
                .init(
                    kind: .fact, origin: .authored, text: "Norvo keeps one file", slug: "musai",
                    memorySessionId: "host-m")),
            as: MusaiActors.user).createMemory.id
        _ = try await backend.library.db.mutate(
            RecordMemoryForSessionMutation(
                .init(
                    kind: .fact, origin: .authored, text: "Norvo keeps one file too", slug: "other",
                    memorySessionId: "host-o")),
            as: MusaiActors.user)

        let client = MusaiClient(record: backend.record(), token: BackendFixture.token)

        // Both memories hold the word, so the whole-store search finds both...
        #expect(try await client.memories(q: "Norvo").count == 2)
        // ...and the project narrows that same search to its own hits.
        let scoped = try await client.memories(project: "musai", q: "Norvo")
        #expect(scoped.map(\.id) == [mine])
        #expect(scoped.map(\.project) == ["musai"])
    }

    /// The import is the agent's work, requested over the endpoint — never a command that opens the store
    /// itself — and one request is one pass: the CLI repeats it until a pass reports nothing left.
    @Test func theImportIsRequestedThroughTheEndpoint() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        let corpus = try ClaudeMemCorpus.thread()
        let client = MusaiClient(record: backend.record(), token: BackendFixture.token)

        let report = try await client.importHistory(from: corpus.url)

        // This corpus's one pass: one project-less session, its two observations as migrated evidence, one of
        // them also as a migrated proposal, one real prompt, and one machine payload dropped.
        #expect(
            report
                == ImportReport(
                    dryRun: false, sessions: 1, evidence: 2, prompts: 1, proposals: 1,
                    buckets: ["open-source"], unbound: 1, machinePrompts: 1))

        // It landed in the agent's store, project-less, as migrated history.
        let memory = try #require(
            try await backend.library.db.query(
                MemoryByProvenanceQuery(.init(provenance: "claude-mem:observation:1"))).memories.first)
        #expect(memory.text == "Norvo keeps one file")
        #expect(memory.origin == .migrated)
        #expect(memory.project == nil)
        #expect(memory.session?.memorySessionId == "host-1")
        // And it is findable, which is the whole point of importing it: a word nothing else in the store holds.
        #expect(try await client.memories(q: "Norvo").map(\.id) == [memory.id])

        // A second request has nothing left to do: the cursors are past this corpus, so the report is empty —
        // which is the signal `musai import` loops on until it stops.
        #expect(try await client.importHistory(from: corpus.url) == ImportReport())
    }

    @Test func aLiveHandshakeOfAnotherMajorIsRefusedEvenWhenTheRecordAgrees() async throws {
        // The record says 1.0 (the fixture's default) and the live helper answers 2.0. The helper is what would
        // store the words, so the handshake — not the record alone — is the source of truth.
        let backend = try await BackendFixture.make(protocolVersion: "2.0")
        defer { backend.close() }
        let record = backend.record()
        #expect(record.protocolVersion == EndpointWire.protocolVersion)
        let client = MusaiClient(record: record, token: BackendFixture.token)

        #expect(await client.health()?.protocolVersion == "2.0")
        await #expect(
            throws: MusaiClient.Failure.incompatibleProtocol(
                helper: "2.0", expected: EndpointWire.protocolVersion)
        ) {
            try await client.capture(turn("words a helper of another major must not store"))
        }

        let rows = try await backend.library.db.query(UtterancesForSessionQuery(.init(session: "s1"))).utterances
        #expect(rows.isEmpty)
    }
}
