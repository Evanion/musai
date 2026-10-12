import Foundation
import Testing
@testable import MusaiCore

@Suite struct SearchTests {
    private func vector(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 1024)
        v[axis] = 1
        return v
    }

    private func memory(_ lib: MusaiLibrary, _ text: String, embedding: [Float]? = nil) async throws -> UUID {
        let id = try await lib.db.mutate(
            RecordMemoryMutation(.init(kind: .fact, origin: .authored, text: text, slug: "musai")),
            as: MusaiActors.user).createMemory.id
        if let embedding {
            _ = try await lib.db.mutate(EmbedMemoryMutation(.init(id: id, embedding: embedding)), as: MusaiActors.curator)
        }
        return id
    }

    private func seed(_ lib: MusaiLibrary) async throws {
        _ = try await lib.db.mutate(
            CreateProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user)
    }

    @Test func fullTextSearchRanksByMatch() async throws {
        let lib = try await MusaiLibrary.inMemory()
        try await seed(lib)
        let hit = try await memory(lib, "copy on write btree pages")
        _ = try await memory(lib, "unrelated")
        let results = try await lib.db.query(SearchMemoriesQuery(.init(q: "copy on write"))).memoriesConnection.edges
        #expect(results.first?.node.id == hit)
        #expect((results.first?.score ?? 0) > 0)
    }

    @Test func unicodeAndPunctuationAreSearchable() async throws {
        let lib = try await MusaiLibrary.inMemory()
        try await seed(lib)
        let hit = try await memory(lib, "記憶 — the muses' sparks, idea → spec")
        let results = try await lib.db.query(SearchMemoriesQuery(.init(q: "記憶"))).memoriesConnection.edges
        #expect(results.first?.node.id == hit)
    }

    @Test func vectorSearchUsesCosineOrderAndSkipsUnembeddedMemories() async throws {
        let lib = try await MusaiLibrary.inMemory()
        try await seed(lib)
        let first = try await memory(lib, "near x", embedding: vector(0))
        let second = try await memory(lib, "near y", embedding: vector(1))
        let bare = try await memory(lib, "no embedding")

        let results = try await lib.db.query(NearestMemoriesQuery(.init(v: vector(0), k: 10))).memoriesConnection.edges
        let ids = results.map(\.node.id)
        #expect(ids.first == first)
        #expect(ids.contains(second))
        #expect(!ids.contains(bare))
    }

    @Test func specsAreSearchableByBody() async throws {
        let lib = try await MusaiLibrary.inMemory()
        try await seed(lib)
        _ = try await lib.db.mutate(
            CreateSpecMutation(.init(title: "Musai design", kind: .design, body: "one Lite file", position: 1, slug: "musai")),
            as: MusaiActors.user)
        let results = try await lib.db.query(SearchSpecsQuery(.init(q: "one Lite file"))).specsConnection.edges
        #expect(results.first?.node.title == "Musai design")
    }
}
