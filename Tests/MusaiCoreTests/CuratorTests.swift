import Foundation
import Testing
@testable import MusaiCore

/// Proposes one decision per event, so the tests can check both the written and the skipped paths.
private struct StubDetector: DecisionDetector {
    let onEvents: @Sendable ([DetectedEvent]) -> [DetectedDecision]
    func propose(from events: [DetectedEvent]) async throws -> [DetectedDecision] { onEvents(events) }
}

private struct FailingDetector: DecisionDetector {
    struct Boom: Error {}
    func propose(from events: [DetectedEvent]) async throws -> [DetectedDecision] { throw Boom() }
}

@Suite struct CuratorTests {
    private func seeded() async throws -> MusaiLibrary {
        let lib = try await MusaiLibrary.inMemory()
        _ = try await lib.db.mutate(
            CreateProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user)
        return lib
    }

    private func twoTurns(_ lib: MusaiLibrary) async throws {
        let capture = MusaiCapture(db: lib.db)
        let texts = ["we will use one Norvo file", "yes, and no Obsidian vault"]
        for (index, text) in texts.enumerated() {
            _ = try await capture.captureUserTurn(
                text: text, at: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                origin: "claude", session: "s1", cwd: "/tmp/musai-curator", as: MusaiActors.curator)
        }
    }

    private func oneEach(_ events: [DetectedEvent]) -> [DetectedDecision] {
        events.enumerated().map { index, event in
            DetectedDecision(
                title: "Decision \(index)", rationale: nil, act: .decision, utterance: event.utterance)
        }
    }

    @Test func drainProposesAndMarksTheEventsDrained() async throws {
        let lib = try await seeded()
        try await twoTurns(lib)
        let curator = ProposalCurator(db: lib.db, detector: StubDetector(onEvents: oneEach))
        let written = try await curator.drain(as: MusaiActors.curator)

        #expect(written == 2)
        #expect(try await lib.db.query(UndrainedEventsQuery()).events.isEmpty)
        let pending = try await lib.db.query(PendingDecisionsQuery()).decisions
        #expect(pending.count == 2)
        #expect(pending.compactMap(\.utterance?.text).count == 2)
    }

    @Test func drainIsIdempotent() async throws {
        let lib = try await seeded()
        try await twoTurns(lib)
        let curator = ProposalCurator(db: lib.db, detector: StubDetector(onEvents: oneEach))
        #expect(try await curator.drain(as: MusaiActors.curator) == 2)
        #expect(try await curator.drain(as: MusaiActors.curator) == 0)
        #expect(try await lib.db.query(PendingDecisionsQuery()).decisions.count == 2)
    }

    @Test func aThrowingDetectorLeavesEveryEventForRetry() async throws {
        let lib = try await seeded()
        try await twoTurns(lib)
        let curator = ProposalCurator(db: lib.db, detector: FailingDetector())

        await #expect(throws: (any Error).self) {
            _ = try await curator.drain(as: MusaiActors.curator)
        }
        #expect(try await lib.db.query(UndrainedEventsQuery()).events.count == 2)
    }

    @Test func aProposalWithoutAUsersWordsIsSkipped() async throws {
        let lib = try await seeded()
        try await twoTurns(lib)
        let detector = StubDetector { events in
            [
                DetectedDecision(
                    title: "Kept", rationale: nil, act: .decision, utterance: events.first?.utterance),
                DetectedDecision(
                    title: "The assistant's own idea, never agreed", rationale: nil, act: .proposal,
                    utterance: nil),
            ]
        }
        let curator = ProposalCurator(db: lib.db, detector: detector)
        #expect(try await curator.drain(as: MusaiActors.curator) == 1)
        #expect(try await lib.db.query(PendingDecisionsQuery()).decisions.map(\.title) == ["Kept"])
    }

    /// Two projects, one turn captured in each: the queue is global, and every proposal files under the
    /// project of the session its event belongs to.
    @Test func theDrainFilesEachEventUnderItsOwnProject() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let capture = MusaiCapture(db: lib.db)
        _ = try await capture.captureUserTurn(
            text: "we will use one Norvo file", at: Date(timeIntervalSince1970: 1_700_000_000),
            origin: "claude", session: "s1", cwd: "/tmp/musai-one", as: MusaiActors.curator)
        _ = try await capture.captureUserTurn(
            text: "yes, and no Obsidian vault", at: Date(timeIntervalSince1970: 1_700_000_001),
            origin: "claude", session: "s2", cwd: "/tmp/musai-two", as: MusaiActors.curator)

        let written = try await ProposalCurator(db: lib.db, detector: StubDetector(onEvents: oneEach))
            .drain(as: MusaiActors.curator)
        #expect(written == 2)

        let decisions = try await lib.db.query(PendingDecisionsQuery()).decisions
        let byWords = Dictionary(uniqueKeysWithValues: decisions.map { ($0.utterance?.text ?? "", $0.project?.slug) })
        #expect(byWords["we will use one Norvo file"] == "musai-one")
        #expect(byWords["yes, and no Obsidian vault"] == "musai-two")
    }

    /// A crash outside the transaction left a decision filed but its event still queued. The event's id is
    /// the decision's origin, so the replay files the event's decision as wasted work, not a duplicate.
    @Test func aReplayedDrainDoesNotFileASecondDecisionForTheSameOrigin() async throws {
        let lib = try await seeded()
        try await twoTurns(lib)

        let first = try #require(try await lib.db.query(UndrainedEventsQuery()).events.first)
        let session = try #require(first.session?.memorySessionId)
        let slug = try #require(first.session?.project?.slug)
        let utterances = try await lib.db.query(UtterancesForSessionQuery(.init(session: session))).utterances
        let utterance = try #require(utterances.first { $0.text == first.text })
        _ = try await lib.db.mutate(
            RecordProposalMutation(
                .init(
                    title: "Already filed", rationale: nil, act: .decision, utterance: utterance.id,
                    project: slug, origin: first.id.uuidString)),
            as: MusaiActors.curator)

        let written = try await ProposalCurator(db: lib.db, detector: StubDetector(onEvents: oneEach))
            .drain(as: MusaiActors.curator)
        #expect(written == 1)  // the second event files; the first is already done
        #expect(try await lib.db.query(PendingDecisionsQuery()).decisions.count == 2)
    }
}
