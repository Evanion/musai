import Foundation
import Testing
@testable import MusaiCore

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
