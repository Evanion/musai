import Foundation

/// The protocol's shape: the types every client shares, in one place, because the endpoint serves them and
/// Task 3's client consumes them.
public enum EndpointWire {
    /// `major.minor`. A client refuses a different major and reports it; a different minor is additive,
    /// because the protocol only grows.
    public static let protocolVersion = "1.0"

    /// Every date on the wire is ISO 8601, so what a person reads in a log and what a client reads agree.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// One request, already parsed — the router is pure, so a test drives it without a socket and Task 2's
/// listener can serve it unchanged. `token` is the bearer the caller presented: every route checks it,
/// `/health` included, because a stranger on the machine must not learn so much as the store's path.
public struct EndpointRequest: Sendable, Equatable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let body: Data
    public let token: String

    public init(
        method: String, path: String, query: [String: String] = [:], body: Data = Data(), token: String
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.token = token
    }
}

/// One response: a status, a body, and what the body is.
public struct EndpointResponse: Sendable, Equatable {
    public let status: Int
    public let body: Data
    public let contentType: String

    public init(status: Int, body: Data, contentType: String = "application/json") {
        self.status = status
        self.body = body
        self.contentType = contentType
    }

    public static func json<T: Encodable>(_ value: T, status: Int = 200) throws -> EndpointResponse {
        EndpointResponse(
            status: status, body: try EndpointWire.encoder().encode(value),
            contentType: "application/json")
    }

    /// The slice is plain text; an empty body is "nothing to say", not an error.
    public static func text(_ text: String, status: Int = 200) -> EndpointResponse {
        EndpointResponse(
            status: status, body: Data(text.utf8), contentType: "text/plain; charset=utf-8")
    }

    /// A client's diagnostic is one line, so it never breaks the host's session.
    public static func error(_ status: Int, _ message: String) -> EndpointResponse {
        struct ErrorReply: Codable { let error: String }
        let body = (try? EndpointWire.encoder().encode(ErrorReply(error: message)))
            ?? Data(#"{"error":"unprintable"}"#.utf8)
        return EndpointResponse(status: status, body: body, contentType: "application/json")
    }
}

/// One already-normalized capture — the `POST /capture` body. Host adaptation is the client's business
/// (Task 3): the endpoint knows nothing about Claude Code, and a new host is a new adapter, not a backend
/// change.
public struct NormalizedEvent: Sendable, Equatable, Codable {
    public let kind: EventKind
    public let session: String
    public let cwd: String
    public let at: Date
    public let text: String?
    public let tool: String?
    public let target: String?
    public let digest: String?

    public init(
        kind: EventKind, session: String, cwd: String, at: Date, text: String? = nil, tool: String? = nil,
        target: String? = nil, digest: String? = nil
    ) {
        self.kind = kind
        self.session = session
        self.cwd = cwd
        self.at = at
        self.text = text
        self.tool = tool
        self.target = target
        self.digest = digest
    }
}

/// What `POST /capture` did.
public enum CaptureOutcome: String, Sendable, Codable {
    /// A new row, durable before the reply went out.
    case created
    /// The same event, already held: a retried hook, not a second turn.
    case duplicate
    /// Nothing was stored — an empty turn, or a kind the store does not keep.
    case ignored
}

/// The `POST /capture` body: `{"stored": …}`.
public struct CaptureReply: Sendable, Equatable, Codable {
    public let stored: CaptureOutcome

    public init(stored: CaptureOutcome) { self.stored = stored }
}

/// The `GET /health` body: what a client needs to know before it trusts the backend with a person's words.
public struct EndpointHealth: Sendable, Equatable, Codable {
    public let protocolVersion: String
    public let storePath: String
    public let startedAt: Date
    public let storeState: StoreState
    public let backlogDepth: Int
    public let curatorState: CuratorState

    public init(
        protocolVersion: String, storePath: String, startedAt: Date, storeState: StoreState,
        backlogDepth: Int, curatorState: CuratorState
    ) {
        self.protocolVersion = protocolVersion
        self.storePath = storePath
        self.startedAt = startedAt
        self.storeState = storeState
        self.backlogDepth = backlogDepth
        self.curatorState = curatorState
    }
}

/// The `GET /proposals` body: the gap first — that is the risk the person came to see — then what awaits
/// confirmation.
public struct ProposalsReply: Sendable, Equatable, Codable {
    public let gap: [Gap]
    public let pending: [Proposal]

    public init(gap: [Gap], pending: [Proposal]) {
        self.gap = gap
        self.pending = pending
    }
}

/// The `POST /proposals/{id}/{action}` body: the decision's new state. `DROPPED` is the wire's word for a
/// decision the store no longer holds.
public struct DecisionReply: Sendable, Equatable, Codable {
    public let id: UUID
    public let state: String
    public let documentRef: String?

    public init(id: UUID, state: String, documentRef: String?) {
        self.id = id
        self.state = state
        self.documentRef = documentRef
    }
}