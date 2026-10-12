import Foundation
import Testing
@testable import MusaiCore

@Suite struct ReviewTests {
    private func seeded() async throws -> (MusaiLibrary, UUID) {
        let lib = try await MusaiLibrary.inMemory()
        _ = try await lib.db.mutate(
            CreateProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user)
        let said = try await MusaiCapture(db: lib.db).captureUserTurn(
            text: "we will use one Norvo file", at: Date(timeIntervalSince1970: 1_700_000_000),
            origin: "claude", session: "s1", cwd: "/tmp/musai-review", as: MusaiActors.curator)
        return (lib, said)
    }

    private func proposal(_ lib: MusaiLibrary, said: UUID, title: String = "One Norvo file") async throws -> UUID {
        try await lib.db.mutate(
            RecordProposalMutation(.init(
                title: title, rationale: "Anti-clunk", act: .decision, utterance: said, project: "musai")),
            as: MusaiActors.curator).createDecision.id
    }

    @Test func pendingIsEmptyOnAFreshStore() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let review = ReviewSession(db: lib.db)
        #expect(try await review.pending().isEmpty)
        #expect(try await review.unpersisted().isEmpty)
    }

    @Test func settlePutsTheDecisionInTheGap() async throws {
        let (lib, said) = try await seeded()
        let id = try await proposal(lib, said: said)
        let review = ReviewSession(db: lib.db)
        #expect(try await review.pending().map(\.title) == ["One Norvo file"])

        try await review.apply(.settle, to: id, as: MusaiActors.user)

        #expect(try await review.pending().isEmpty)
        #expect(try await review.unpersisted().map(\.title) == ["One Norvo file"])
        let row = try await lib.db.query(DecisionByIDQuery(.init(id: id))).decision
        #expect(row?.state == .settled)
        #expect(row?.settledAt != nil)
    }

    @Test func persistTakesItOutOfTheGapAndRemembersWhereItLanded() async throws {
        let (lib, said) = try await seeded()
        let id = try await proposal(lib, said: said)
        let review = ReviewSession(db: lib.db)

        try await review.apply(.persist(documentRef: "commit:abc"), to: id, as: MusaiActors.user)

        #expect(try await review.pending().isEmpty)
        #expect(try await review.unpersisted().isEmpty)
        let row = try await lib.db.query(DecisionByIDQuery(.init(id: id))).decision
        #expect(row?.state == .persisted)
        #expect(row?.documentRef == "commit:abc")
        #expect(row?.persistedAt != nil)
    }

    @Test func dropRemovesTheProposalAndLeavesTheGapEmpty() async throws {
        let (lib, said) = try await seeded()
        let id = try await proposal(lib, said: said)
        let review = ReviewSession(db: lib.db)

        try await review.apply(.drop, to: id, as: MusaiActors.user)

        #expect(try await review.pending().isEmpty)
        #expect(try await review.unpersisted().isEmpty)
    }

    @Test func skipLeavesItPending() async throws {
        let (lib, said) = try await seeded()
        let id = try await proposal(lib, said: said)
        let review = ReviewSession(db: lib.db)

        try await review.apply(.skip, to: id, as: MusaiActors.user)

        #expect(try await review.pending().map(\.title) == ["One Norvo file"])
        #expect(try await review.unpersisted().isEmpty)
    }

    @Test func theGapIsReadableWithoutRunningTheWholeReview() async throws {
        let (lib, said) = try await seeded()
        let id = try await proposal(lib, said: said)
        let review = ReviewSession(db: lib.db)
        try await review.apply(.settle, to: id, as: MusaiActors.user)

        let gap = try await review.unpersisted()
        #expect(gap.count == 1)
        #expect(gap.first?.said == "we will use one Norvo file")
        #expect(gap.first?.settledAt != nil)
    }
}
