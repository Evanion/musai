import Foundation
import Testing
@testable import MusaiCore

@Suite struct LinkTests {
    private func project(_ lib: MusaiLibrary, _ name: String, _ slug: String) async throws -> UUID {
        try await lib.db.mutate(
            CreateProjectMutation(.init(name: name, slug: slug)), as: MusaiActors.user).createProject.id
    }

    @Test func linksAreTypedAndReadableFromBothEnds() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let musai = try await project(lib, "Musai", "musai")
        let norvo = try await project(lib, "NorvoDB", "norvo")
        _ = try await lib.db.mutate(
            CreateLinkMutation(.init(source: musai, target: norvo, kind: .dependsOn)), as: MusaiActors.user)

        let out = try await lib.db.query(OutgoingLinksQuery(.init(id: musai))).links
        #expect(out.map(\.kind) == [.dependsOn])
        #expect(out.first?.target?.id == norvo)
        let incoming = try await lib.db.query(IncomingLinksQuery(.init(id: norvo))).links
        #expect(incoming.first?.source?.id == musai)
        let ofKind = try await lib.db.query(LinksOfKindQuery(.init(kind: .dependsOn))).links
        #expect(ofKind.count == 1)
    }

    @Test func deletingATargetLeavesTheLinkWithANullEndpoint() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let musai = try await project(lib, "Musai", "musai")
        let norvo = try await project(lib, "NorvoDB", "norvo")
        _ = try await lib.db.mutate(
            CreateLinkMutation(.init(source: musai, target: norvo, kind: .references)), as: MusaiActors.user)
        _ = try await lib.db.mutate(DeleteProjectMutation(.init(id: norvo)), as: MusaiActors.user)

        let out = try await lib.db.query(OutgoingLinksQuery(.init(id: musai))).links
        #expect(out.count == 1)
        #expect(out.first?.target?.id == nil)
        #expect(out.first?.source?.id == musai)
    }
}
