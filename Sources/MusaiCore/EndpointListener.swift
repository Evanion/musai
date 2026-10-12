import Foundation
import Network

/// Serves `MusaiEndpoint` over a loopback socket: parse one HTTP/1.1 request, hand it to the router, write the
/// reply, close. It holds no protocol logic — the router is pure and answers the same whether a test calls
/// it directly or a client reaches it here — so this file is the only place a socket exists.
public final class EndpointListener: @unchecked Sendable {
    /// A body larger than this is refused from its headers, never read: the bound matches a hook payload's,
    /// and a client that declares an endless body must get an answer rather than hold the connection open.
    public static let maxBodyBytes = 32 << 20
    /// Headers are far smaller than this; the bound only stops a client that never sends the blank line.
    private static let maxHeaderBytes = 64 << 10
    private static let readChunk = 64 << 10

    private let endpoint: MusaiEndpoint
    private let host: String
    private let requestedPort: UInt16
    private let queue = DispatchQueue(label: "dev.musai.endpoint.listener")

    /// `listener` and `connections` are touched from the network queue, the per-connection tasks, and
    /// `start`/`stop`, so they are guarded by one lock.
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    public init(endpoint: MusaiEndpoint, host: String = "127.0.0.1", port: UInt16 = 0) {
        self.endpoint = endpoint
        self.host = host
        self.requestedPort = port
    }

    deinit { stop() }

    /// Binds the loopback port and returns it. With `port` 0 the system chooses, so the return value — not the
    /// requested port — is what the caller publishes in the record; that is the whole reason a client can
    /// find the backend at all.
    @discardableResult
    public func start() throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: requestedPort) ?? .any)
        let listener = try NWListener(using: parameters)

        let outcome = Outcome()
        let ready = DispatchSemaphore(value: 0)
        let fixedPort = requestedPort != 0
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if outcome.settle(nil) { ready.signal() }
            case .failed(let error):
                if outcome.settle(error) { ready.signal() }
            case .waiting(let error):
                // A fixed port that cannot be bound waits rather than fails, and a hand-started second agent
                // (or a listener in a test) must be told no rather than hang. A system-chosen port does not wait.
                if fixedPort, outcome.settle(error) { ready.signal() }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)

        // `start` is synchronous, so the calling thread waits here for the bind; the network queue is a
        // different one, so nothing deadlocks.
        guard ready.wait(timeout: .now() + 5) == .success else {
            listener.cancel()
            throw ListenerError.notReady
        }
        if let error = outcome.error {
            listener.cancel()
            throw error
        }
        lock.lock()
        self.listener = listener
        lock.unlock()
        return listener.port?.rawValue ?? requestedPort
    }

    /// Cancels the listener and every open connection. The port is released; a record still naming it is the
    /// agent's to remove, because only the agent knows where it was written.
    public func stop() {
        lock.lock()
        let listener = self.listener
        self.listener = nil
        let open = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        listener?.cancel()
        for connection in open { connection.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections[ObjectIdentifier(connection)] = connection
        lock.unlock()
        connection.start(queue: queue)
        Task { [weak self] in
            guard let self else { return }
            await self.serve(connection)
            connection.cancel()
            self.forget(connection)
        }
    }

    private func forget(_ connection: NWConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
    }

    private func serve(_ connection: NWConnection) async {
        do {
            let request = try await readRequest(from: connection)
            let response = await endpoint.respond(to: request)
            try await send(response, on: connection)
        } catch let refusal as Refusal {
            // A malformed or oversized request still gets an answer: silence would leave the client waiting.
            try? await send(refusal.response, on: connection)
        } catch {
            // The peer went away, or the socket failed: there is nothing to answer.
        }
    }

    // MARK: - One request

    private func readRequest(from connection: NWConnection) async throws -> EndpointRequest {
        let marker = Data("\r\n\r\n".utf8)
        var buffer = Data()
        while buffer.range(of: marker) == nil {
            if buffer.count > Self.maxHeaderBytes { throw Refusal.malformed }
            let chunk = try await receive(from: connection)
            if chunk.isEmpty { throw Refusal.malformed }
            buffer.append(chunk)
        }
        guard let end = buffer.range(of: marker) else { throw Refusal.malformed }
        let head = try Self.parseHead(buffer[buffer.startIndex..<end.lowerBound])
        // Refused from the headers alone: reading a body this large is exactly the read that must not happen.
        if head.contentLength > Self.maxBodyBytes { throw Refusal.tooLarge }

        var body = Data(buffer[end.upperBound...])
        while body.count < head.contentLength {
            let chunk = try await receive(from: connection)
            if chunk.isEmpty { throw Refusal.malformed }
            body.append(chunk)
        }
        return EndpointRequest(
            method: head.method, path: head.path, query: head.query,
            body: body.prefix(head.contentLength), token: head.token)
    }

    private func receive(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: Self.readChunk) {
                data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
    }

    private func send(_ response: EndpointResponse, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: Self.serialize(response), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private static func serialize(_ response: EndpointResponse) -> Data {
        var head = "HTTP/1.1 \(response.status) \(reason(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var data = Data(head.utf8)
        data.append(response.body)
        return data
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        case 500: "Internal Server Error"
        default: "OK"
        }
    }

    // MARK: - Parsing

    private struct Head {
        let method: String
        let path: String
        let query: [String: String]
        let token: String
        let contentLength: Int
    }

    private static func parseHead(_ bytes: Data) throws -> Head {
        guard let text = String(data: bytes, encoding: .utf8) else { throw Refusal.malformed }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { throw Refusal.malformed }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { throw Refusal.malformed }
        let (path, query) = splitTarget(String(parts[1]))

        var contentLength = 0
        var token = ""
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "content-length":
                guard let length = Int(value), length >= 0 else { throw Refusal.malformed }
                contentLength = length
            case "authorization":
                if value.lowercased().hasPrefix("bearer ") { token = String(value.dropFirst(7)) }
            default:
                break
            }
        }
        return Head(
            method: String(parts[0]), path: path, query: query, token: token,
            contentLength: contentLength)
    }

    /// `/context?cwd=%2Ftmp%2Fx` into its path and its decoded query — a client percent-encodes, so the
    /// router must see the original.
    private static func splitTarget(_ target: String) -> (String, [String: String]) {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = pieces.first.map(String.init) ?? ""
        var query: [String: String] = [:]
        if pieces.count == 2 {
            for pair in pieces[1].split(separator: "&", omittingEmptySubsequences: true) {
                let halves = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let rawKey = halves.first.map(String.init),
                    let key = rawKey.removingPercentEncoding, !key.isEmpty
                else { continue }
                let rawValue = halves.count == 2 ? String(halves[1]) : ""
                query[key] = rawValue.removingPercentEncoding ?? rawValue
            }
        }
        return (rawPath.removingPercentEncoding ?? rawPath, query)
    }

    /// A request the listener answers itself, because waiting for the rest of it would be the bug.
    private struct Refusal: Error {
        let response: EndpointResponse

        static let malformed = Refusal(response: .error(400, "malformed request"))
        static let tooLarge = Refusal(response: .error(413, "request body too large"))
    }

    /// The bind's first outcome, carried from the network queue back to the thread waiting in `start`. First
    /// wins, so a later `.cancelled` cannot overwrite a `.ready`; a `nil` error is success.
    private final class Outcome: @unchecked Sendable {
        private let lock = NSLock()
        private var settled = false
        private var failure: Error?

        @discardableResult
        func settle(_ error: Error?) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !settled else { return false }
            settled = true
            failure = error
            return true
        }

        var error: Error? {
            lock.lock()
            defer { lock.unlock() }
            return failure
        }
    }

    public enum ListenerError: Error {
        /// The bind neither succeeded nor failed within the wait.
        case notReady
    }
}
