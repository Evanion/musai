import Foundation
import NorvoLite

/// What discovery concluded about a corpus: the projects a working tree was still found for, the ideas a label
/// turned out to be, the buckets that are neither, and how many sessions bound to nothing.
public struct DiscoveryOutcome: Sendable, Equatable {
    /// Project slugs, in the order the sessions named them, each once.
    public let projects: [String]
    /// Idea titles, in the order the labels named them, each once.
    public let ideas: [String]
    /// Bucket labels that became neither, each once.
    public let buckets: [String]
    /// Sessions whose `cwd` resolved to no project.
    public let unboundSessions: Int

    public init(projects: [String], ideas: [String], buckets: [String], unboundSessions: Int) {
        self.projects = projects
        self.ideas = ideas
        self.buckets = buckets
        self.unboundSessions = unboundSessions
    }
}

/// What a discovery pass concluded, and the project each bound session's `cwd` resolved to. The outcome is
/// what a person is shown and what the report carries; `projectByCwd` is what a caller writing the rows that
/// hang off a session needs, so it does not have to re-derive the rule for itself.
public struct DiscoveryPreview: Sendable, Equatable {
    public let outcome: DiscoveryOutcome
    /// The project slug for each session whose `cwd` resolved to one, keyed by the `cwd` exactly as the
    /// session row carries it.
    public let projectByCwd: [String: String]

    public init(outcome: DiscoveryOutcome, projectByCwd: [String: String]) {
        self.outcome = outcome
        self.projectByCwd = projectByCwd
    }
}

/// The first run's discovery — what an existing claude-mem corpus amounts to as a graph's entry points.
///
/// The rule is three-way, and it is **discovery, not invention**:
///
/// - A `Project` is created only from a session's `cwd` that is *still a git working tree*, and through
///   `ProjectBinder` so that working in the same repository later lands on the same slug instead of a second
///   project. A repository with no `origin` is not one (`gitRemote` returning non-`nil` is the test, not
///   merely "the directory exists"), a path that no longer exists is not one, and `$HOME` is never one
///   whatever it contains.
/// - An `Idea` is a label that neither names a project nor is a known bucket — a thread that lived only in
///   conversation. Discovery does not guess whether it is real; the person renames, merges or drops it.
/// - A bucket (`bucketLabels`) becomes neither, and is counted.
///
/// Nothing here opens the store, and every write goes through an operation that already exists:
/// `ProjectBinder`'s own resolution for a project, `CreateLooseIdea` for an idea with no project. Discovery
/// writes no `Memory` and no `Decision`. Running it twice over the same rows is a no-op — a project is keyed
/// by the binder's slug, an idea by its title.
///
/// The same rule is available with none of those writes, as `preview`: a person sees what *would* be
/// discovered before it is kept, which is what the import's dry run reads. `discover` and `preview` share one
/// plan, so the two cannot drift.
///
/// `evidence` is accepted because the import reads both kinds of row in one pass, but no rule here consumes it:
/// this task's rule is wholly about sessions, and minting ideas out of a subject or a concept would be exactly
/// the invention the design forbids, until the corpus names one.
public struct ImportDiscovery: Sendable {
    /// claude-mem project labels that are a filing habit rather than a unit of work, matched
    /// case-insensitively — so the seeds themselves are lowercase. Explicit, and extended only as the corpus
    /// teaches more: its junk labels cannot be inferred, and a heuristic that guessed at them would silently
    /// discard real projects, where an unknown label merely becomes an idea the person can drop.
    public static let bucketLabels: Set<String> = ["open-source"]

    /// Discovery writes as the migrator: these rows are history being read in, not the person's own work.
    private static let actor = MusaiActors.migrator("claude-mem")

    private let db: Database
    /// `$HOME`, resolved once from the injected file manager. `FileManager` is not `Sendable`, so the one
    /// environment-dependent value this type needs is the one that is kept.
    private let home: String

    public init(db: Database, fileManager: FileManager = .default) {
        self.db = db
        self.home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
    }

    public func discover(
        from sessions: [SourceSession], evidence: [SourceEvidence]
    ) async throws -> DiscoveryOutcome {
        let plan = try await plan(from: sessions)
        for path in plan.newProjectCwds {
            _ = try await ProjectBinder(db: db).resolveProject(cwd: URL(fileURLWithPath: path), as: Self.actor)
        }
        for title in plan.newIdeaTitles {
            _ = try await db.mutate(CreateLooseIdeaMutation(.init(title: title)), as: Self.actor)
        }
        return plan.outcome
    }

    /// The same rule, evaluated without writing anything: what `discover` would conclude, and where each
    /// session's history would land. A dry run is why this exists — the person sees what would be discovered
    /// *before* it is kept, so the run that shows them must not create the projects and ideas it is showing.
    /// `discover` and `preview` share one plan, so the two cannot drift.
    public func preview(
        from sessions: [SourceSession], evidence: [SourceEvidence]
    ) async throws -> DiscoveryPreview {
        let plan = try await plan(from: sessions)
        return DiscoveryPreview(outcome: plan.outcome, projectByCwd: plan.projectByCwd)
    }

    /// What a pass concludes, and what it would have to create to make its conclusion true. The plan is the
    /// rule; `discover` and `preview` are the two ways of delivering it.
    private struct DiscoveryPlan {
        let outcome: DiscoveryOutcome
        /// Session `cwd` → project slug, exactly as its row carries the `cwd`.
        let projectByCwd: [String: String]
        /// The working trees whose project is not in the store yet, in the order they were first named.
        let newProjectCwds: [String]
        /// Idea titles not in the store yet, in the order they were first named.
        let newIdeaTitles: [String]
    }

    private func plan(from sessions: [SourceSession]) async throws -> DiscoveryPlan {
        let binder = ProjectBinder(db: db)
        var projectByCwd: [String: String] = [:]
        var projectSlugs: [String] = []
        var seenSlugs: Set<String> = []
        var newProjectCwds: [String] = []
        var seenCwds: Set<String> = []
        var claimed: Set<String> = []
        var unbound = 0

        for session in sessions {
            guard let raw = session.cwd, let cwd = workingTree(of: session) else {
                unbound += 1
                continue
            }
            // Two sessions in one directory are one project, so a `cwd` already named is not looked up twice.
            if let named = projectByCwd[raw] {
                if seenSlugs.insert(named).inserted { projectSlugs.append(named) }
                continue
            }
            // A working tree that is not in the store yet is named by the binder's own rule, with the slugs
            // this pass has already claimed counted as taken — so the preview names what creating them in
            // order would produce, rather than handing two repositories one slug.
            let stored = try await binder.knownProject(cwd: cwd)
            let slug: String
            if let stored {
                slug = stored
            } else {
                slug = try await binder.prospectiveSlug(cwd: cwd, claiming: claimed)
                claimed.insert(slug)
                if seenCwds.insert(cwd.path).inserted { newProjectCwds.append(cwd.path) }
            }
            projectByCwd[raw] = slug
            if seenSlugs.insert(slug).inserted { projectSlugs.append(slug) }
        }

        // The titles already in the store, so a re-run — or a person's own idea of the same name — is not
        // duplicated. An idea's title has no unique index, so this read is what makes the write idempotent.
        let existing = try await db.query(AllIdeasQuery()).ideas
        var knownTitles = Set(existing.map(\.title))
        var seenLabels: Set<String> = []
        var buckets: [String] = []
        var ideas: [String] = []
        var newIdeaTitles: [String] = []
        let createdThisPass = Set(projectSlugs)

        for session in sessions {
            let label = session.projectLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, seenLabels.insert(label).inserted else { continue }
            if Self.bucketLabels.contains(label.lowercased()) {
                buckets.append(label)
                continue
            }
            // A label names a project when the binder's own rule turns it into that project's slug — the same
            // rule that names a live capture in the directory, so the two agree rather than duplicate. A
            // project this pass is about to create is as much a project as one already in the store.
            let slug = ProjectBinder.slugBase(label)
            if createdThisPass.contains(slug) { continue }
            if try await db.query(ProjectBySlugQuery(.init(slug: slug))).project != nil { continue }
            // An idea that is already there is still an idea, so it is reported either way: a second run over
            // the same rows concludes the same thing about the same rows and creates nothing. That is the same
            // reading as `projects` above, which reports a project it found rather than one it made.
            if knownTitles.insert(label).inserted { newIdeaTitles.append(label) }
            ideas.append(label)
        }

        return DiscoveryPlan(
            outcome: DiscoveryOutcome(
                projects: projectSlugs, ideas: ideas, buckets: buckets, unboundSessions: unbound),
            projectByCwd: projectByCwd,
            newProjectCwds: newProjectCwds,
            newIdeaTitles: newIdeaTitles)
    }

    /// The session's `cwd` as a URL, when it is a git working tree Musai may bind a project to; `nil` when it
    /// is missing, gone, `$HOME`, or not a repository with an `origin`.
    private func workingTree(of session: SourceSession) -> URL? {
        guard let path = session.cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        let cwd = URL(fileURLWithPath: path).standardizedFileURL
        // $HOME exactly is never a working tree, whatever it contains: binding it would create a junk project
        // that swallows the person's whole home directory.
        guard cwd.path != home else { return nil }
        guard FileManager.default.fileExists(atPath: cwd.path) else { return nil }
        guard ProjectBinder.gitRemote(for: cwd) != nil else { return nil }
        return cwd
    }
}
