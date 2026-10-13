import Foundation
import Testing
import MusaiCore
@testable import musai

/// The live review loop — the one `musai review` actually runs — driven by scripted input against the
/// in-process backend, so it is proven rather than merely written.
@Suite struct ReviewLoopTests {
    /// A pending proposal in the fixture's store, and its id.
    private func pending(in backend: BackendFixture, title: String = "One Norvo file") async throws -> UUID {
        let cwd = "/tmp/musai-review-loop"
        let said = try await MusaiCapture(db: backend.library.db).captureUserTurn(
            text: "we will use one Norvo file", at: Date(timeIntervalSince1970: 1_700_000_000),
            origin: "claude", session: "s1", cwd: cwd, as: MusaiActors.curator)
        let slug = try #require(
            try await backend.library.db.query(ProjectByRootQuery(.init(root: cwd))).projects.first?.slug)
        return try await backend.library.db.mutate(
            RecordProposalMutation(
                .init(title: title, rationale: "Anti-clunk", act: .decision, utterance: said, project: slug)),
            as: MusaiActors.curator).createDecision.id
    }

    @Test func reviewConfirmsAProposalAndRecordsWhereItLanded() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        let id = try await pending(in: backend)
        let client = MusaiClient(record: backend.record(), token: BackendFixture.token)

        var input = ["r", "commit:abc"]
        var lines: [String] = []
        let review = Review(
            client: client,
            read: { input.isEmpty ? nil : input.removeFirst() },
            write: { lines.append($0) })
        await review.run()

        #expect(lines.contains { $0.contains("One Norvo file") })
        let row = try await backend.library.db.query(DecisionByIDQuery(.init(id: id))).decision
        #expect(row?.state == .persisted)
        #expect(row?.documentRef == "commit:abc")
        #expect(try await client.proposals().isEmpty)
        #expect(try await client.gap().isEmpty)
    }

    @Test func reviewSaysNothingPendingOnAnEmptyStore() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        let client = MusaiClient(record: backend.record(), token: BackendFixture.token)

        var lines: [String] = []
        await Review(client: client, read: { nil }, write: { lines.append($0) }).run()

        #expect(lines == ["nothing pending"])
    }

    @Test func reviewShowsTheGapItWasNeverToldAbout() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        let id = try await pending(in: backend)
        let client = MusaiClient(record: backend.record(), token: BackendFixture.token)
        // Settle it, so it is a gap: recorded nowhere, and the first thing review must surface.
        try await client.apply(.settle, to: id)

        var lines: [String] = []
        await Review(client: client, read: { nil }, write: { lines.append($0) }).run()

        #expect(lines.contains { $0.contains("settled and never recorded anywhere") })
        #expect(lines.contains { $0.contains("One Norvo file") })
    }
}
