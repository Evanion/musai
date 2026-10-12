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

    @Test func controlCharactersInATitleCannotBreakTheHandover() async throws {
        let lib = try await seeded()
        let said = try await utterance(lib)
        let id = try await lib.db.mutate(
            RecordProposalMutation(.init(
                title: "tabs\tand\rreturns", rationale: nil, act: .constraint,
                utterance: said, project: "musai")),
            as: MusaiActors.curator).createDecision.id
        _ = try await lib.db.mutate(
            PersistDecisionOutsideMutation(.init(id: id, documentRef: "docs/\ta.swift", persistedAt: Date())),
            as: MusaiActors.user)

        let text = try #require(try await MusaiSlice.render(project: "musai", budget: 2_000, db: lib.db))
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(MusaiSlice.additionalContext(text).utf8))
                as? [String: Any])
        let specific = json["hookSpecificOutput"] as? [String: Any]
        let context = try #require(specific?["additionalContext"] as? [String])
        #expect(context.first?.contains("tabs\tand") == true)
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
}
