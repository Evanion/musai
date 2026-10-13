import Foundation
import Testing
@testable import MusaiCore

@Suite struct SliceTests {
    private func seeded() async throws -> MusaiLibrary {
        let lib = try await MusaiLibrary.inMemory()
        _ = try await lib.db.mutate(
            CreateProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user)
        return lib
    }

    private func utterance(_ lib: MusaiLibrary) async throws -> UUID {
        let capture = MusaiCapture(db: lib.db)
        return try await capture.captureUserTurn(
            text: "we will use one Norvo file", at: Date(timeIntervalSince1970: 1_700_000_000),
            origin: "claude", session: "s1", cwd: "/tmp/musai-slice", as: MusaiActors.curator)
    }

    /// A session as the claude-mem import writes one: bound to `musai`, with the moment it began.
    private func session(_ lib: MusaiLibrary, _ id: String, startedAt: Date) async throws {
        _ = try await lib.db.mutate(
            UpsertSessionMutation(.init(
                memorySessionId: id, platform: "claude-code", startedAt: startedAt, slug: "musai")),
            as: MusaiActors.migrator("claude-mem"))
    }

    private func memory(
        _ lib: MusaiLibrary, _ text: String, provenance: String, session id: String
    ) async throws {
        _ = try await lib.db.mutate(
            RecordMemoryForSessionMutation(.init(
                kind: .fact, origin: .migrated, text: text, provenance: provenance,
                slug: "musai", memorySessionId: id)),
            as: MusaiActors.migrator("claude-mem"))
    }

    /// A settled decision with a landing place, so a slice has something to render besides memories.
    private func settled(_ lib: MusaiLibrary) async throws {
        let said = try await utterance(lib)
        let id = try await lib.db.mutate(
            RecordProposalMutation(.init(
                title: "One Norvo file", rationale: "Anti-clunk", act: .decision,
                utterance: said, project: "musai")),
            as: MusaiActors.curator).createDecision.id
        _ = try await lib.db.mutate(
            PersistDecisionOutsideMutation(
                .init(id: id, documentRef: "commit:abc", persistedAt: Date())),
            as: MusaiActors.user)
    }

    @Test func anEmptyStoreRendersNothing() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let text = try await MusaiSlice.render(project: "musai", budget: 2_000, db: lib.db)
        #expect(text == nil)
    }

    @Test func onlySettledOrPersistedDecisionsAreHandedOver() async throws {
        let lib = try await seeded()
        let said = try await utterance(lib)
        let settled = try await lib.db.mutate(
            RecordProposalMutation(.init(
                title: "One Norvo file", rationale: "Anti-clunk", act: .decision,
                utterance: said, project: "musai")),
            as: MusaiActors.curator).createDecision.id
        _ = try await lib.db.mutate(
            PersistDecisionOutsideMutation(
                .init(id: settled, documentRef: "commit:abc", persistedAt: Date())),
            as: MusaiActors.user)
        _ = try await utterance(lib)
        _ = try await lib.db.mutate(
            RecordProposalMutation(.init(
                title: "A stray proposal", rationale: nil, act: .proposal,
                utterance: said, project: "musai")),
            as: MusaiActors.curator)
        let plan = try await lib.db.mutate(
            CreatePlanMutation(.init(title: "Data model", slug: "musai")), as: MusaiActors.user).createPlan.id
        let task = try await lib.db.mutate(
            CreateTaskMutation(.init(title: "Write the schema", plan: plan, slug: "musai")),
            as: MusaiActors.user).createTask.id
        _ = try await lib.db.mutate(
            SetTaskStatusMutation(.init(id: task, status: .doing)), as: MusaiActors.user)

        let text = try await MusaiSlice.render(project: "musai", budget: 2_000, db: lib.db)
        #expect(text?.contains("One Norvo file") == true)
        #expect(text?.contains("commit:abc") == true)
        #expect(text?.contains("A stray proposal") == false)
        #expect(text?.contains("Write the schema") == true)
    }

    @Test func theSliceRespectsItsBudget() async throws {
        let lib = try await seeded()
        let said = try await utterance(lib)
        for index in 0..<40 {
            let id = try await lib.db.mutate(
                RecordProposalMutation(.init(
                    title: String(repeating: "long title \(index) ", count: 8), rationale: nil,
                    act: .decision, utterance: said, project: "musai")),
                as: MusaiActors.curator).createDecision.id
            _ = try await lib.db.mutate(
                PersistDecisionOutsideMutation(
                    .init(id: id, documentRef: "commit:\(index)", persistedAt: Date())),
                as: MusaiActors.user)
        }
        let text = try await MusaiSlice.render(project: "musai", budget: 1_200, db: lib.db)
        #expect((text?.utf8.count ?? 0) <= 1_200)
        #expect(text?.contains("more") == true)
    }

    @Test func theSliceCarriesTheProjectsMemory() async throws {
        let lib = try await seeded()
        try await settled(lib)
        // The newer session's memory is written first, so write order and session order disagree: only
        // `startedAt` — not `createdAt`, which for a migrated row is the import's clock — puts the corpus
        // the right way round. The last row is written without a session at all, and it sorts last rather
        // than jumping the queue.
        try await session(lib, "s-new", startedAt: Date(timeIntervalSince1970: 1_700_003_600))
        try await memory(
            lib, "The flaky import was SQLite's epoch handling\n- pin the integer literal",
            provenance: "claude-mem:observation:1", session: "s-new")
        try await session(lib, "s-old", startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await memory(
            lib, "The store began as one Norvo file",
            provenance: "claude-mem:observation:2", session: "s-old")
        _ = try await lib.db.mutate(
            RecordMemoryMutation(.init(
                kind: .fact, origin: .ambient, text: "Nobody's session claimed this",
                provenance: "curator:drain:1", slug: "musai")),
            as: MusaiActors.curator)

        let text = try await MusaiSlice.render(project: "musai", budget: 2_000, db: lib.db)
        let rendered = try #require(text)
        #expect(rendered.contains("The flaky import was SQLite's epoch handling"))
        #expect(rendered.contains("The store began as one Norvo file"))
        // The marker is the only thing telling a remembered fact from a settled decision in the same bullet
        // list; dropping it renders identically but hands the agent a different thing.
        #expect(rendered.contains("(remembered)"))
        #expect(rendered.utf8.count <= 2_000)
        let newer = try #require(rendered.range(of: "The flaky import was SQLite's epoch handling"))
        let older = try #require(rendered.range(of: "The store began as one Norvo file"))
        let sessionless = try #require(rendered.range(of: "Nobody's session claimed this"))
        #expect(newer.lowerBound < older.lowerBound)
        #expect(older.lowerBound < sessionless.lowerBound)
    }

    @Test func theSliceStillStaysInsideItsBudget() async throws {
        let lib = try await seeded()
        try await session(lib, "s-budget", startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        for index in 0..<200 {
            try await memory(
                lib, String(repeating: "long memory \(index) ", count: 8),
                provenance: "claude-mem:observation:\(index)", session: "s-budget")
        }

        let text = try await MusaiSlice.render(project: "musai", budget: 1_200, db: lib.db)
        let rendered = try #require(text)
        #expect(rendered.utf8.count <= 1_200)
        #expect(rendered.hasSuffix("more)"))
    }

    /// The read is bounded, not the whole project: with more memories than the window holds, the slice can
    /// only ever consider `sliceMemoryWindow` of them. The proof needs no knowledge of *which* rows the query's
    /// `createdAt` order keeps — only that everything the render shows or counts came out of that one window,
    /// so shown + omitted cannot exceed it however many memories the project holds.
    @Test func theSliceReadsOnlyItsMemoryWindow() async throws {
        let lib = try await seeded()
        try await session(lib, "s-corpus", startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        for index in 0..<250 {
            try await memory(
                lib, String(repeating: "long memory \(index) ", count: 8),
                provenance: "claude-mem:observation:\(index)", session: "s-corpus")
        }

        let text = try await MusaiSlice.render(project: "musai", budget: 1_200, db: lib.db)
        let rendered = try #require(text)
        let bulleted = rendered.split(separator: "\n").filter { $0.hasPrefix("- ") }.count
        let omitted = try #require(
            rendered.split(separator: "\n").last.flatMap { line in
                line.hasPrefix("(+") && line.hasSuffix(" more)") ? Int(line.dropFirst(2).dropLast(6)) : nil
            })
        #expect(bulleted + omitted == MusaiSlice.sliceMemoryWindow)
    }

    /// Not a red-then-green test: this is the guard that a project with nothing remembered renders the
    /// very bytes it did before the slice carried memory — no blank line, no header, no stray bullet.
    @Test func aProjectWithNoMemoriesRendersAsBefore() async throws {
        let lib = try await seeded()
        try await settled(lib)
        let plan = try await lib.db.mutate(
            CreatePlanMutation(.init(title: "Data model", slug: "musai")), as: MusaiActors.user).createPlan.id
        let task = try await lib.db.mutate(
            CreateTaskMutation(.init(title: "Write the schema", plan: plan, slug: "musai")),
            as: MusaiActors.user).createTask.id
        _ = try await lib.db.mutate(
            SetTaskStatusMutation(.init(id: task, status: .doing)), as: MusaiActors.user)

        let text = try await MusaiSlice.render(project: "musai", budget: 2_000, db: lib.db)
        #expect(text == """
        Musai knows this project:
        - One Norvo file — decision, landed at commit:abc
        - Write the schema (in progress)
        """)
    }

    @Test func aMemoryWithNoProjectIsNotInAProjectsSlice() async throws {
        let lib = try await seeded()
        _ = try await lib.db.mutate(
            UpsertSessionUnboundMutation(.init(
                memorySessionId: "s-unbound", platform: "claude-code",
                cwd: "/tmp/never-a-repository", startedAt: Date(timeIntervalSince1970: 1_700_000_000))),
            as: MusaiActors.migrator("claude-mem"))
        _ = try await lib.db.mutate(
            RecordMemoryUnboundMutation(.init(
                kind: .fact, origin: .migrated, text: "the schema compiles",
                provenance: "claude-mem:observation:9", memorySessionId: "s-unbound")),
            as: MusaiActors.migrator("claude-mem"))
        try await settled(lib)

        let text = try await MusaiSlice.render(project: "musai", budget: 2_000, db: lib.db)
        let rendered = try #require(text)
        #expect(rendered.contains("One Norvo file"))
        #expect(!rendered.contains("the schema compiles"))
    }
}
