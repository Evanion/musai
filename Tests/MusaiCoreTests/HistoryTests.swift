import Foundation
import Testing
@testable import MusaiCore

@Suite struct HistoryTests {
    @Test func everyChangeNamesItsActorAndOldValue() async throws {
        let lib = try await MusaiLibrary.inMemory()
        _ = try await lib.db.mutate(
            CreateProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user)
        let spec = try await lib.db.mutate(
            CreateSpecMutation(.init(title: "Musai design", kind: .design, body: "first", position: 1, slug: "musai")),
            as: MusaiActors.user).createSpec.id
        _ = try await lib.db.mutate(
            SetSpecBodyMutation(.init(id: spec, body: "second")), as: MusaiActors.migrator("claude-mem"))

        let entries = try await lib.db.query(SpecHistoryQuery(.init(id: spec))).spec?.history.edges ?? []
        guard let latest = entries.first, entries.count >= 2 else {
            Issue.record("expected at least two history entries, got \(entries.count)")
            return
        }
        #expect(latest.node.fields.body?.new == "second")
        #expect(latest.node.fields.body?.old == "first")
        #expect(latest.node.actor?.name == "migration:claude-mem")

        let authored = entries.last
        #expect(authored?.node.actor?.name == "user")
        #expect(authored?.node.fields.body?.old != "second")
    }

    @Test func historyOfADeletedEntitySurvives() async throws {
        let lib = try await MusaiLibrary.inMemory()
        _ = try await lib.db.mutate(
            CreateProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user)
        let memory = try await lib.db.mutate(
            RecordMemoryMutation(.init(kind: .decision, origin: .authored, text: "keep it", slug: "musai")),
            as: MusaiActors.user).createMemory.id
        _ = try await lib.db.mutate(DeleteMemoryMutation(.init(id: memory)), as: MusaiActors.user)

        // A deleted entity is gone from the read path, but the deleted list still names it.
        let gone = try await lib.db.query(MemoryByIDQuery(.init(id: memory))).memory
        #expect(gone?.id == nil)
        let deleted = try await lib.db.query(DeletedMemoriesQuery()).deletedMemories
        #expect(deleted.contains { $0.id == memory })

        // Restoring re-creates it from history, so the original change is still there.
        _ = try await lib.db.mutate(RestoreMemoryMutation(.init(id: memory)), as: MusaiActors.user)
        let back = try await lib.db.query(MemoryByIDQuery(.init(id: memory))).memory
        #expect(back?.text == "keep it")
        let entries = try await lib.db.query(MemoryHistoryQuery(.init(id: memory))).memory?.history.edges ?? []
        #expect(entries.contains { $0.node.fields.text?.new == "keep it" })
    }
}
