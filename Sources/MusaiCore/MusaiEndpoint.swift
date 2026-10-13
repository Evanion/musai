import Foundation
import NorvoLite

/// The backend's whole protocol, one request at a time: a pure router from `EndpointRequest` to
/// `EndpointResponse`. It owns nothing — the store is the agent's, the curator runs in its own controller —
/// so a test drives the whole protocol without a socket, and Task 2's listener can serve it unchanged.
///
/// It can also exist with **no store at all**, which is a state a person has to be able to read: an agent
/// that could not open its store keeps its listener up, and `/health` is the one route that still answers —
/// truthfully saying `failed` — while every other route says why in one line naming the log, rather than
/// crashing or leaving a 500 a client cannot tell from a broken backend.
public struct MusaiEndpoint: Sendable {
    /// What this endpoint has to serve from. There is deliberately no third state, and not two independent
    /// optionals either: the store either opened or it did not, and two optionals could disagree about which.
    public enum Store: Sendable {
        /// The store this endpoint serves, and the library that owns it — held so the owner outlives the
        /// requests.
        case open(db: Database, library: MusaiLibrary)
        /// No store: the agent could not open one. `/health` still answers.
        case none
    }

    public let store: Store
    public let state: EndpointState
    /// The drain that turns captures into proposals. `nil` when there is no store to drain.
    public let curator: CuratorController?
    /// Every request must carry this. A stranger on the machine gets a 401 and learns nothing — not even
    /// the store's path, which is why `/health` checks it too.
    public let token: String
    /// The log a person reads when something is wrong, named in the one line a storeless endpoint answers
    /// with. The agent passes its own; the default is the one a person will find.
    public let logPath: String
    /// The cheap read that tells a healthy store from one the engine has declared failed, run before each
    /// store-touching request exactly as the agent runs it at start. `nil` (the default) trusts the store; the
    /// agent passes its own, and a test can pass one that surfaces a fatal mid-life.
    public let probe: (@Sendable (Database) async throws -> Void)?

    public init(
        store: Store, state: EndpointState, curator: CuratorController? = nil, token: String,
        logPath: String = MusaiLog.defaultURL.path,
        probe: (@Sendable (Database) async throws -> Void)? = nil
    ) {
        self.store = store
        self.state = state
        self.curator = curator
        self.token = token
        self.logPath = logPath
        self.probe = probe
    }

    public func respond(to request: EndpointRequest) async -> EndpointResponse {
        guard request.token == token else { return .error(401, "not authorized") }

        // `/health` is the one route that never touches the store: it is how a process that could not open
        // one still tells the truth, and the reason the process stays up at all.
        if request.method == "GET", request.path == "/health" { return await health() }

        // Every other route needs the store, so its absence is asked about once, here, before any of them.
        guard case .open(let db, _) = store, let curator else { return noStore() }

        do {
            // A store can enter a failed state while this process is up, and nothing else here would notice:
            // the same cheap read `openStore` runs at start is run before the work. A fatal is reported up —
            // never swallowed, and never a decision made in the router — so `/health` can say so.
            if let probe { try await probe(db) }
            switch (request.method, request.path) {
            case ("POST", "/capture"):
                return try await capture(request, db: db, curator: curator)
            case ("GET", "/context"):
                return try await context(request, db: db)
            case ("GET", "/proposals"):
                return try await proposals(db: db)
            case ("GET", "/memories"):
                return try await memories(request, db: db)
            case ("GET", "/migrated"):
                return try await migrated(request, db: db)
            case ("POST", "/admin/import"):
                return try await importHistory(request, db: db)
            case ("POST", "/admin/restart"):
                return try await restart()
            case ("POST", let path) where path.hasPrefix("/proposals/"):
                return try await act(on: path, body: request.body, db: db)
            default:
                return miss(request)
            }
        } catch let error as NorvoError where error.code == .fatal {
            // The engine has declared the store failed: record it and tell the agent, which is the one that can
            // log it and ask for a clean process. This request still gets its 500 — it is the request that found
            // the failure — but `/health` keeps answering with the truth from here on.
            await state.reportFatal(Self.oneLine(error))
            return .error(500, Self.oneLine(error))
        } catch {
            // A failure is a response, never a crash: the endpoint must not take the backend down with it.
            return .error(500, Self.oneLine(error))
        }
    }

    /// One line, and the file that has the rest. A client that reached a storeless backend learns that it
    /// cannot answer and where to look, rather than getting a 500 it cannot tell from a broken store, or a
    /// connection that drops as if the process had died.
    ///
    /// The store could not be opened rather than *is closed*: the only way to have no store is to have failed
    /// to open one — nothing closes a working store without the process ending.
    private func noStore() -> EndpointResponse {
        .error(503, "this backend could not open its store at \(state.storePath); see \(logPath)")
    }

    /// The queue is the truth; the state mirrors it, so the status item and the next reader agree. With no
    /// store open there is nothing to mirror: the state already holds the truth — `failed` — and reading a
    /// store that is not there is exactly what must not happen on the one route a person can still reach.
    private func health() async -> EndpointResponse {
        do {
            // A store the engine has declared failed is not read again: the queue's depth cannot be mirrored
            // from a store that will not answer, and `/health` — the one route a person can still reach — must
            // keep answering with the truth it already holds rather than turning into a 500 no client can tell
            // apart from a dead backend.
            if case .open(let db, _) = store, await state.storeIsOpen {
                await state.setBacklogDepth(try await undrainedCount(db))
            }
            if let curator {
                await state.setCuratorState(curator.curatorState)
                // The producer's failure count travels with the curator state: a model that is not answering
                // costs each drain its ambient memory while the store stays healthy, so `/health` green is not
                // enough, and nothing else on the wire says a producer is down rather than idle.
                await state.setFilerFailures(curator.filerFailures)
            }
            return try .json(await state.health())
        } catch {
            return .error(500, Self.oneLine(error))
        }
    }

    private func capture(
        _ request: EndpointRequest, db: Database, curator: CuratorController
    ) async throws -> EndpointResponse {
        let event = try EndpointWire.decoder().decode(NormalizedEvent.self, from: request.body)
        let capture = MusaiCapture(db: db)
        let outcome: CaptureOutcome
        switch event.kind {
        case .userTurn: outcome = try await captureUserTurn(event, capture)
        case .agentTurn: outcome = try await captureAgentTurn(event, capture)
        case .toolUse: outcome = try await captureToolUse(event, capture)
        default: outcome = .ignored
        }
        if outcome == .created {
            // The event is durable; the drain is not this caller's problem. It runs debounced, off the
            // request path, so a slow model never delays a capture.
            await curator.noteCapture()
            await state.setBacklogDepth(try await undrainedCount(db))
        }
        return try .json(CaptureReply(stored: outcome))
    }

    /// The person's words, kept verbatim. Whether the row is new is told by the count, because the capture
    /// returns the utterance's id either way.
    private func captureUserTurn(_ event: NormalizedEvent, _ capture: MusaiCapture) async throws -> CaptureOutcome {
        guard let text = event.text, !text.isEmpty else { return .ignored }
        let before = try await utterances(in: event.session, db: capture.db)
        _ = try await capture.captureUserTurn(
            text: text, at: event.at, origin: nil, session: event.session, cwd: event.cwd,
            as: MusaiActors.curator)
        return try await utterances(in: event.session, db: capture.db) > before ? .created : .duplicate
    }

    /// The agent's own account of its turn; the capture returns nil when it already has this one.
    private func captureAgentTurn(_ event: NormalizedEvent, _ capture: MusaiCapture) async throws -> CaptureOutcome {
        guard let text = event.text, !text.isEmpty else { return .ignored }
        let made = try await capture.captureAgentTurn(
            text: text, at: event.at, session: event.session, cwd: event.cwd, as: MusaiActors.curator)
        return made == nil ? .duplicate : .created
    }

    /// A tool use, as a reference: what ran and on what, never what it produced.
    private func captureToolUse(_ event: NormalizedEvent, _ capture: MusaiCapture) async throws -> CaptureOutcome {
        guard let tool = event.tool, !tool.isEmpty else { return .ignored }
        let before = try await toolUses(in: event.session, db: capture.db)
        try await capture.captureToolUse(
            tool: tool, target: event.target, digest: event.digest, at: event.at, session: event.session,
            cwd: event.cwd, as: MusaiActors.curator)
        return try await toolUses(in: event.session, db: capture.db) > before ? .created : .duplicate
    }

    private func context(_ request: EndpointRequest, db: Database) async throws -> EndpointResponse {
        guard let cwd = request.query["cwd"], !cwd.isEmpty else { return .error(400, "cwd is required") }
        // A read must not write: a typo'd cwd gets nothing to say, not a junk project.
        guard let project = try await ProjectBinder(db: db).knownProject(cwd: URL(fileURLWithPath: cwd)),
            let text = try await MusaiSlice.render(project: project, db: db)
        else { return .text("") }
        return .text(text)
    }

    /// What `musai review` lists, and the window app will show: the gap first, then what awaits
    /// confirmation.
    private func proposals(db: Database) async throws -> EndpointResponse {
        let review = ReviewSession(db: db)
        let reply = ProposalsReply(gap: try await review.unpersisted(), pending: try await review.pending())
        return try .json(reply)
    }

    /// `GET /memories` — what a person half remembers.
    ///
    /// The query is chosen by what the request gives: a `q` searches the store's full text over `Memory.text`;
    /// a `project` with no `q` lists that project's memories, newest first; neither lists the memories bound to
    /// no project, which is most of an imported corpus. Nothing found is an empty list with a 200, never an
    /// error — a search that matches nothing and a project that does not exist are both ordinary answers.
    ///
    /// A `q` and a `project` together search only that project's memories: the filter is the search's own, so a
    /// project hit ranked below the whole-store bound is still found rather than silently missed.
    private func memories(_ request: EndpointRequest, db: Database) async throws -> EndpointResponse {
        let query = request.query["q"]
        let project = request.query["project"].flatMap { $0.isEmpty ? nil : $0 }
        let found: [MemorySummary]
        if let query, !query.isEmpty {
            found = try await searched(query, project: project, db: db)
        } else if let project {
            found = try await db.query(MemoriesForProjectQuery(.init(slug: project))).memories.map {
                Self.summary($0)
            }
        } else {
            found = try await db.query(MemoriesWithoutProjectQuery()).memories.map { Self.summary($0) }
        }
        return try .json(MemoriesReply(memories: found))
    }

    /// The full-text hits, as the reply's shape.
    ///
    /// The search's projection carries each hit's whole summary — widened from the fields that merely rank it,
    /// so a hit need not be read back by id. `project` is the engine's own filter, so the ranking walks far
    /// enough into the project's hits to fill the bound.
    private func searched(_ q: String, project: String?, db: Database) async throws -> [MemorySummary] {
        let filter = project.map { ProjectWhere(slug: StringFilter(eq: $0)) }
        return try await db.query(SearchMemoriesQuery(.init(q: q, project: filter))).memoriesConnection.edges
            .map { Self.summary($0.node) }
    }

    /// `GET /migrated` — the imported, one-sided history, in the view of its own. Separate from `/proposals`
    /// so that live review is never buried under an import, and a `MigratedProposal` rather than a `Proposal`
    /// because claude-mem recorded no utterance for these: there is no `said` to carry.
    ///
    /// Every migrated row the import writes carries its `origin`, which is what a person traces it back by; the
    /// empty string is only for a row that somehow has none, so one old row cannot fail the whole view.
    ///
    /// The answer is bounded — `first` is optional and capped — because the real corpus yields ~6 900 migrated
    /// proposals, and it says whether it is showing all of them. That is known by **fetching one more than it
    /// returns**: the query has no count, and the one extra row is the whole of `hasMore`.
    private func migrated(_ request: EndpointRequest, db: Database) async throws -> EndpointResponse {
        let first = Self.boundedFirst(request.query["first"])
        let rows = try await db.query(MigratedDecisionsQuery(.init(first: first + 1))).decisions
        let reply = MigratedReply(
            proposals: rows.prefix(first).map {
                MigratedProposal(id: $0.id, title: $0.title, act: $0.act, origin: $0.origin ?? "")
            },
            hasMore: rows.count > first)
        return try .json(reply)
    }

    /// `POST /admin/import` — one pass of the import, over the corpus the body names.
    ///
    /// **One request is one pass** — one batch per stage, exactly as `MusaiImport.run` defines it, and
    /// deliberately never a loop to exhaustion. This endpoint serves one request at a time, so a request that
    /// imported a whole 1 GB corpus would hold that slot and block every *capture* — every hook — for as long
    /// as it ran. One pass per request is what keeps the import short, resumable and idle-friendly, and
    /// `musai import` is what repeats it until a pass reports nothing left.
    ///
    /// The route opens no store: it writes through the database the agent already holds, the one this endpoint
    /// serves from, because exactly one process may have the store open and the engine refuses a second opener
    /// on the same file. The corpus is a *different* file, opened read-only by `ClaudeMemReader`, and the
    /// import never writes to it. A dry run writes nothing at all, cursors included.
    private func importHistory(_ request: EndpointRequest, db: Database) async throws -> EndpointResponse {
        struct Body: Codable {
            let source: String
            let dryRun: Bool?
        }
        // A body that is not the shape this protocol promised is the client's mistake, not a failed import.
        guard let body = try? EndpointWire.decoder().decode(Body.self, from: request.body),
            !body.source.isEmpty
        else { return .error(400, "source is required") }
        let importer = MusaiImport(
            db: db, reader: try ClaudeMemReader(url: URL(fileURLWithPath: body.source)),
            discovery: ImportDiscovery(db: db), as: MusaiActors.migrator("claude-mem"))
        return try .json(ImportReportReply(report: try await importer.run(dryRun: body.dryRun ?? false)))
    }

    /// `POST /proposals/{id}/{settle|persist|drop}` — one action, applied as the person.
    private func act(on path: String, body: Data, db: Database) async throws -> EndpointResponse {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 3, let id = UUID(uuidString: parts[1]) else {
            return .error(404, "no such route")
        }
        let review = ReviewSession(db: db)
        switch parts[2] {
        case "settle":
            try await review.apply(.settle, to: id, as: MusaiActors.user)
        case "persist":
            let reference = try EndpointWire.decoder().decode(PersistBody.self, from: body).documentRef
            guard !reference.isEmpty else { return .error(400, "documentRef is required") }
            try await review.apply(.persist(documentRef: reference), to: id, as: MusaiActors.user)
        case "drop":
            // A drop leaves nothing to read back, so it is told apart from a decision that never was by
            // looking before acting.
            let existing = try await db.query(DecisionByIDQuery(.init(id: id))).decision
            guard existing != nil else { return .error(404, "no such decision") }
            try await review.apply(.drop, to: id, as: MusaiActors.user)
            return try .json(DecisionReply(id: id, state: "DROPPED", documentRef: nil))
        default:
            return .error(404, "no such route")
        }
        // The route's answer is the decision's new state, read back from the store rather than assumed.
        let row = try await db.query(DecisionByIDQuery(.init(id: id))).decision
        guard let row else { return .error(404, "no such decision") }
        return try .json(DecisionReply(id: id, state: row.state.rawValue, documentRef: row.documentRef))
    }

    private func restart() async throws -> EndpointResponse {
        // Answering is this process's job; ending itself is the agent's (Task 5), which watches for the
        // request through the state and restarts under launchd.
        await state.requestRestart()
        let reply = ["acknowledged": true] as [String: Bool]
        return try .json(reply)
    }

    /// A path we serve under another method is a 405; a path we do not serve at all is a 404.
    private func miss(_ request: EndpointRequest) -> EndpointResponse {
        let known = [
            "/health", "/capture", "/context", "/proposals", "/memories", "/migrated", "/admin/restart",
            "/admin/import",
        ].contains(request.path) || Self.isProposalAction(request.path)
        return known ? .error(405, "method not allowed") : .error(404, "no such route")
    }

    private static func isProposalAction(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "proposals", UUID(uuidString: parts[1]) != nil else {
            return false
        }
        return ["settle", "persist", "drop"].contains(parts[2])
    }

    /// One memory row as the wire's summary. Each listing's row type is its own — the engine generates one per
    /// query — so each is turned into the one shape a client reads; a row whose `project` is absent means the
    /// memory belongs to no project, which the summary says by `nil` rather than by omission.
    private static func summary(_ row: MemoriesForProjectQuery.Data.Memories) -> MemorySummary {
        summary(
            id: row.id, text: row.text, kind: row.kind, origin: row.origin, provenance: row.provenance,
            project: row.project?.slug)
    }

    private static func summary(_ row: MemoriesWithoutProjectQuery.Data.Memories) -> MemorySummary {
        summary(
            id: row.id, text: row.text, kind: row.kind, origin: row.origin, provenance: row.provenance,
            project: row.project?.slug)
    }

    private static func summary(_ hit: SearchMemoriesQuery.Data.MemoriesConnection.Edges.Node_) -> MemorySummary {
        summary(
            id: hit.id, text: hit.text, kind: hit.kind, origin: hit.origin, provenance: hit.provenance,
            project: hit.project?.slug)
    }

    private static func summary(
        id: UUID, text: String?, kind: MemoryKind, origin: MemoryOrigin, provenance: String?,
        project: String?
    ) -> MemorySummary {
        MemorySummary(
            id: id, text: text, kind: kind, origin: origin, provenance: provenance, project: project)
    }

    /// What `musai review --migrated` shows without asking: a page a person reads at a glance.
    private static let migratedFirst = 50
    /// The most one request may ask for. The endpoint serves one request at a time, and there are ~6 900
    /// migrated proposals, so the bound keeps a paging surface from walking the whole backlog in one read.
    /// The view's own paging advice reads it, so a person is never sent to a `--first` the endpoint clamps
    /// straight back to the page they are already looking at.
    public static let migratedFirstCap = 500

    /// `first` as the request gave it, within the bound. Absent or unreadable is the default; a non-positive
    /// number is read as 1, and anything over the cap is the cap, so every clamped input keeps `hasMore` honest.
    private static func boundedFirst(_ raw: String?) -> Int {
        guard let raw, let asked = Int(raw) else { return migratedFirst }
        return min(max(asked, 1), migratedFirstCap)
    }

    private func undrainedCount(_ db: Database) async throws -> Int {
        // `first` is a bound the backlog should never reach; a health report must not lie about a failure.
        try await db.query(UndrainedEventsQuery(.init(first: 1_000_000))).events.count
    }

    private func utterances(in session: String, db: Database) async throws -> Int {
        try await db.query(UtterancesForSessionQuery(.init(session: session))).utterances.count
    }

    private func toolUses(in session: String, db: Database) async throws -> Int {
        try await db.query(EventsForSessionQuery(.init(session: session))).events
            .filter { $0.kind == .toolUse }.count
    }

    /// The one line of a failure a client will read, cut before the engine's stack dump.
    private static func oneLine(_ error: any Error) -> String {
        let text = String(describing: error)
        return text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "failed"
    }

    /// The reference a `persist` records where the decision landed.
    private struct PersistBody: Codable {
        let documentRef: String
    }
}
