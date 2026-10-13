import Foundation

/// A client of the backend: one request to the port the record names, with the token it was given. It never
/// opens the store and never starts anything — when the backend is not there it says so, so the caller can ask
/// launchd to start it, and never posts a person's words into a port the record no longer owns.
public struct MusaiClient: Sendable {
    /// Why a call could not be made. A failure is reported, never guessed at.
    public enum Failure: Error, Equatable {
        /// Nothing answered at the recorded port — a stale record, or no backend at all.
        case unreachable
        /// The backend speaks another major protocol. A minor difference is additive; a major one is not.
        case incompatibleProtocol(helper: String, expected: String)
        /// The backend answered with a status this client does not read.
        case unexpectedStatus(Int, String)
        /// The backend's body was not the shape this protocol promised.
        case malformedResponse(String)
    }

    public let record: HelperRecord
    public let token: String

    /// The handshake a caller already made, if it made one. When present it is reused rather than re-fetched,
    /// so a client that checked `/health` before it posted pays for that check only once.
    private let handshake: EndpointHealth?

    private let baseURL: URL
    private let session: URLSession

    public init(record: HelperRecord, token: String, handshake: EndpointHealth? = nil) {
        self.record = record
        self.token = token
        self.handshake = handshake
        self.baseURL = URL(string: "http://127.0.0.1:\(record.port)")!
        self.session = .shared
    }

    /// Whether a helper advertising `protocolVersion` speaks a protocol this client understands: the same
    /// major. A different minor is additive, because the protocol only grows.
    public static func accepts(protocolVersion: String) -> Bool {
        guard let ours = major(of: EndpointWire.protocolVersion),
            let theirs = major(of: protocolVersion)
        else { return false }
        return ours == theirs
    }

    /// What the backend knows about itself, or `nil` when nothing answers at the recorded port. A `nil` is the
    /// caller's cue to start the agent — a fact, not something a retry loop should hide.
    public func health() async -> EndpointHealth? {
        guard let (data, response) = try? await get(path: "health", query: [:]),
            response.statusCode == 200,
            let health = try? EndpointWire.decoder().decode(EndpointHealth.self, from: data)
        else { return nil }
        return health
    }

    /// The `POST /capture` body, already normalized by the host adapter. Throws before sending when the helper
    /// advertises a protocol this client cannot speak, so a mismatched helper's store is never written.
    public func capture(_ event: NormalizedEvent) async throws -> CaptureOutcome {
        try await ensureCompatible()
        let (data, response) = try await post(
            path: "capture", body: try EndpointWire.encoder().encode(event))
        try ensureSuccess(response, data)
        return try decode(CaptureReply.self, from: data).stored
    }

    /// The slice for a working directory, or `nil` when the backend has nothing to say there. An empty body is
    /// silence, not an error.
    public func context(cwd: String) async throws -> String? {
        try await ensureCompatible()
        let (data, response) = try await get(path: "context", query: ["cwd": cwd])
        try ensureSuccess(response, data)
        let text = String(decoding: data, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    /// The proposals awaiting a decision. The gap is a different question, asked separately.
    public func proposals() async throws -> [Proposal] {
        try await proposalsReply().pending
    }

    /// The decisions settled and recorded nowhere: the risk review exists to surface.
    public func gap() async throws -> [Gap] {
        try await proposalsReply().gap
    }

    /// One action, applied as the person. `skip` is the absence of an action, so it never reaches the wire.
    public func apply(_ action: ReviewAction, to id: UUID) async throws {
        try await ensureCompatible()
        switch action {
        case .skip:
            return
        case .settle:
            try await act(on: "\(id.uuidString)/settle", body: Data())
        case .persist(let documentRef):
            struct Body: Encodable { let documentRef: String }
            try await act(on: "\(id.uuidString)/persist", body: try EndpointWire.encoder().encode(Body(documentRef: documentRef)))
        case .drop:
            try await act(on: "\(id.uuidString)/drop", body: Data())
        }
    }

    // MARK: - The wire

    private func proposalsReply() async throws -> ProposalsReply {
        try await ensureCompatible()
        let (data, response) = try await get(path: "proposals", query: [:])
        try ensureSuccess(response, data)
        return try decode(ProposalsReply.self, from: data)
    }

    private func act(on action: String, body: Data) async throws {
        let (data, response) = try await post(path: "proposals/\(action)", body: body)
        try ensureSuccess(response, data)
    }

    /// Every route holds the same bound: the record's advertised major and the live helper's must both be the
    /// one this client speaks. The record alone is unsafe one way — a helper upgraded past the record's word
    /// would be posted to — so the handshake is checked too, reusing a caller's handshake when it made one.
    private func ensureCompatible() async throws {
        try requireCompatible(record.protocolVersion)
        let live: EndpointHealth?
        if let handshake { live = handshake } else { live = await health() }
        guard let live else { throw Failure.unreachable }
        try requireCompatible(live.protocolVersion)
    }

    private func requireCompatible(_ version: String) throws {
        guard Self.accepts(protocolVersion: version) else {
            throw Failure.incompatibleProtocol(
                helper: version, expected: EndpointWire.protocolVersion)
        }
    }

    private func get(path: String, query: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(
            url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await perform(request)
    }

    private func post(path: String, body: Data) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.unreachable }
            return (data, http)
        } catch let failure as Failure {
            throw failure
        } catch {
            // The port refused, the connection dropped, or the host is gone: the record is stale.
            throw Failure.unreachable
        }
    }

    private func ensureSuccess(_ response: HTTPURLResponse, _ data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            throw Failure.unexpectedStatus(response.statusCode, String(decoding: data, as: UTF8.self))
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try EndpointWire.decoder().decode(type, from: data)
        } catch {
            throw Failure.malformedResponse(Self.oneLine(error))
        }
    }

    /// The major component of a `major.minor` version.
    private static func major(of version: String) -> Int? {
        Int(version.split(separator: ".").first.map(String.init) ?? "")
    }

    /// The one line of a failure a person will read, cut before a stack dump.
    private static func oneLine(_ error: any Error) -> String {
        let text = String(describing: error)
        return text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "failed"
    }
}
