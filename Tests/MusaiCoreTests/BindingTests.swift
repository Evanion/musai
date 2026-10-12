import Foundation
import Testing
@testable import MusaiCore

@Suite struct BindingTests {
    /// A directory with a hand-written `.git/config`, so the test needs no `git`.
    private func makeRepo(name: String, remote: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-bind-\(UUID().uuidString)/\(name)")
        try FileManager.default.createDirectory(at: root.appending(path: ".git"), withIntermediateDirectories: true)
        try """
        [core]
        \trepositoryformatversion = 0
        [remote "origin"]
        \turl = \(remote)
        \tfetch = +refs/heads/*:refs/remotes/origin/*
        """.write(to: root.appending(path: ".git/config"), atomically: true, encoding: .utf8)
        return root
    }

    @Test func bindsIdempotently() async throws {
        let root = try makeRepo(name: "NorvoDB", remote: "git@github.com:NorvoDB/norvo-swift.git")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let lib = try await MusaiLibrary.inMemory()
        let binder = ProjectBinder(db: lib.db)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await binder.bind(cwd: root, memorySessionId: "s1", platform: "test", startedAt: start, as: MusaiActors.user)
        _ = try await binder.bind(cwd: root, memorySessionId: "s1", platform: "test", startedAt: start, as: MusaiActors.user)
        let projects = try await lib.db.query(AllProjectsQuery()).projects
        #expect(projects.count == 1)
        let session = try await lib.db.query(SessionByMemoryIdQuery(.init(memorySessionId: "s1"))).session
        #expect(session?.memorySessionId == "s1")
    }

    @Test func normalizesRemotes() {
        let ssh = ProjectBinder.normalizedRemote("git@github.com:NorvoDB/norvo-swift.git")
        let https = ProjectBinder.normalizedRemote("https://github.com/NorvoDB/norvo-swift.git")
        #expect(ssh == https)
    }

    @Test func bindsTwoRemoteFormsToOneProject() async throws {
        let ssh = try makeRepo(name: "a", remote: "git@github.com:NorvoDB/norvo-swift.git")
        let https = try makeRepo(name: "b", remote: "https://github.com/NorvoDB/norvo-swift.git")
        defer {
            try? FileManager.default.removeItem(at: ssh.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: https.deletingLastPathComponent())
        }
        let lib = try await MusaiLibrary.inMemory()
        let binder = ProjectBinder(db: lib.db)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try await binder.bind(cwd: ssh, memorySessionId: "s1", platform: "test", startedAt: start, as: MusaiActors.user)
        _ = try await binder.bind(cwd: https, memorySessionId: "s2", platform: "test", startedAt: start, as: MusaiActors.user)
        let projects = try await lib.db.query(AllProjectsQuery()).projects
        #expect(projects.count == 1)
    }

    @Test func aDirectoryWithoutGitBecomesItsOwnProject() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-bind-\(UUID().uuidString)/Sans-Dépôt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let lib = try await MusaiLibrary.inMemory()
        let binder = ProjectBinder(db: lib.db)
        let bound = try await binder.bind(
            cwd: root, memorySessionId: "s1", platform: "test",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), as: MusaiActors.user)
        let project = try await lib.db.query(ProjectBySlugQuery(.init(slug: bound.projectSlug))).project
        #expect(project?.name == "Sans-Dépôt")
        #expect(project?.rootPath == root.path)
    }
}
