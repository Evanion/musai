import Foundation
import Testing
@testable import MusaiCore
@testable import musai

/// The ideas surface: what the first run discovered, listed — and, at last, correctable.
///
/// An idea is what discovery makes of a corpus label that named no working tree; before this the dry-run
/// report showed them and nothing shipped could act on one. The routes are exercised through the real client
/// and the verb through `Ideas`, so both sides of the wire are covered, and the store is always a temp one
/// this suite makes and removes.
@Suite struct IdeaTests {
    private static let token = "a-token-idea-tests-chose"

    /// An idea for a project, the shape a live `CreateIdea` makes.
    @discardableResult
    private func idea(_ backend: BackendFixture, title: String, slug: String) async throws -> UUID {
        _ = try await backend.library.db.mutate(
            CreateProjectMutation(.init(name: slug.capitalized, slug: slug)), as: MusaiActors.user)
        return try await backend.library.db.mutate(
            CreateIdeaMutation(.init(title: title, slug: slug)), as: MusaiActors.user).createIdea.id
    }

    /// A loose idea, the shape discovery makes from a label that named no working tree — which is most of
    /// what the first run leaves behind.
    @discardableResult
    private func looseIdea(_ backend: BackendFixture, title: String) async throws -> UUID {
        try await backend.library.db.mutate(
            CreateLooseIdeaMutation(.init(title: title)), as: MusaiActors.migrator("claude-mem")).createIdea.id
    }

    /// An idea lists for its project, and the unfiltered listing carries the loose ones too — the whole
    /// reason the surface exists, because discovery's ideas have no project at all.
    @Test func anIdeaListsForItsProject() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        let bound = try await idea(backend, title: "A workspace with memory", slug: "musai")
        let loose = try await looseIdea(backend, title: "a-thread")
        let client = MusaiClient(record: backend.record(), token: BackendFixture.token)

        let mine = try await client.ideas(project: "musai")
        #expect(mine.map(\.id) == [bound])
        #expect(mine.first?.project == "musai")
        #expect(mine.first?.status == .open)

        // A project nobody discovered has no ideas, and says so as an empty list rather than an error.
        #expect(try await client.ideas(project: "no-such-project").isEmpty)

        let all = try await client.ideas()
        #expect(Set(all.map(\.id)) == Set([bound, loose]))
        #expect(all.first { $0.id == loose }?.project == nil)
    }

    /// A dropped idea is deleted: nothing references an idea, so there is nothing to leave dangling.
    @Test func droppingAnIdeaRemovesIt() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        let id = try await looseIdea(backend, title: "a-thread")
        let client = MusaiClient(record: backend.record(), token: BackendFixture.token)

        let reply = try await client.drop(idea: id)

        #expect(reply.status == .dropped)
        #expect(reply.title == "a-thread")
        #expect(try await backend.library.db.query(AllIdeasQuery()).ideas.isEmpty)
        #expect(try await client.ideas().isEmpty)
    }

    /// A promote is the data model's own arc — the idea becomes the project it was pointing at — and the
    /// reply names the project so the person is told what happened.
    @Test func promotingAnIdeaMakesItAProject() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        let id = try await looseIdea(backend, title: "a-thread")
        let client = MusaiClient(record: backend.record(), token: BackendFixture.token)

        let reply = try await client.promote(idea: id)

        #expect(reply.status == .promoted)
        #expect(reply.spawnedProject == "a-thread")
        let project = try #require(
            try await backend.library.db.query(ProjectBySlugQuery(.init(slug: "a-thread"))).project)
        #expect(project.name == "a-thread")
        let stored = try #require(try await backend.library.db.query(AllIdeasQuery()).ideas.first { $0.id == id })
        #expect(stored.status == .promoted)
        #expect(stored.spawnedProject?.slug == "a-thread")
    }

    /// An id nothing holds is a 404 that names what was missing — a fact, never a crash.
    @Test func anUnknownIdeaIdIsReportedNotACrash() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        let client = MusaiClient(record: backend.record(), token: BackendFixture.token)

        do {
            _ = try await client.drop(idea: UUID())
            Issue.record("dropping an idea the store has never heard of should have failed")
        } catch let failure as MusaiClient.Failure {
            guard case .unexpectedStatus(let status, let body) = failure else {
                Issue.record("unexpected failure: \(failure)")
                return
            }
            #expect(status == 404)
            #expect(body.contains("no such idea"))
        }
    }

    /// The new routes inherit the router's shape: the token first, the store guard second, one line and no
    /// crash when the store is not there.
    @Test func theIdeasRoutesKeepTheRoutersGuards() async throws {
        let storeless = MusaiEndpoint(
            store: .none, state: EndpointState(storePath: "/tmp/musai-ideas-nowhere/Musai.norvo"),
            token: Self.token)

        // The token comes first: a stranger learns nothing, not even that there is no store.
        let stranger = await storeless.respond(
            to: EndpointRequest(method: "GET", path: "/ideas", token: "an-impostor"))
        #expect(stranger.status == 401)

        // With the right token and no store, every ideas route says why in one line rather than a 500.
        for (method, path) in [
            ("GET", "/ideas"),
            ("POST", "/ideas/\(UUID().uuidString)/drop"),
            ("POST", "/ideas/\(UUID().uuidString)/promote"),
        ] {
            let response = await storeless.respond(
                to: EndpointRequest(method: method, path: path, token: Self.token))
            #expect(response.status == 503)
        }
    }

    /// `AllIdeas` gained a `$first` for the ideas listing, and discovery reads the *same* query to tell what
    /// the corpus has already named — so the bound must not be a default one. This pins the read a caller
    /// that leaves it out gets: everything, which is what keeps a re-run from filing an idea it already
    /// holds once the store has more ideas than the listing's own bound.
    @Test func theIdeasQueryHasNoDefaultBound() async throws {
        let lib = try await MusaiLibrary.inMemory()
        for n in 1...201 {
            _ = try await lib.db.mutate(
                CreateLooseIdeaMutation(.init(title: "idea \(n)")), as: MusaiActors.migrator("claude-mem"))
        }

        #expect(try await lib.db.query(AllIdeasQuery()).ideas.count == 201)
    }

    /// `musai ideas` prints what the first run discovered, one idea a line, and where each one sits.
    @Test func ideasListsWhatDiscoveryMade() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        try await looseIdea(backend, title: "a-thread")
        try await idea(backend, title: "A workspace with memory", slug: "musai")
        let client = MusaiClient(record: backend.record(), token: BackendFixture.token)

        var out: [String] = []
        var err: [String] = []
        await Ideas(arguments: [], connect: { client }, write: { out.append($0) }, diagnose: { err.append($0) })
            .run()

        #expect(err.isEmpty)
        #expect(out.first == "2 ideas:")
        #expect(out.contains { $0.contains("a-thread") && $0.contains("no project") })
        #expect(out.contains { $0.contains("A workspace with memory") && $0.contains("musai") })
    }

    /// `musai ideas --drop <id>` deletes one and `--promote <id>` turns one into a project, each saying in
    /// one line what it did.
    @Test func ideasDropsAndPromotesById() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        let noise = try await looseIdea(backend, title: "noise")
        let thread = try await looseIdea(backend, title: "a-thread")
        let client = MusaiClient(record: backend.record(), token: BackendFixture.token)

        var out: [String] = []
        await Ideas(
            arguments: ["--drop", noise.uuidString], connect: { client }, write: { out.append($0) },
            diagnose: { _ in }
        ).run()
        #expect(out == ["musai: dropped \"noise\""])
        #expect(try await backend.library.db.query(AllIdeasQuery()).ideas.map(\.title) == ["a-thread"])

        out = []
        await Ideas(
            arguments: ["--promote", thread.uuidString], connect: { client }, write: { out.append($0) },
            diagnose: { _ in }
        ).run()
        #expect(out == ["musai: \"a-thread\" is now project \"a-thread\""])
        #expect(try await backend.library.db.query(ProjectBySlugQuery(.init(slug: "a-thread"))).project != nil)
    }

    /// An unknown id is reported in one stderr line, and the verb still exits 0.
    @Test func ideasReportsAnUnknownIdWithoutCrashing() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        let client = MusaiClient(record: backend.record(), token: BackendFixture.token)

        var out: [String] = []
        var err: [String] = []
        await Ideas(
            arguments: ["--drop", UUID().uuidString], connect: { client }, write: { out.append($0) },
            diagnose: { err.append($0) }
        ).run()

        #expect(out.isEmpty)
        #expect(err.count == 1)
        #expect(err.first?.contains("no such idea") == true)
    }

    /// A missing backend is the same one line every other command reports, on stderr, and nothing on stdout.
    @Test func ideasNeedsARunningBackendAndSaysSo() async throws {
        var out: [String] = []
        var err: [String] = []
        await Ideas(arguments: [], connect: { nil }, write: { out.append($0) }, diagnose: { err.append($0) })
            .run()

        #expect(out.isEmpty)
        #expect(err.count == 1)
        #expect(err.first?.contains("musai install") == true)
    }
}
