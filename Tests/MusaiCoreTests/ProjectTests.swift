import Foundation
import Testing
@testable import MusaiCore

@Suite struct ProjectTests {
    @Test func createsAndReadsAProject() async throws {
        let lib = try await MusaiLibrary.inMemory()
        _ = try await lib.db.mutate(
            CreateProjectMutation(.init(name: "Musai", slug: "musai", summary: "Workspace")),
            as: MusaiActors.user)
        let project = try await lib.db.query(ProjectBySlugQuery(.init(slug: "musai"))).project
        #expect(project?.name == "Musai")
        #expect(project?.status == .active)
        let all = try await lib.db.query(AllProjectsQuery()).projects
        #expect(all.map(\.slug) == ["musai"])
    }

    @Test func upsertIsIdempotent() async throws {
        let lib = try await MusaiLibrary.inMemory()
        for _ in 0..<2 {
            _ = try await lib.db.mutate(
                UpsertProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user)
        }
        let all = try await lib.db.query(AllProjectsQuery()).projects
        #expect(all.count == 1)
    }

    @Test func aFileBackedLibrarySurvivesReopening() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-\(UUID().uuidString)/Musai.norvo")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // The engine holds the file lock until the last statement prepared from a database is freed, so the
        // first library must go out of scope, not merely be closed, before the file can be reopened.
        do {
            let first = try await MusaiLibrary.open(at: url)
            _ = try await first.db.mutate(
                CreateProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user)
            first.close()
        }
        let second = try await MusaiLibrary.open(at: url)
        let reopened = try await second.db.query(AllProjectsQuery()).projects
        #expect(reopened.count == 1)
        second.close()
    }
}
