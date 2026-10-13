import Foundation
import Testing
@testable import MusaiCore

/// The operations the claude-mem import writes through: evidence in a bound session lands bound to its
/// project, evidence in an unbound one lands unbound and still bound to its session, migrated proposals
/// land in their own state so they never reach the live review list, and an unbound session is writable
/// at all.
@Suite struct ImportOperationsTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func seedProject(_ lib: MusaiLibrary) async throws {
        _ = try await lib.db.mutate(
            CreateProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user)
    }

    private func seedUnboundSession(_ lib: MusaiLibrary, _ memorySessionId: String) async throws {
        _ = try await lib.db.mutate(
            UpsertSessionUnboundMutation(.init(
                memorySessionId: memorySessionId, platform: "claude-code",
                cwd: "/tmp/never-a-repository", startedAt: start)),
            as: MusaiActors.migrator("claude-mem"))
    }

    @Test func aMemoryWithNoProjectIsWrittenAndBoundToItsSession() async throws {
        let lib = try await MusaiLibrary.inMemory()
        try await seedUnboundSession(lib, "s-unbound")
        _ = try await lib.db.mutate(
            RecordMemoryUnboundMutation(.init(
                kind: .fact, origin: .migrated, text: "the schema compiles",
                provenance: "claude-mem:observation:1", memorySessionId: "s-unbound")),
            as: MusaiActors.migrator("claude-mem"))

        let found = try await lib.db.query(
            MemoryByProvenanceQuery(.init(provenance: "claude-mem:observation:1"))).memories
        #expect(found.first?.project == nil)
        #expect(found.first?.session?.memorySessionId == "s-unbound")
        let projectless = try await lib.db.query(MemoriesWithoutProjectQuery()).memories
        #expect(projectless.contains { $0.provenance == "claude-mem:observation:1" })
    }

    @Test func aMemoryWithAProjectBinds() async throws {
        let lib = try await MusaiLibrary.inMemory()
        try await seedProject(lib)
        _ = try await lib.db.mutate(
            UpsertSessionMutation(.init(
                memorySessionId: "s-bound", platform: "claude-code", startedAt: start, slug: "musai")),
            as: MusaiActors.migrator("claude-mem"))
        _ = try await lib.db.mutate(
            RecordMemoryForSessionMutation(.init(
                kind: .fact, origin: .migrated, text: "one Norvo Lite file",
                provenance: "claude-mem:observation:2", slug: "musai", memorySessionId: "s-bound")),
            as: MusaiActors.migrator("claude-mem"))

        let found = try await lib.db.query(
            MemoryByProvenanceQuery(.init(provenance: "claude-mem:observation:2"))).memories
        #expect(found.first?.project?.slug == "musai")
        let projectless = try await lib.db.query(MemoriesWithoutProjectQuery()).memories
        #expect(!projectless.contains { $0.provenance == "claude-mem:observation:2" })
    }

    @Test func aMigratedProposalIsInItsOwnQueryOnly() async throws {
        let lib = try await MusaiLibrary.inMemory()
        try await seedProject(lib)
        _ = try await lib.db.mutate(
            RecordMigratedProposalMutation(.init(
                title: "One Norvo Lite file", act: .decision,
                origin: "claude-mem:observation:7", slug: "musai")),
            as: MusaiActors.migrator("claude-mem"))
        _ = try await lib.db.mutate(
            RecordMigratedProposalUnboundMutation(.init(
                title: "Never a repository", act: .decision,
                origin: "claude-mem:observation:8")),
            as: MusaiActors.migrator("claude-mem"))

        let live = try await lib.db.query(PendingDecisionsQuery()).decisions
        #expect(live.isEmpty)
        let migrated = try await lib.db.query(MigratedDecisionsQuery()).decisions
        #expect(migrated.map(\.origin) == ["claude-mem:observation:7", "claude-mem:observation:8"])
        #expect(migrated.allSatisfy { $0.state == .migrated })
        #expect(migrated.first?.project?.slug == "musai")
        #expect(migrated.last?.project == nil)
    }

    @Test func anUnboundSessionIsWritten() async throws {
        let lib = try await MusaiLibrary.inMemory()
        try await seedUnboundSession(lib, "s-lonely")

        let session = try await lib.db.query(SessionByMemoryIdQuery(.init(memorySessionId: "s-lonely"))).session
        #expect(session?.memorySessionId == "s-lonely")
        #expect(session?.project == nil)
    }
}
