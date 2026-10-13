import Foundation
import NorvoLite

/// The import: the first run's driver. It reads an existing claude-mem corpus — **read-only**, through
/// `ClaudeMemReader` — and writes the person's history into the graph: sessions keyed on the host's session
/// id, claude-mem's own distilled observations as migrated `Memory`, the conversation as `Utterance`s, and the
/// work state, latest-only. It writes nothing back to the corpus.
///
/// Three properties it has to hold, and how:
///
/// - **Idempotent.** `Session.memorySessionId` carries the *host's* session id — the one live capture already
///   upserts on — so a conversation claude-mem and Musai both saw lands on one row. A memory is keyed by its
///   `provenance` and an utterance by its `origin`, so a row that is written twice lands once.
/// - **Resumable.** Each stage keeps an `ImportCursor`: a stored high-water mark of the last source row id it
///   has passed, moved *after* the batch it names has been written. A run that fails, or is killed between two
///   batches, resumes at the last committed boundary rather than at the beginning — and a row that was read
///   and deliberately dropped (an apparatus prompt) is behind the cursor too, so a re-run does not resurrect it.
/// - **Bounded.** A run is one batch per stage, not the whole corpus: it shares the one writer with capture
///   and the curator, so it holds it for a batch at a time, and a caller repeats `run()` until a report comes
///   back empty. The one exception is the sessions stage, which is read to its end before the others start:
///   every later stage writes *through* a session row, and a half-read sessions stage would strand evidence
///   behind a cursor that had already passed it.
///
/// Every write goes through `commit`, which a dry run turns off and nothing else — the dry run is the same
/// code with the mutations skipped, rather than a second path that could disagree with the real one.
public struct MusaiImport: Sendable {
    /// The `ImportCursor.source` names, one per stage this driver owns. A stage's name is its identity —
    /// `ImportCursor.source` is unique — so they must stay distinct; Task 6's proposals stage takes a fourth.
    public enum Cursor: String, Sendable {
        case sessions = "claude-mem:sessions"
        case evidence = "claude-mem:observations"
        case prompts = "claude-mem:prompts"
    }

    /// What the import does with one prompt. The rule is a judgement rather than a column, so it lives in one
    /// place, and it is a *drop* rule: 6 068 of the real corpus's 17 848 prompts are `<task-notification>` hook
    /// payloads (every one of the 1 709 carrying a `toolu_` id is one of them) and 432 are two characters or
    /// less. The decision-loop design's rule is that the person's words are stored verbatim, and none of these
    /// are the person's words — so none becomes an `Utterance`.
    public enum PromptVerdict: Sendable, Equatable {
        /// The person's words: an `Utterance`.
        case utterance
        /// A machine apparatus payload — a hook notification, or a tool result the host echoed.
        case machine
        /// No words in it: empty, or at or below `promptLengthFloor` characters.
        case skipped
    }

    /// The length floor for a prompt, after trimming: a row this many characters or shorter is not a word.
    public static let promptLengthFloor = 2

    /// The one place the prompt rule lives. Apparatus first, because a payload is the machine's whatever its
    /// length; then the floor, because a row with no words in it is not the person's either.
    public static func verdict(forPrompt text: String) -> PromptVerdict {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<task-notification") || trimmed.contains("toolu_") { return .machine }
        if trimmed.count <= Self.promptLengthFloor { return .skipped }
        return .utterance
    }

    /// A prompt's source row as an `Utterance.origin` — the role `Decision.origin` plays, and what makes a
    /// re-run land on the utterance already there rather than beside it.
    static func promptOrigin(_ id: Int) -> String { "claude-mem:prompt:\(id)" }
    /// A work-state row's source row as a `WorkState.origin`, the same shape.
    static func workStateOrigin(_ id: Int) -> String { "claude-mem:work_state:\(id)" }

    private let db: Database
    private let reader: ClaudeMemReader
    private let discovery: ImportDiscovery
    private let batch: Int
    private let actor: Actor

    public init(db: Database, reader: ClaudeMemReader, discovery: ImportDiscovery, batch: Int = 500, as actor: Actor) {
        self.db = db
        self.reader = reader
        self.discovery = discovery
        // A batch of zero would never advance a cursor; one row per batch is the smallest honest run.
        self.batch = max(batch, 1)
        self.actor = actor
    }

    /// Runs the import — or, with `dryRun`, everything it would do except the writes.
    ///
    /// The stages are ordered by dependency: a session before the evidence and prompts that connect through it,
    /// evidence before prompts, work state last. Each stage commits a batch at a time and only then moves its
    /// cursor past it.
    public func run(dryRun: Bool = false) async throws -> ImportReport {
        var tally = Tally()
        // Where each session this run read belongs, by host session id. A dry run needs it as much as a real
        // run: evidence and prompts connect through a session that a dry run has not written.
        var bindings: [String: Binding?] = [:]

        try await importSessions(dryRun: dryRun, tally: &tally, bindings: &bindings)
        try await importEvidence(dryRun: dryRun, tally: &tally, bindings: &bindings)
        try await importPrompts(dryRun: dryRun, tally: &tally, bindings: &bindings)
        // The slugs discovery named — the projects a dry run has not written, and that a work state may live on.
        let projects = tally.projects
        try await importWorkState(dryRun: dryRun, tally: &tally, projects: projects)

        return tally.report(dryRun)
    }

    // MARK: - Sessions

    /// Reads the sessions to their end, in batches, and writes them — discovery first, so that a project
    /// exists before the evidence that binds to it. Read to the end rather than one batch, because every later
    /// stage connects through a session row: a batch boundary in the middle of this stage would leave evidence
    /// whose session has not been written, behind an evidence cursor that has already passed it.
    private func importSessions(dryRun: Bool, tally: inout Tally, bindings: inout [String: Binding?]) async throws {
        var cursor = try await highWater(.sessions)
        while true {
            let rows = try reader.sessions(limit: batch, after: cursor)
            guard let last = rows.last else { break }
            // The preview is what a dry run reports and what both modes bind by; `discover` is the same rule
            // with the writes turned on, so a real run's projects are exactly the slugs the preview named.
            let preview = try await discovery.preview(from: rows, evidence: [])
            tally.merge(preview.outcome)
            if !dryRun { _ = try await discovery.discover(from: rows, evidence: []) }
            for session in rows {
                let binding = try await importSession(
                    session, preview: preview, dryRun: dryRun, tally: &tally)
                bindings[session.hostSessionId] = binding
            }
            cursor = last.id
            try await move(.sessions, to: cursor, dryRun: dryRun)
        }
    }

    /// Writes one source session and says where it ended up bound.
    ///
    /// The corpus row decides its platform, `cwd`, title and start. Its project comes from discovery's verdict
    /// for that `cwd`, or — when the corpus names none — from the project the store already has for that
    /// session: 838 of the real corpus's sessions carry no `cwd`, and a conversation live capture bound must
    /// not be unbound by an import that merely lacks one. A session the store already has as finished is not
    /// moved back to active, for the same reason `ProjectBinder.bind` does not: an import reads old rows.
    private func importSession(
        _ session: SourceSession, preview: DiscoveryPreview, dryRun: Bool, tally: inout Tally
    ) async throws -> Binding {
        let existing = try await db.query(
            SessionByMemoryIdQuery(.init(memorySessionId: session.hostSessionId))).session
        let status = existing.map { $0.status == .active ? session.status : $0.status } ?? session.status
        let slug = session.cwd.flatMap { preview.projectByCwd[$0] } ?? existing?.project?.slug
        if let slug {
            try await commit(
                UpsertSessionMutation(.init(
                    memorySessionId: session.hostSessionId, platform: session.platform, cwd: session.cwd,
                    title: session.title, status: status, startedAt: session.startedAt, slug: slug)),
                dryRun)
        } else {
            try await commit(
                UpsertSessionUnboundMutation(.init(
                    memorySessionId: session.hostSessionId, platform: session.platform, cwd: session.cwd,
                    title: session.title, status: status, startedAt: session.startedAt)),
                dryRun)
            tally.unbound += 1
        }
        // A session the corpus recorded an end for keeps one: status and a wall-clock end go together, and
        // `UpsertSession` cannot carry the latter.
        if let endedAt = session.endedAt {
            try await commit(
                EndSessionMutation(.init(
                    memorySessionId: session.hostSessionId, status: status, endedAt: endedAt)),
                dryRun)
        }
        tally.sessions += 1
        return Binding(slug: slug)
    }

    // MARK: - Evidence

    /// One batch of observations, as migrated `Memory`. A row whose composed prose is empty is not evidence;
    /// a row already in the store — a resumed run whose cursor was lost — is not written twice; and a row whose
    /// session the store has not got has nothing to connect to, so it is counted rather than written. Every one
    /// of those was read, so the cursor passes all of them.
    private func importEvidence(
        dryRun: Bool, tally: inout Tally, bindings: inout [String: Binding?]
    ) async throws {
        let cursor = try await highWater(.evidence)
        let rows = try reader.evidence(limit: batch, after: cursor)
        for row in rows {
            guard !row.text.isEmpty else {
                tally.skipped += 1
                continue
            }
            let present = try await db.query(
                MemoryByProvenanceQuery(.init(provenance: row.provenance))).memories
            guard present.isEmpty else {
                tally.skipped += 1
                continue
            }
            guard let binding = try await binding(forSession: row.hostSessionId, in: &bindings) else {
                tally.skipped += 1
                continue
            }
            if let slug = binding.slug {
                try await commit(
                    RecordMemoryForSessionMutation(.init(
                        kind: row.kind, origin: .migrated, text: row.text, narrative: row.narrative,
                        concepts: row.concepts, provenance: row.provenance, slug: slug,
                        memorySessionId: row.hostSessionId)),
                    dryRun)
            } else {
                try await commit(
                    RecordMemoryUnboundMutation(.init(
                        kind: row.kind, origin: .migrated, text: row.text, narrative: row.narrative,
                        concepts: row.concepts, provenance: row.provenance,
                        memorySessionId: row.hostSessionId)),
                    dryRun)
            }
            tally.evidence += 1
        }
        if let last = rows.last { try await move(.evidence, to: last.id, dryRun: dryRun) }
    }

    // MARK: - Prompts

    /// One batch of the person's prompts, as `Utterance`s: `Speaker.user`, the corpus's own time, and the text
    /// truncated on a UTF-8 boundary exactly as live capture truncates it. The apparatus is dropped and
    /// counted, and every dropped row is behind the cursor — which is what keeps a re-run from resurrecting it.
    private func importPrompts(
        dryRun: Bool, tally: inout Tally, bindings: inout [String: Binding?]
    ) async throws {
        let cursor = try await highWater(.prompts)
        let rows = try reader.prompts(limit: batch, after: cursor)
        // The origins each session already carries, read once per session rather than once per prompt.
        var recorded: [String: Set<String>] = [:]
        for row in rows {
            switch Self.verdict(forPrompt: row.text) {
            case .machine:
                tally.machinePrompts += 1
            case .skipped:
                tally.skipped += 1
            case .utterance:
                guard try await binding(forSession: row.hostSessionId, in: &bindings) != nil else {
                    tally.skipped += 1
                    continue
                }
                let origin = Self.promptOrigin(row.id)
                let already = try await origins(forSession: row.hostSessionId, in: &recorded)
                guard !already.contains(origin) else {
                    tally.skipped += 1
                    continue
                }
                try await commit(
                    RecordUtteranceMutation(.init(
                        text: MusaiCapture.truncated(row.text, to: MusaiCapture.maxTextBytes), at: row.at,
                        speaker: .user, origin: origin, session: row.hostSessionId)),
                    dryRun)
                recorded[row.hostSessionId, default: []].insert(origin)
                tally.prompts += 1
            }
        }
        if let last = rows.last { try await move(.prompts, to: last.id, dryRun: dryRun) }
    }

    // MARK: - Work state

    /// The work state. claude-mem's entries are revisions of a list rather than rows of data — the real
    /// corpus's 18 are 18 revisions of one — so only the newest revision of each (project, list) is written,
    /// and a re-run that finds the store already holding it moves nothing. There is no cursor here: the rows
    /// are few, and the write converges instead.
    private func importWorkState(dryRun: Bool, tally: inout Tally, projects: [String]) async throws {
        var latest: [String: (slug: String, row: SourceWorkState)] = [:]
        // The project a label names, resolved once per label: the same rule discovery uses for a label, so the
        // two agree — the binder's slug, either already in the store or one this run's discovery named.
        var named: [String: String] = [:]
        var unnamed: Set<String> = []
        for row in try reader.workState() {
            let trimmed = row.projectLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, named[trimmed] == nil, !unnamed.contains(trimmed) {
                let slug = ProjectBinder.slugBase(trimmed)
                // `||` takes an autoclosure, which cannot await, so the store is asked first.
                let stored = try await db.query(ProjectBySlugQuery(.init(slug: slug))).project != nil
                if projects.contains(slug) || stored {
                    named[trimmed] = slug
                } else {
                    unnamed.insert(trimmed)
                }
            }
            guard let slug = named[trimmed] else {
                // A `WorkState` lives on a project — the schema requires one — and discovery is not in the
                // business of inventing a project for a label it never found a working tree for.
                tally.skipped += 1
                continue
            }
            let key = "\(slug)\u{1}\(row.listName)"
            if let current = latest[key], current.row.id > row.id { continue }
            latest[key] = (slug, row)
        }
        for entry in latest.values.sorted(by: { $0.row.id < $1.row.id }) {
            let fields = Self.json(entry.row.fields)
            let stored = try await db.query(WorkStateListsQuery(.init(slug: entry.slug))).workStates
                .last { $0.listName == entry.row.listName }
            if let stored {
                guard stored.fields != fields else { continue }
                try await commit(UpdateWorkStateEntryMutation(.init(id: stored.id, fields: fields)), dryRun)
            } else {
                try await commit(
                    AddWorkStateEntryMutation(.init(
                        listName: entry.row.listName, fields: fields,
                        origin: Self.workStateOrigin(entry.row.id), slug: entry.slug)),
                    dryRun)
            }
            tally.workStates += 1
        }
    }

    /// The corpus's `fields` as the graph's JSON. A value that will not decode is kept as its raw text rather
    /// than dropped: a person reading the row sees what claude-mem wrote.
    static func json(_ text: String) -> JSONValue {
        guard let data = text.data(using: .utf8),
            let value = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return .string(text) }
        return value
    }

    // MARK: - Where a session's rows belong

    /// A session's project, for the rows that connect through it. `nil` when the session has none.
    private struct Binding: Equatable {
        let slug: String?
    }

    /// Where a session's rows belong. The session may be one this run read — a dry run's, which the store has
    /// not got — or one an earlier run or live capture wrote, so the store is asked when the run's own map has
    /// nothing. A session in neither is not in the corpus's sessions at all, and a row connecting to it is
    /// counted rather than written. (The map holds `Binding?`: a key present with `nil` means "known to be
    /// absent", which is what stops a dry run from asking the store for every orphan row.)
    private func binding(forSession key: String, in bindings: inout [String: Binding?]) async throws -> Binding? {
        if let known = bindings[key] { return known }
        guard let stored = try await db.query(SessionByMemoryIdQuery(.init(memorySessionId: key))).session else {
            bindings[key] = Binding?.none
            return nil
        }
        let found = Binding(slug: stored.project?.slug)
        bindings[key] = found
        return found
    }

    /// The utterance origins a session already carries, read once per session per run.
    private func origins(forSession key: String, in known: inout [String: Set<String>]) async throws -> Set<String> {
        if let found = known[key] { return found }
        let rows = try await db.query(UtterancesForSessionQuery(.init(session: key))).utterances
        let origins = Set(rows.compactMap(\.origin))
        known[key] = origins
        return origins
    }

    // MARK: - The cursor, and the one place a write happens

    /// The high-water mark a stage has passed, or zero when it has never run.
    private func highWater(_ cursor: Cursor) async throws -> Int {
        try await db.query(ImportCursorQuery(.init(source: cursor.rawValue))).importCursor?.highWaterId ?? 0
    }

    /// Moves a stage's cursor past the batch that was just written. Called *after* the batch, so an interrupted
    /// run resumes at the last committed boundary; a dry run moves nothing, because it wrote nothing.
    private func move(_ cursor: Cursor, to highWaterId: Int, dryRun: Bool) async throws {
        try await commit(SetImportCursorMutation(.init(source: cursor.rawValue, highWaterId: highWaterId)), dryRun)
    }

    /// Every write the import makes, in one place, so that a dry run is this code with the writes turned off
    /// rather than a second path that could disagree with it.
    private func commit<M: NorvoMutation>(_ mutation: M, _ dryRun: Bool) async throws {
        guard !dryRun else { return }
        _ = try await db.mutate(mutation, as: actor)
    }

    // MARK: - The run's numbers

    /// The run's working tally. `ImportReport` is the run's answer and never changes; these are the numbers
    /// behind it, with discovery's three arrays deduped because the sessions stage reads in batches and two
    /// batches can name the same project or idea.
    private struct Tally {
        var sessions = 0
        var evidence = 0
        var prompts = 0
        var workStates = 0
        var unbound = 0
        var machinePrompts = 0
        var skipped = 0
        var projects: [String] = []
        var ideas: [String] = []
        var buckets: [String] = []
        private var seenProjects: Set<String> = []
        private var seenIdeas: Set<String> = []
        private var seenBuckets: Set<String> = []

        mutating func merge(_ outcome: DiscoveryOutcome) {
            for slug in outcome.projects where seenProjects.insert(slug).inserted { projects.append(slug) }
            for title in outcome.ideas where seenIdeas.insert(title).inserted { ideas.append(title) }
            for label in outcome.buckets where seenBuckets.insert(label).inserted { buckets.append(label) }
        }

        func report(_ dryRun: Bool) -> ImportReport {
            ImportReport(
                dryRun: dryRun, sessions: sessions, evidence: evidence, prompts: prompts,
                workStates: workStates, proposals: 0, projects: projects, ideas: ideas, buckets: buckets,
                unbound: unbound, machinePrompts: machinePrompts, skipped: skipped)
        }
    }
}
