import Foundation
import Testing
@testable import MusaiCore

@Suite struct LoopSchemaTests {
    @Test func theLoopsTypesMigrateAndRoundTrip() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let sdl = try await lib.db.schema()
        for type in ["Utterance", "Event", "Decision"] {
            #expect(sdl.contains("type \(type)"))
        }
        #expect(
            NorvoSchema.migrations.map(\.name) == [
                "0001_init", "0002_loop", "0003_decision_required", "0004_event_expiry",
                "0005_migrated_state", "0006_import_cursor",
            ])

        _ = try await lib.db.mutate(
            CreateProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user)
        _ = try await lib.db.mutate(
            UpsertSessionMutation(.init(
                memorySessionId: "s1", platform: "claude", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                slug: "musai")),
            as: MusaiActors.curator)
        _ = try await lib.db.mutate(
            RecordUtteranceMutation(.init(
                text: "I said that I want to Read the post", at: Date(timeIntervalSince1970: 1_700_000_001),
                speaker: .user, session: "s1")),
            as: MusaiActors.curator)
        _ = try await lib.db.mutate(
            RecordEventMutation(.init(
                kind: .toolUse, at: Date(timeIntervalSince1970: 1_700_000_002),
                tool: "Edit", target: "Sources/MusaiCore/ProjectBinder.swift", digest: "sha256:abc",
                session: "s1")),
            as: MusaiActors.curator)

        let utterances = try await lib.db.query(UtterancesForSessionQuery(.init(session: "s1"))).utterances
        #expect(utterances.map(\.text) == ["I said that I want to Read the post"])
        #expect(utterances.first?.speaker == .user)
        let events = try await lib.db.query(UndrainedEventsQuery()).events
        #expect(events.count == 1)
        #expect(events.first?.tool == "Edit")
        #expect(events.first?.text == nil)
    }
}
