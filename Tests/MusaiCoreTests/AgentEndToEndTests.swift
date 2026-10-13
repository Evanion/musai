import Foundation
import Testing
import MusaiCore
@testable import musai

/// A model call the test can hold open. `enter` blocks until `release`, and once released every later call
/// returns at once — so the first drain is slow in exactly one place and nothing else waits. `entries` is
/// read by the test rather than waited on, so a loop that never reaches the model fails in seconds instead
/// of parking a test forever.
private actor ModelGate {
    private var count = 0
    private var released = false
    private var parked: [CheckedContinuation<Void, Never>] = []

    var entries: Int { count }

    func enter() async {
        count += 1
        if released { return }
        await withCheckedContinuation { parked.append($0) }
    }

    func release() {
        released = true
        let waiting = parked
        parked = []
        for waiter in waiting { waiter.resume() }
    }
}

/// The model behind the agent's curator, stubbed so no network is touched. The first call answers with one
/// decision about the person's first turn; later calls answer with nothing, so the loop's own re-drain of a
/// late capture cannot file a second proposal.
private actor StubTransport: ModelTransport {
    private let gate: ModelGate
    private var calls = 0

    init(gate: ModelGate) { self.gate = gate }

    func send(_ request: URLRequest, body: Data) async throws -> Data {
        calls += 1
        let first = calls == 1
        await gate.enter()
        let content =
            first
            ? #"{"decisions":[{"title":"One Norvo file","rationale":"said so","act":"DECISION","utterance_index":0}]}"#
            : #"{"decisions":[]}"#
        let object: [String: Any] = ["choices": [["message": ["content": content]]]]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}

/// The acceptance test of the slice: a real agent owns a temporary store, and the whole loop runs through a
/// client and the endpoint — the person's words in, a proposal out, one keystroke to record it, and the next
/// session handed the decision and where it landed. Nothing here opens the store: the agent is the one
/// process, and every assertion is made over the wire, the way a client has to.
@Suite struct AgentEndToEndTests {
    private let at = Date(timeIntervalSince1970: 1_700_000_000)

    /// What the host hands one hook invocation, decoded by the adapter the way the `musai hook` command does
    /// — the result of a tool use included, so "it is never stored" is about a payload that really carries it.
    private func event(
        _ name: String, cwd: String, session: String, prompt: String? = nil, tool: String? = nil,
        target: String? = nil, result: String? = nil, transcript: String? = nil
    ) throws -> NormalizedEvent {
        var object: [String: Any] = ["hook_event_name": name, "cwd": cwd, "session_id": session]
        if let prompt { object["user_prompt"] = prompt }
        if let tool { object["tool_name"] = tool }
        if let target { object["tool_input"] = ["file_path": target] }
        if let result { object["tool_result"] = result }
        if let transcript { object["transcript_path"] = transcript }
        let payload = try HostAdapter.payload(try JSONSerialization.data(withJSONObject: object))
        return try #require(try HostAdapter.events(for: payload, at: at, event: name).first)
    }

    /// Polls rather than sleeping a fixed time, so a concurrent result is picked up as soon as it exists.
    private func eventually(_ condition: @Sendable () async throws -> Bool) async throws {
        for _ in 0..<300 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition did not hold in time")
    }

    @Test func theLoopRunsThroughTheAgentToTheNextSession() async throws {
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-agent-e2e-\(UUID().uuidString)")
        let store = sandbox.appending(path: "Musai.norvo")
        let gate = ModelGate()
        let windows = WindowGate()
        let detector = ModelDecisionDetector(
            provider: OpenAICompatibleProvider(
                configuration: .default, transport: StubTransport(gate: gate)))
        // The log goes beside the store, not into the developer's real `~/Library/Logs/Musai`.
        let agent = try MusaiAgent(
            libraryURL: store, detector: detector, logURL: sandbox.appending(path: "helper.log"),
            sleep: { _ in await windows.nap() }, debounce: 1)
        defer {
            agent.stop()
            try? FileManager.default.removeItem(at: sandbox)
        }
        _ = try await agent.start()

        // The client finds the backend the way every client does: through the record the agent published
        // beside the store, and the token inside it.
        let record = try HelperRecord.read(from: agent.recordURL)
        let token = try #require(MusaiToken.read(at: agent.tokenURL))
        let client = MusaiClient(record: record, token: token)

        let root = sandbox.appending(path: "Project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cwd = root.path

        // 1. A directory the backend has never seen has nothing to say, and says it as an empty body.
        #expect(try await client.context(cwd: cwd) == nil)

        // 2. The person's turn, as the host hands it over, is kept whole.
        let said = "we will use one Norvo file"
        let turn = try event("UserPromptSubmit", cwd: cwd, session: "s1", prompt: said)
        #expect(turn.kind == .userTurn)
        #expect(turn.text == said)
        #expect(try await client.capture(turn) == .created)

        // 3. A tool use travels as a reference: the result is in the payload and has nowhere to go, so it
        //    never reaches the wire at all.
        let tool = try event(
            "PostToolUse", cwd: cwd, session: "s1", tool: "Edit", target: "a.swift",
            result: "WHOLE FILE CONTENTS")
        #expect(tool.kind == .toolUse)
        #expect(tool.tool == "Edit")
        #expect(tool.target == "a.swift")
        #expect(tool.text == nil)

        // 4. The agent's own account of its turn, from the transcript the Stop hook hands over.
        let transcript = sandbox.appending(path: "transcript.jsonl")
        try #"{"type":"assistant","message":{"content":[{"type":"text","text":"I changed a.swift"}]}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        let stop = try event("Stop", cwd: cwd, session: "s1", transcript: transcript.path)
        #expect(stop.kind == .agentTurn)
        #expect(stop.text == "I changed a.swift")

        #expect(try await client.capture(tool) == .created)
        #expect(try await client.capture(stop) == .created)

        // Nothing was lost: all three captures are in the queue, waiting for the agent's own drain — the
        // debounce has not been let through yet.
        let queued = try #require(await client.health())
        #expect(queued.backlogDepth == 3)
        #expect(queued.storeState == .open)

        // 5. The agent's drain, on the debounce window this test hands over. The first model call is held
        //    open, so what follows lands while the model is busy.
        try await eventually { await windows.opened == 1 }
        await windows.openWindows()
        try await eventually { await gate.entries == 1 }

        // Review Focus 5: a capture that arrives mid-drain is stored and answered at once — the queue grows
        // rather than the request waiting, and the drain's own next pass picks it up. Dropping it here would
        // be a person's turn lost.
        let during = NormalizedEvent(
            kind: .userTurn, session: "s1", cwd: cwd, at: at.addingTimeInterval(1), text: "one file, not two")
        #expect(try await client.capture(during) == .created)
        let waiting = try #require(await client.health())
        #expect(waiting.backlogDepth == 4)
        #expect(waiting.curatorState == .pending)

        await gate.release()

        // 6. The drain finishes: one proposal, built from the person's own words, and the queue empty.
        try await eventually {
            let pending = try await client.proposals()
            let health = await client.health()
            return pending.count == 1 && health?.backlogDepth == 0
        }
        let proposal = try #require(try await client.proposals().first)
        #expect(proposal.title == "One Norvo file")
        #expect(proposal.said == said)

        // 7. One keystroke, and where it landed is recorded.
        try await client.apply(.persist(documentRef: "commit:abc"), to: proposal.id)

        // 8. The next session is handed the decision and its reference.
        let next = try #require(try await client.context(cwd: cwd))
        #expect(next.contains("One Norvo file"))
        #expect(next.contains("commit:abc"))

        // 9. And nothing is left settled-but-unrecorded.
        #expect(try await client.gap().isEmpty)
    }
}
