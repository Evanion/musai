import Foundation
import Testing
@testable import MusaiCore

@Suite struct MemoryTests {
    private func seedProject(_ lib: MusaiLibrary) async throws -> UUID {
        try await lib.db.mutate(
            CreateProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user).createProject.id
    }

    @Test func memoriesAttachToTheThingTheyAreAbout() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let subject = try await seedProject(lib)
        let memory = try await lib.db.mutate(
            RecordMemoryMutation(.init(kind: .decision, origin: .authored, text: "One Lite file", slug: "musai")),
            as: MusaiActors.user).createMemory.id
        _ = try await lib.db.mutate(
            AttachMemoryToSubjectMutation(.init(id: memory, subject: subject)), as: MusaiActors.user)

        let found = try await lib.db.query(MemoryByIDQuery(.init(id: memory))).memory
        #expect(found?.subject?.id == subject)
        #expect(found?.origin == .authored)
    }

    @Test func anAmbientMemoryCarriesProvenanceAndItsSession() async throws {
        let lib = try await MusaiLibrary.inMemory()
        _ = try await seedProject(lib)
        _ = try await lib.db.mutate(
            UpsertSessionMutation(.init(
                memorySessionId: "s9", platform: "test",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000), slug: "musai")),
            as: MusaiActors.curator)
        let memory = try await lib.db.mutate(
            RecordMemoryMutation(.init(
                kind: .fact, origin: .ambient, text: "the schema compiles",
                provenance: "event/42", slug: "musai")),
            as: MusaiActors.curator).createMemory.id
        _ = try await lib.db.mutate(
            SetMemorySessionMutation(.init(id: memory, memorySessionId: "s9")), as: MusaiActors.curator)

        let found = try await lib.db.query(MemoryByProvenanceQuery(.init(provenance: "event/42"))).memories
        #expect(found.first?.session?.memorySessionId == "s9")
    }

    @Test func emptyAndLongAndUnicodeTextRoundTrip() async throws {
        let lib = try await MusaiLibrary.inMemory()
        _ = try await seedProject(lib)
        let long = String(repeating: "記憶 ", count: 2_000)
        _ = try await lib.db.mutate(
            RecordMemoryMutation(.init(kind: .fact, origin: .authored, text: "", slug: "musai")),
            as: MusaiActors.user)
        _ = try await lib.db.mutate(
            RecordMemoryMutation(.init(kind: .fact, origin: .authored, text: long, slug: "musai")),
            as: MusaiActors.user)
        let all = try await lib.db.query(MemoriesOfKindQuery(.init(kind: .fact))).memories
        #expect(all.count == 2)
        #expect(all.contains { $0.text == long })
    }

    @Test func decisionsAreAuthoredWithTheirRationale() async throws {
        let lib = try await MusaiLibrary.inMemory()
        _ = try await seedProject(lib)
        let decision = try await lib.db.mutate(
            RecordDecisionMutation(.init(
                title: "One file", rationale: "Anti-clunk and anti-weight", act: .decision, slug: "musai")),
            as: MusaiActors.user).createDecision.id
        _ = try await lib.db.mutate(
            AttachDecisionToSubjectMutation(.init(id: decision, subject: decision)), as: MusaiActors.user)
        let decisions = try await lib.db.query(DecisionsForProjectQuery(.init(slug: "musai"))).decisions
        #expect(decisions.first?.title == "One file")
        #expect(decisions.first?.subject?.id == decision)
    }
}
