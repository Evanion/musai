import Foundation
import NorvoLite

/// The backend's whole protocol, one request at a time: a pure router from `EndpointRequest` to
/// `EndpointResponse`. It owns nothing — the store is the agent's, the curator runs in its own controller —
/// so a test drives the whole protocol without a socket, and Task 2's listener can serve it unchanged.
public struct MusaiEndpoint: Sendable {
    /// What the queries and captures take.
    public let db: Database
    /// The library that owns the store this endpoint serves; held so the owner outlives the requests.
    public let library: MusaiLibrary
    public let state: EndpointState
    public let curator: CuratorController
    /// Every request must carry this. A stranger on the machine gets a 401 and learns nothing — not even
    /// the store's path, which is why `/health` checks it too.
    public let token: String

    public init(
        db: Database, library: MusaiLibrary, state: EndpointState, curator: CuratorController, token: String
    ) {
        self.db = db
        self.library = library
        self.state = state
        self.curator = curator
        self.token = token
    }

    public func respond(to request: EndpointRequest) async -> EndpointResponse {
        guard request.token == token else { return .error(401, "not authorized") }
        do {
            switch (request.method, request.path) {
            case ("GET", "/health"):
                return try await health()
            case ("POST", "/capture"):
                return try await capture(request)
            case ("GET", "/context"):
                return try await context(request)
            case ("GET", "/proposals"):
                return try await proposals()
            case ("POST", "/admin/restart"):
                return try await restart()
            case ("POST", let path) where path.hasPrefix("/proposals/"):
                return try await act(on: path, body: request.body)
            default:
                return miss(request)
            }
        } catch {
            // A failure is a response, never a crash: the endpoint must not take the backend down with it.
            return .error(500, Self.oneLine(error))
        }
    }

    /// The queue is the truth; the state mirrors it, so the status item and the next reader agree.
    private func health() async throws -> EndpointResponse {
        await state.setBacklogDepth(try await undrainedCount())
        await state.setCuratorState(curator.curatorState)
        let health = await state.health()
        return try .json(health)
    }

    private func capture(_ request: EndpointRequest) async throws -> EndpointResponse {
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
            await state.setBacklogDepth(try await undrainedCount())
        }
        return try .json(CaptureReply(stored: outcome))
    }

    /// The person's words, kept verbatim. Whether the row is new is told by the count, because the capture
    /// returns the utterance's id either way.
    private func captureUserTurn(_ event: NormalizedEvent, _ capture: MusaiCapture) async throws -> CaptureOutcome {
        guard let text = event.text, !text.isEmpty else { return .ignored }
        let before = try await utterances(in: event.session)
        _ = try await capture.captureUserTurn(
            text: text, at: event.at, origin: nil, session: event.session, cwd: event.cwd,
            as: MusaiActors.curator)
        return try await utterances(in: event.session) > before ? .created : .duplicate
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
        let before = try await toolUses(in: event.session)
        try await capture.captureToolUse(
            tool: tool, target: event.target, digest: event.digest, at: event.at, session: event.session,
            cwd: event.cwd, as: MusaiActors.curator)
        return try await toolUses(in: event.session) > before ? .created : .duplicate
    }

    private func context(_ request: EndpointRequest) async throws -> EndpointResponse {
        guard let cwd = request.query["cwd"], !cwd.isEmpty else { return .error(400, "cwd is required") }
        // A read must not write: a typo'd cwd gets nothing to say, not a junk project.
        guard let project = try await ProjectBinder(db: db).knownProject(cwd: URL(fileURLWithPath: cwd)),
            let text = try await MusaiSlice.render(project: project, db: db)
        else { return .text("") }
        return .text(text)
    }

    /// What `musai review` lists, and the window app will show: the gap first, then what awaits
    /// confirmation.
    private func proposals() async throws -> EndpointResponse {
        let review = ReviewSession(db: db)
        let reply = ProposalsReply(gap: try await review.unpersisted(), pending: try await review.pending())
        return try .json(reply)
    }

    /// `POST /proposals/{id}/{settle|persist|drop}` — one action, applied as the person.
    private func act(on path: String, body: Data) async throws -> EndpointResponse {
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
        let known = ["/health", "/capture", "/context", "/proposals", "/admin/restart"].contains(request.path)
            || Self.isProposalAction(request.path)
        return known ? .error(405, "method not allowed") : .error(404, "no such route")
    }

    private static func isProposalAction(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "proposals", UUID(uuidString: parts[1]) != nil else {
            return false
        }
        return ["settle", "persist", "drop"].contains(parts[2])
    }

    private func undrainedCount() async throws -> Int {
        // `first` is a bound the backlog should never reach; a health report must not lie about a failure.
        try await db.query(UndrainedEventsQuery(.init(first: 1_000_000))).events.count
    }

    private func utterances(in session: String) async throws -> Int {
        try await db.query(UtterancesForSessionQuery(.init(session: session))).utterances.count
    }

    private func toolUses(in session: String) async throws -> Int {
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