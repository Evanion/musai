import Foundation

/// What one import run did, and what discovery found. Two kinds of number live here deliberately, and the
/// type says which is which so the next reader is not misled:
///
/// - **This run's work** — `sessions`, `evidence`, `prompts`, `workStates`, `proposals`, `machinePrompts`,
///   `skipped` and `unbound`. A run is a bounded piece of the one writer (see `MusaiImport.run`), so these
///   count what *this* call wrote, never a running total for the import.
/// - **Discovery's verdict** — `projects`, `ideas` and `buckets`. These are what the corpus *names*, not what
///   the run created: discovery reports a project it found as readily as one it made, so a second run over
///   the same rows concludes the same three, and a dry run can show them before anything is kept.
///
/// A dry run reports both kinds and writes neither: every number below is what a real run would have done.
public struct ImportReport: Sendable, Equatable, Codable {
    /// Whether this was a dry run — a report of what would happen, with nothing written.
    public let dryRun: Bool
    /// Sessions written this run, each keyed on the host's session id.
    public let sessions: Int
    /// Evidence written this run, as `Memory { origin: .migrated }`.
    public let evidence: Int
    /// The person's prompts written this run, as `Utterance`s.
    public let prompts: Int
    /// Work-state lists created or moved forward this run. They are latest-only: one list is one row.
    public let workStates: Int
    /// Migrated proposals filed this run: the corpus's one-sided entries — its `decision`-typed observations
    /// and the `next_steps` of summaries — as proposals in their own state, out of the live review list.
    public let proposals: Int
    /// Projects discovery named, in the order the corpus first named them.
    public let projects: [String]
    /// Ideas discovery named, in the order the corpus first named them.
    public let ideas: [String]
    /// Labels that are a filing habit rather than a unit of work, and so became neither a project nor an idea.
    public let buckets: [String]
    /// Sessions written with no project — 838 of the real corpus's 956 importable ones, which is exactly why
    /// they are written at all.
    public let unbound: Int
    /// Prompts dropped as machine apparatus: hook payloads and tool-result echoes.
    public let machinePrompts: Int
    /// Rows read and deliberately not written: evidence whose prose composed to nothing, a prompt with no
    /// words in it, evidence already in the store, a work state whose label names no project, a row whose
    /// session is not in the store to connect it to, and a summary with no `next_steps` to propose from — or
    /// one whose proposal is already filed. A one-sided observation the proposals stage declines is *not*
    /// counted here: the evidence stage read the same row and already counted it.
    public let skipped: Int

    public init(
        dryRun: Bool = false, sessions: Int = 0, evidence: Int = 0, prompts: Int = 0, workStates: Int = 0,
        proposals: Int = 0, projects: [String] = [], ideas: [String] = [], buckets: [String] = [],
        unbound: Int = 0, machinePrompts: Int = 0, skipped: Int = 0
    ) {
        self.dryRun = dryRun
        self.sessions = sessions
        self.evidence = evidence
        self.prompts = prompts
        self.workStates = workStates
        self.proposals = proposals
        self.projects = projects
        self.ideas = ideas
        self.buckets = buckets
        self.unbound = unbound
        self.machinePrompts = machinePrompts
        self.skipped = skipped
    }
}
