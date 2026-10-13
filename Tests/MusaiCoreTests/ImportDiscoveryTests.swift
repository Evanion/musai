import Foundation
import Testing
@testable import MusaiCore

/// The first run's three-way rule: a `cwd` that is still a git working tree creates a project, a label that
/// never was one becomes an idea, and a filing bucket becomes neither. The corpus is what makes the rule
/// three-way — 13 distinct cwds across 244 sessions, only 9 of 68 labels carrying one at all — so discovery
/// must not invent a project for a label any more than it must drop one for a working tree.
@Suite struct ImportDiscoveryTests {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let remote = "git@github.com:evanion/musai-fixture.git"

    /// A throwaway directory that is a real working tree as far as `ProjectBinder.gitRemote(for:)` is
    /// concerned — a `.git/config` carrying an `origin`. Temp only: no repository of the person's is read.
    private func makeWorkingTree() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-discovery-\(UUID().uuidString)")
        let git = root.appending(path: ".git")
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        try "[remote \"origin\"]\n\turl = \(remote)\n".write(
            to: git.appending(path: "config"), atomically: true, encoding: .utf8)
        return root
    }

    /// A path that does not exist, so nothing about it can be a working tree.
    private func missingPath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-discovery-gone-\(UUID().uuidString)").path
    }

    private func session(_ id: String, cwd: String?, label: String) -> SourceSession {
        SourceSession(
            memorySessionId: id, hostSessionId: id, platform: "claude-code", cwd: cwd,
            status: .completed, startedAt: start, projectLabel: label)
    }

    @Test func aCwdThatIsAWorkingTreeBecomesAProject() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let root = try makeWorkingTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let name = root.lastPathComponent

        // The label is the directory's own name: it names the project that was just discovered, so it must
        // not *also* be filed as an idea.
        let outcome = try await ImportDiscovery(db: lib.db)
            .discover(from: [session("s-repo", cwd: root.path, label: name)], evidence: [])

        let slug = ProjectBinder.slugBase(name)
        #expect(outcome.projects == [slug])
        #expect(outcome.ideas.isEmpty)
        #expect(outcome.buckets.isEmpty)
        #expect(outcome.unboundSessions == 0)

        let project = try await lib.db.query(ProjectBySlugQuery(.init(slug: slug))).project
        #expect(project != nil)
        #expect(project?.name == name)
        #expect(project?.rootPath == root.path)
        #expect(project?.repoRemote == ProjectBinder.normalizedRemote(remote))
    }

    @Test func aLabelWithNoWorkingTreeBecomesAnIdea() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let root = try makeWorkingTree()
        defer { try? FileManager.default.removeItem(at: root) }

        // Two sessions of one thread: one whose path is gone, one with no path at all. The first's *parent* is
        // a working tree, so walking up must not adopt that repository for it — a path that no longer exists
        // is not a project however its ancestors look. One idea, not two.
        let gone = root.appending(path: "gone-subdirectory").path
        #expect(ProjectBinder.gitRemote(for: URL(fileURLWithPath: gone)) != nil)
        let outcome = try await ImportDiscovery(db: lib.db).discover(
            from: [session("s-1", cwd: gone, label: "some-thread"),
                session("s-2", cwd: nil, label: "some-thread")],
            evidence: [])

        #expect(outcome.ideas == ["some-thread"])
        #expect(outcome.projects.isEmpty)
        #expect(outcome.buckets.isEmpty)
        #expect(outcome.unboundSessions == 2)

        let ideas = try await lib.db.query(AllIdeasQuery()).ideas
        #expect(ideas.map(\.title) == ["some-thread"])
        #expect(ideas.first?.project == nil)
        let projects = try await lib.db.query(AllProjectsQuery()).projects
        #expect(projects.isEmpty)
    }

    @Test func aBucketBecomesNeither() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let gone = missingPath()

        // The seed is lowercase and the set is case-insensitive, so the corpus's own spelling of the same
        // filing habit is the same bucket.
        let outcome = try await ImportDiscovery(db: lib.db).discover(
            from: [session("s-1", cwd: gone, label: "open-source"),
                session("s-2", cwd: nil, label: "Open-Source")],
            evidence: [])

        #expect(ImportDiscovery.bucketLabels.contains("open-source"))
        #expect(outcome.buckets == ["open-source", "Open-Source"])
        #expect(outcome.ideas.isEmpty)
        #expect(outcome.projects.isEmpty)
        #expect(outcome.unboundSessions == 2)

        let ideas = try await lib.db.query(AllIdeasQuery()).ideas
        #expect(ideas.isEmpty)
        let projects = try await lib.db.query(AllProjectsQuery()).projects
        #expect(projects.isEmpty)
    }

    @Test func theHomeDirectoryIsNotAWorkingTree() async throws {
        let lib = try await MusaiLibrary.inMemory()

        // $HOME exactly: it exists, it is not a repository, and binding it would swallow the person's home.
        // Bucket-labelled so that "neither a project nor an idea" is the whole of what this session yields.
        let real = try await ImportDiscovery(db: lib.db).discover(
            from: [session("s-home", cwd: NSHomeDirectory(), label: "open-source")], evidence: [])
        #expect(real.projects.isEmpty)
        #expect(real.ideas.isEmpty)
        #expect(real.unboundSessions == 1)

        // And a home that *is* a working tree, so that the exclusion — not the absence of a `.git` — is what
        // refuses it. The injected file manager reports a temp directory as home so the real one is untouched.
        let fakeHome = try makeWorkingTree()
        defer { try? FileManager.default.removeItem(at: fakeHome) }
        #expect(ProjectBinder.gitRemote(for: fakeHome) != nil)
        let outcome = try await ImportDiscovery(db: lib.db, fileManager: HomeFileManager(home: fakeHome))
            .discover(from: [session("s-fake-home", cwd: fakeHome.path, label: "open-source")], evidence: [])
        #expect(outcome.projects.isEmpty)
        #expect(outcome.ideas.isEmpty)
        #expect(outcome.unboundSessions == 1)

        let projects = try await lib.db.query(AllProjectsQuery()).projects
        #expect(projects.isEmpty)
    }

    @Test func discoveryIsIdempotent() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let root = try makeWorkingTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = [session("s-repo", cwd: root.path, label: root.lastPathComponent),
            session("s-thread", cwd: missingPath(), label: "some-thread")]
        let discovery = ImportDiscovery(db: lib.db)

        let first = try await discovery.discover(from: rows, evidence: [])
        let projectsAfterFirst = try await lib.db.query(AllProjectsQuery()).projects.count
        let ideasAfterFirst = try await lib.db.query(AllIdeasQuery()).ideas.count
        #expect(projectsAfterFirst == 1)
        #expect(ideasAfterFirst == 1)

        let second = try await discovery.discover(from: rows, evidence: [])
        #expect(second == first)
        let projectsAfterSecond = try await lib.db.query(AllProjectsQuery()).projects.count
        let ideasAfterSecond = try await lib.db.query(AllIdeasQuery()).ideas.count
        #expect(projectsAfterSecond == projectsAfterFirst)
        #expect(ideasAfterSecond == ideasAfterFirst)
    }
}

/// The home rule compares a session's `cwd` with the injected file manager's home, so a test can give it a
/// temporary home instead of writing a `.git` into the real one (`init(db:fileManager:)` is the seam).
private final class HomeFileManager: FileManager {
    private let home: URL

    init(home: URL) {
        self.home = home
        super.init()
    }

    override var homeDirectoryForCurrentUser: URL { home }
}
