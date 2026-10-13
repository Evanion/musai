import Foundation
import Testing
@testable import MusaiCore

/// The endpoint's memory surfaces, driven as the router they are. The tests that can only be asked directly
/// live here — a storeless endpoint, an endpoint told its store is somewhere that does not exist, the empty
/// answer of each `/memories` branch — while the answers a client reaches are exercised over a real socket in
/// `ClientTests`, so the client methods have coverage on both sides of the wire.
@Suite struct MemoryEndpointTests {
    private static let token = "a-token-memory-endpoint-tests-chose"

    /// A file-backed store, a state that knows its path — or, for the opener rule, one told a path that is not
    /// where the store is — and a curator whose debounce is parked, so no drain runs mid-test.
    private struct Backend {
        let library: MusaiLibrary
        let endpoint: MusaiEndpoint
        let store: URL
        let directory: URL

        func close() {
            library.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func made(storePath: String? = nil) async throws -> Backend {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-memory-endpoint-\(UUID().uuidString)")
        let store = directory.appending(path: "Musai.norvo")
        let library = try await MusaiLibrary.open(at: store)
        let controller = CuratorController(
            db: library.db, detector: SilentDetector(),
            sleep: { _ in try? await Task.sleep(for: .seconds(3_600)) }, debounce: 1)
        let endpoint = MusaiEndpoint(
            store: .open(db: library.db, library: library),
            state: EndpointState(storePath: storePath ?? store.path), curator: controller, token: Self.token)
        return Backend(library: library, endpoint: endpoint, store: store, directory: directory)
    }

    private func request(
        _ method: String, _ path: String, query: [String: String] = [:], body: Data = Data(),
        token: String = MemoryEndpointTests.token
    ) -> EndpointRequest {
        EndpointRequest(method: method, path: path, query: query, body: body, token: token)
    }

    private func importBody(_ source: URL, dryRun: Bool? = nil) throws -> Data {
        struct Body: Encodable {
            let source: String
            let dryRun: Bool?
        }
        return try EndpointWire.encoder().encode(Body(source: source.path, dryRun: dryRun))
    }

    /// The report this corpus's one pass writes: one project-less session, its two observations as migrated
    /// evidence, one of them also as a migrated proposal, one real prompt and one machine payload dropped.
    private func expectedReport(_ dryRun: Bool) -> ImportReport {
        ImportReport(
            dryRun: dryRun, sessions: 1, evidence: 2, prompts: 1, proposals: 1, buckets: ["open-source"],
            unbound: 1, machinePrompts: 1)
    }

    @Test func anEmptySearchIsEmptyNotAnError() async throws {
        let backend = try await made()
        defer { backend.close() }

        // A search that matches nothing is an answer, not an error.
        let miss = await backend.endpoint.respond(
            to: request("GET", "/memories", query: ["q": "nothing-matches-these-words"]))
        #expect(miss.status == 200)
        #expect(try EndpointWire.decoder().decode(MemoriesReply.self, from: miss.body).memories.isEmpty)

        // So is a project the store has never heard of, and an unfiltered listing of an empty store.
        let unknown = await backend.endpoint.respond(
            to: request("GET", "/memories", query: ["project": "no-such-project"]))
        #expect(unknown.status == 200)
        #expect(try EndpointWire.decoder().decode(MemoriesReply.self, from: unknown.body).memories.isEmpty)

        let bare = await backend.endpoint.respond(to: request("GET", "/memories"))
        #expect(bare.status == 200)
        #expect(try EndpointWire.decoder().decode(MemoriesReply.self, from: bare.body).memories.isEmpty)
    }

    @Test func theImportIsRefusedWhenItWouldBeASecondOpener() async throws {
        let corpus = try ClaudeMemCorpus.thread()
        let elsewhere = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-memory-endpoint-\(UUID().uuidString)/Musai.norvo")
        defer { try? FileManager.default.removeItem(at: elsewhere.deletingLastPathComponent()) }

        // An endpoint with no store refuses the import rather than opening one of its own — and it leaves
        // nothing behind, not even the directory it was told its store would be in.
        let storeless = MusaiEndpoint(
            store: .none, state: EndpointState(storePath: elsewhere.path), token: Self.token)
        let refused = await storeless.respond(
            to: request("POST", "/admin/import", body: try importBody(corpus.url)))
        #expect(refused.status == 503)
        #expect(!FileManager.default.fileExists(atPath: elsewhere.deletingLastPathComponent().path))

        // The token still comes first: a stranger learns nothing, not even that there is no store.
        let stranger = await storeless.respond(
            to: request("POST", "/admin/import", body: try importBody(corpus.url), token: "an-impostor"))
        #expect(stranger.status == 401)

        // And when it does have a store, it imports through it. The endpoint is told its store is somewhere
        // that does not exist, which is the one thing a route that opened the file itself would have to obey:
        // it succeeds anyway, and every row lands in the store the agent is holding.
        let backend = try await made(storePath: elsewhere.path)
        defer { backend.close() }
        let response = await backend.endpoint.respond(
            to: request("POST", "/admin/import", body: try importBody(corpus.url)))
        #expect(response.status == 200)
        let report = try EndpointWire.decoder().decode(ImportReportReply.self, from: response.body).report
        #expect(report == expectedReport(false))
        let memory = try await backend.library.db.query(
            MemoryByProvenanceQuery(.init(provenance: "claude-mem:observation:1"))).memories.first
        #expect(memory?.text == "Norvo keeps one file")
        #expect(memory?.session?.memorySessionId == "host-1")
        #expect(!FileManager.default.fileExists(atPath: elsewhere.path))
    }

    @Test func aDryRunImportWritesNothing() async throws {
        let backend = try await made()
        defer { backend.close() }
        let corpus = try ClaudeMemCorpus.thread()

        let dry = await backend.endpoint.respond(
            to: request("POST", "/admin/import", body: try importBody(corpus.url, dryRun: true)))
        #expect(dry.status == 200)
        let report = try EndpointWire.decoder().decode(ImportReportReply.self, from: dry.body).report
        // The numbers are what a real run would do — discovery's verdict included, which a person wants to see
        // before anything is kept.
        #expect(report == expectedReport(true))

        // And none of it is in the store: no session, no memory, no utterance, no proposal, no cursor.
        #expect(
            try await backend.library.db.query(SessionByMemoryIdQuery(.init(memorySessionId: "host-1")))
                .session == nil)
        #expect(
            try await backend.library.db.query(
                MemoryByProvenanceQuery(.init(provenance: "claude-mem:observation:1"))).memories.isEmpty)
        #expect(try await backend.library.db.query(MemoriesWithoutProjectQuery()).memories.isEmpty)
        #expect(
            try await backend.library.db.query(UtterancesForSessionQuery(.init(session: "host-1"))).utterances
                .isEmpty)
        #expect(try await backend.library.db.query(MigratedDecisionsQuery()).decisions.isEmpty)
        #expect(try await backend.library.db.query(AllProjectsQuery()).projects.isEmpty)
        #expect(
            try await backend.library.db.query(ImportCursorQuery(.init(source: "claude-mem:sessions")))
                .importCursor == nil)

        // The numbers were true: the same request without the dry run writes exactly them — a dry run moved no
        // cursor, so nothing was left half-done for the real run to resume past.
        let real = await backend.endpoint.respond(
            to: request("POST", "/admin/import", body: try importBody(corpus.url)))
        #expect(real.status == 200)
        let written = try EndpointWire.decoder().decode(ImportReportReply.self, from: real.body).report
        #expect(written == expectedReport(false))
        #expect(
            try await backend.library.db.query(
                MemoryByProvenanceQuery(.init(provenance: "claude-mem:observation:1"))).memories.first?.origin
                == .migrated)
    }
}
