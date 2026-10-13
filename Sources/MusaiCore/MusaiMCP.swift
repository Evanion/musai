import Foundation

/// The backend, reached by an agent as a client: one JSON-RPC message in, one out (or `nil` for a
/// notification), over stdio. It proxies the endpoint's two read tools — the slice, and the decisions that
/// were settled and recorded nowhere — and it is a pure function of one message: the caller re-reads the
/// record and the token for each one, so a long-lived server is never pinned to a port the agent has since
/// left behind.
///
/// It exists with **no client at all**, which is a state a host has to be able to read: a host connects and
/// asks to `initialize` before the backend is necessarily running, and that — and `tools/list` — answer
/// regardless. A tool call with no backend is a **tool error**, not a crash: the server stays up, because
/// the agent's session must outlive the backend's absence.
public struct MusaiMCP: Sendable {
    /// The MCP revision this server speaks. It is a version of the *MCP* protocol, not of Musai's endpoint
    /// protocol, and it is the revision the hosts in the wild negotiate.
    public static let protocolVersion = "2024-11-05"

    /// What `initialize` names this server. The version is the build's own, so a host and a person read the
    /// same number in the handshake as in the bundle.
    public static let serverName = "musai"

    /// The one line a tool error carries when there is no backend to ask. It names the fix, because a
    /// failure an agent cannot act on is only half a report.
    public static let notRunning = "the Musai backend is not running; run `musai install`"

    /// The client this server proxies to, or `nil` when the backend is not running. `nil` is a state, not an
    /// error: the handshake answers without it.
    private let client: MusaiClient?

    public init(client: MusaiClient?) {
        self.client = client
    }

    /// One message in, one out. `nil` is a message that is not answered — a notification — and never a
    /// failure: a failure is a JSON-RPC error or a tool error, either of which is something the host can
    /// read.
    public func handle(_ message: Data) async -> Data? {
        guard let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any] else {
            return Self.error(id: NSNull(), code: -32700, message: "parse error")
        }
        guard let method = object["method"] as? String else {
            return Self.error(
                id: object["id"] ?? NSNull(), code: -32600, message: "invalid request: no method")
        }
        // A message without an id is a notification: JSON-RPC answers it with silence, whatever it asks.
        let id = object["id"]
        let params = object["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return Self.reply(id: id, result: Self.handshake)
        case "tools/list":
            return Self.reply(id: id, result: ["tools": Self.tools])
        case "tools/call":
            return Self.reply(id: id, result: await callTool(params))
        case "notifications/initialized":
            return nil
        default:
            guard let id else { return nil }
            return Self.error(id: id, code: -32601, message: "method not found: \(method)")
        }
    }

    // MARK: - The tools

    /// What one tool call becomes. Every failure here is a tool error — a result the model reads and can act
    /// on — rather than a JSON-RPC error: the backend being down is a fact about the world, not a mistake in
    /// the request.
    private func callTool(_ params: [String: Any]) async -> [String: Any] {
        guard let name = params["name"] as? String else {
            return Self.toolError("tools/call needs a tool name")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        guard let client else { return Self.toolError(Self.notRunning) }

        do {
            switch name {
            case "context":
                guard let cwd = arguments["cwd"] as? String, !cwd.isEmpty else {
                    return Self.toolError("context needs a cwd: the working directory the slice is for")
                }
                // An empty slice is silence, and the endpoint says it as an empty body: the agent is told
                // there is nothing to say rather than handed an error to interpret.
                return Self.toolResult(try await client.context(cwd: cwd) ?? "")
            case "decisions":
                return Self.toolResult(Self.json(try await client.gap()))
            default:
                return Self.toolError("no such tool: \(name)")
            }
        } catch {
            return Self.toolError(Self.describe(error))
        }
    }

    /// The two tools, and the arguments a host will show its model. The `decisions` tool takes no argument:
    /// the endpoint's read is the store's, not one project's.
    private static var tools: [[String: Any]] {
        [
            [
                "name": "context",
                "description":
                    "The slice of Musai memory for a working directory: what this project has settled and "
                    + "learned so far, as a short text. Empty when Musai has nothing to say there.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "cwd": [
                            "type": "string",
                            "description": "The absolute path of the working directory the slice is for.",
                        ] as [String: Any]
                    ],
                    "required": ["cwd"],
                ] as [String: Any],
            ],
            [
                "name": "decisions",
                "description":
                    "The decisions settled and recorded nowhere, as JSON: the risk Musai's loop exists to "
                    + "surface, because nothing durable holds them yet.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:] as [String: Any],
                ] as [String: Any],
            ],
        ]
    }

    private static var handshake: [String: Any] {
        [
            "protocolVersion": protocolVersion,
            "capabilities": ["tools": [:] as [String: Any]],
            "serverInfo": ["name": serverName, "version": MusaiBundle.version],
        ]
    }

    // MARK: - The wire

    private static func reply(id: Any?, result: [String: Any]) -> Data? {
        // No id is no answer: a notification is only ever a notification.
        guard let id else { return nil }
        return encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func error(id: Any, code: Int, message: String) -> Data? {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private static func toolResult(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text] as [String: Any]]]
    }

    private static func toolError(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message] as [String: Any]], "isError": true]
    }

    /// The reply as bytes. The shapes here are all JSON values, so `JSONSerialization` cannot fail; a
    /// `nil` would be a programming error, and it is answered with silence rather than a crash.
    private static func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object)
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        guard let data = try? EndpointWire.encoder().encode(value) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// A client's failure as one line an agent can act on: the reason, and the fix where there is one.
    private static func describe(_ error: any Error) -> String {
        guard case let failure as MusaiClient.Failure = error else { return oneLine(error) }
        switch failure {
        case .unreachable:
            return notRunning
        case .incompatibleProtocol(let helper, let expected):
            return "the Musai backend speaks protocol \(helper) and this musai speaks \(expected); "
                + "run `musai install` so the two match"
        case .unexpectedStatus(let status, let body):
            // A storeless backend answers 503 with one line naming the log; it is passed through whole,
            // because that line is the whole reason the person can fix it.
            return "the Musai backend answered \(status): \(body)"
        case .malformedResponse(let detail):
            return "the Musai backend's reply could not be read: \(detail)"
        }
    }

    /// The one line of a failure, cut before a stack dump.
    private static func oneLine(_ error: any Error) -> String {
        let text = String(describing: error)
        return text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "failed"
    }
}
