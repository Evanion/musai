import Foundation
import NorvoLite
import Testing
@testable import MusaiCore

@Suite struct WorkStateTests {
    @Test func listsAreScopedToAProjectAndKeepTheirShape() async throws {
        let lib = try await MusaiLibrary.inMemory()
        _ = try await lib.db.mutate(
            CreateProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user)
        _ = try await lib.db.mutate(
            CreateProjectMutation(.init(name: "NorvoDB", slug: "norvo")), as: MusaiActors.user)
        _ = try await lib.db.mutate(
            AddWorkStateEntryMutation(.init(
                listName: "musai-work",
                fields: .object(["task": .string("write the schema"), "status": .string("doing")]),
                origin: "claude-mem", slug: "musai")),
            as: MusaiActors.migrator("claude-mem"))
        _ = try await lib.db.mutate(
            AddWorkStateEntryMutation(.init(listName: "other", fields: .object([:]), slug: "norvo")),
            as: MusaiActors.migrator("claude-mem"))

        let lists = try await lib.db.query(WorkStateListsQuery(.init(slug: "musai"))).workStates
        #expect(lists.map(\.listName) == ["musai-work"])
        #expect(lists.first?.fields == .object(["task": .string("write the schema"), "status": .string("doing")]))
        #expect(lists.first?.origin == "claude-mem")
    }
}
