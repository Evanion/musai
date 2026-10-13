import Foundation
import Testing
@testable import MusaiCore

/// `MusaiMCP` is one JSON-RPC message in and one out, proxying the backend's two read tools to an agent that
/// reaches Musai as a client. The backend here is the real endpoint behind the real listener (Task 2), so
/// these tests exercise the proxy and not a stub of it.
@Suite struct MCPTests {
    private let at = Date(timeIntervalSince1970: 1_700_000_000)
    private let cwd = "/tmp/musai-mcp"

    // MARK: - Driving it

    private func request(_ id: Int, _ method: String, _ params: [String: Any] = [:]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "id": id, "method": method, "params": params] as [String: Any])
    }

    private func call(_ name: String, _ arguments: [String: Any]) throws -> Data {
        try request(11, "tools/call", ["name": name, "arguments": arguments] as [String: Any])
    }

    /// One message out, decoded. A `nil` here is a finding: these are all requests, and every request is
    /// answered.
    private func response(_ server: MusaiMCP, _ message: Data) async throws -> [String: Any] {
        let data = await server.handle(message)
        let unwrapped = try #require(data)
        let object = try JSONSerialization.jsonObject(with: unwrapped)
        return try #require(object as? [String: Any])
    }

    private func outcome(of reply: [String: Any]) throws -> [String: Any] {
        try #require(reply["result"] as? [String: Any])
    }

    /// The text one tool result carries, concatenated across its content blocks.
    private func text(_ result: [String: Any]) throws -> String {
        let content = try #require(result["content"] as? [[String: Any]])
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// A settled decision — the gap — and a proposal still awaiting one, filed under one project.
    private func seedReview(_ backend: BackendFixture) async throws -> (settled: String, pending: String) {
        let capture = MusaiCapture(db: backend.library.db)
        let said = try await capture.captureUserTurn(
            text: "we will use one Norvo file", at: at, origin: "claude", session: "s1", cwd: cwd,
            as: MusaiActors.curator)
        let slug = try #require(
            try await backend.library.db.query(ProjectByRootQuery(.init(root: cwd))).projects.first?.slug)
        let proposal = try await backend.library.db.mutate(
            RecordProposalMutation(
                .init(title: "One Norvo file", rationale: nil, act: .decision, utterance: said, project: slug)),
            as: MusaiActors.curator)
        try await ReviewSession(db: backend.library.db).apply(
            .settle, to: proposal.createDecision.id, as: MusaiActors.user)

        let other = try await capture.captureUserTurn(
            text: "and something else", at: at.addingTimeInterval(1), origin: "claude", session: "s1",
            cwd: cwd, as: MusaiActors.curator)
        _ = try await backend.library.db.mutate(
            RecordProposalMutation(
                .init(
                    title: "Something still awaiting a decision", rationale: nil, act: .proposal,
                    utterance: other, project: slug)),
            as: MusaiActors.curator)
        return (settled: "One Norvo file", pending: "Something still awaiting a decision")
    }

    // MARK: - The handshake

    @Test func initializeNamesTheServerAndItsTools() async throws {
        // No client: a host connects and initialises before the backend is necessarily running, and this
        // must answer regardless.
        let server = MusaiMCP(client: nil)
        let reply = try await response(server, request(1, "initialize", ["clientInfo": ["name": "claude"]]))

        #expect(reply["jsonrpc"] as? String == "2.0")
        #expect(reply["id"] as? Int == 1)
        let result = try outcome(of: reply)
        #expect(result["protocolVersion"] is String)
        let capabilities = try #require(result["capabilities"] as? [String: Any])
        #expect(capabilities["tools"] != nil)

        let serverInfo = try #require(result["serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == "musai")
        #expect(serverInfo["version"] is String)
    }

    @Test func toolsListHasContextAndDecisions() async throws {
        let server = MusaiMCP(client: nil)
        let reply = try await response(server, request(2, "tools/list"))

        let tools = try #require(try outcome(of: reply)["tools"] as? [[String: Any]])
        #expect(tools.count == 2)
        #expect(tools.compactMap { $0["name"] as? String }.sorted() == ["context", "decisions"])

        for tool in tools {
            #expect(tool["description"] is String)
            let schema = try #require(tool["inputSchema"] as? [String: Any])
            #expect(schema["type"] as? String == "object")
        }
        // The slice is asked for by the directory it is for.
        let context = try #require(tools.first { $0["name"] as? String == "context" })
        let schema = try #require(context["inputSchema"] as? [String: Any])
        #expect((schema["required"] as? [String])?.contains("cwd") == true)
    }

    // MARK: - The tools

    @Test func callingContextReturnsTheSlice() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        let seeded = try await seedReview(backend)

        let server = MusaiMCP(client: MusaiClient(record: backend.record(), token: BackendFixture.token))
        let reply = try await response(server, call("context", ["cwd": cwd]))
        let result = try outcome(of: reply)

        #expect((result["isError"] as? Bool) != true)
        #expect(try text(result).contains(seeded.settled))

        // A directory the backend knows nothing about says nothing, and says it as a tool result, not an
        // error the agent has to interpret. It says nothing *for that directory*: the argument is the
        // question, not decoration.
        let nowhere = try outcome(of: try await response(server, call("context", ["cwd": "/tmp/musai-mcp-nothing"])))
        #expect((nowhere["isError"] as? Bool) != true)
        #expect(!(try text(nowhere)).contains(seeded.settled))
    }

    @Test func callingDecisionsReturnsTheProjectsDecisions() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        let seeded = try await seedReview(backend)

        let server = MusaiMCP(client: MusaiClient(record: backend.record(), token: BackendFixture.token))
        let result = try outcome(of: try await response(server, call("decisions", [:])))

        #expect((result["isError"] as? Bool) != true)
        let decisions = try text(result)
        #expect(decisions.contains(seeded.settled))
        // Filtered to what was settled and recorded nowhere: the proposal still awaiting a decision is not a
        // decision yet.
        #expect(!decisions.contains(seeded.pending))
    }

    // MARK: - The protocol's edges

    @Test func anUnknownMethodIsAJSONRPCError() async throws {
        let server = MusaiMCP(client: nil)
        let reply = try await response(server, request(9, "does/not/exist"))

        #expect(reply["result"] == nil)
        let error = try #require(reply["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32601)
        #expect(reply["id"] as? Int == 9)

        // A request's failure is answered; a notification, which has no id, is never answered — the
        // `Data?` a caller reads has to be safe to be nil.
        let notification = try JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "method": "does/not/exist"] as [String: Any])
        #expect(await server.handle(notification) == nil)
    }

    @Test func aNotificationProducesNoResponse() async throws {
        let server = MusaiMCP(client: nil)
        let notification = try JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "method": "notifications/initialized", "params": [:]] as [String: Any])

        #expect(await server.handle(notification) == nil)
    }

    @Test func aToolCallAgainstADeadPortIsAToolErrorAndTheServerStaysUp() async throws {
        // The long-lived server is never pinned to a port: the agent restarted under it, and the record it
        // was built from names a port nothing owns. That is a tool error the agent can read, not a crash and
        // not the end of the session.
        let backend = try await BackendFixture.make()
        let stale = backend.record()
        backend.close()

        let server = MusaiMCP(client: MusaiClient(record: stale, token: BackendFixture.token))
        let result = try outcome(of: try await response(server, call("context", ["cwd": cwd])))
        #expect(result["isError"] as? Bool == true)
        #expect(try text(result).contains("musai install"))

        // The server stayed up: the next message is answered as if nothing had happened.
        let listed = try await response(server, request(5, "tools/list"))
        #expect(try outcome(of: listed)["tools"] != nil)

        // No client at all — the host connected before the backend was ever running — is the same answer.
        let cold = try outcome(of: try await response(MusaiMCP(client: nil), call("decisions", [:])))
        #expect(cold["isError"] as? Bool == true)
        #expect(try text(cold).contains("musai install"))
    }
}
