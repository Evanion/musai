import Foundation
import Testing
@testable import MusaiCore

/// Answers every request with one decision about the first turn, so the Stop path's real drain runs offline.
private struct OneDecisionTransport: ModelTransport {
    func send(_ request: URLRequest, body: Data) async throws -> Data {
        let content = #"{"decisions":[{"title":"One Norvo file","rationale":"said so","act":"DECISION","utterance_index":0}]}"#
        let object: [String: Any] = ["choices": [["message": ["content": content]]]]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }
}

@Suite struct LoopEndToEndTests {
    private func payload(
        _ event: String, cwd: String, session: String, prompt: String? = nil, tool: String? = nil,
        target: String? = nil, result: String? = nil, transcript: String? = nil
    ) -> Data {
        var object: [String: Any] = ["hook_event_name": event, "cwd": cwd, "session_id": session]
        if let prompt { object["user_prompt"] = prompt }
        if let tool { object["tool_name"] = tool }
        if let target { object["tool_input"] = ["file_path": target] }
        if let result { object["tool_result"] = result }
        if let transcript { object["transcript_path"] = transcript }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    @Test func theLoopRunsFromATurnToTheNextSession() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let runner = HookRunner(
            capture: MusaiCapture(db: lib.db), library: lib,
            provider: OpenAICompatibleProvider(
                configuration: .default, transport: OneDecisionTransport()))
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-loop-\(UUID().uuidString)/Project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let cwd = root.path

        // 1. A first session start says nothing at all.
        let first = await runner.run(
            event: nil, stdin: payload("SessionStart", cwd: cwd, session: "s1"), cwd: cwd)
        #expect(first.stdout == nil)
        #expect(first.diagnostic == nil)

        // 2. The person's turn is kept once, even though the hook fires twice.
        let turn = payload("UserPromptSubmit", cwd: cwd, session: "s1", prompt: "we will use one Norvo file")
        _ = await runner.run(event: nil, stdin: turn, cwd: cwd)
        _ = await runner.run(event: nil, stdin: turn, cwd: cwd)
        let utterances = try await lib.db.query(UtterancesForSessionQuery(.init(session: "s1"))).utterances
        #expect(utterances.count == 1)
        #expect(utterances.first?.text == "we will use one Norvo file")

        // 3. A tool use keeps the reference and never the result.
        _ = await runner.run(
            event: nil,
            stdin: payload(
                "PostToolUse", cwd: cwd, session: "s1", tool: "Edit", target: "a.swift",
                result: "WHOLE FILE CONTENTS"),
            cwd: cwd)
        let events = try await lib.db.query(EventsForSessionQuery(.init(session: "s1"))).events
        let toolEvent = events.first { $0.kind == .toolUse }
        #expect(toolEvent?.tool == "Edit")
        #expect(toolEvent?.target == "a.swift")
        #expect(toolEvent?.text == nil)
        #expect(events.contains { ($0.text ?? "").contains("WHOLE FILE CONTENTS") } == false)

        // 4. The agent's own last message, from the transcript the Stop hook hands over.
        let transcript = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-loop-\(UUID().uuidString).jsonl")
        try #"{"type":"assistant","message":{"content":[{"type":"text","text":"I changed a.swift"}]}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: transcript) }
        _ = await runner.run(
            event: nil,
            stdin: payload("Stop", cwd: cwd, session: "s1", transcript: transcript.path),
            cwd: cwd)
        let afterStop = try await lib.db.query(EventsForSessionQuery(.init(session: "s1"))).events
        #expect(afterStop.first { $0.kind == .agentTurn }?.text == "I changed a.swift")

        // 5. The Stop hook above already drained the queue through the detector, offline.
        #expect(try await lib.db.query(UndrainedEventsQuery()).events.isEmpty)

        // 6. One keystroke, and it is recorded where it landed.
        let review = ReviewSession(db: lib.db)
        let pending = try await review.pending()
        #expect(pending.map(\.title) == ["One Norvo file"])
        let decision = try #require(pending.first)
        try await review.apply(.persist(documentRef: "commit:abc"), to: decision.id, as: MusaiActors.user)

        // 7. The next session starts with it.
        let next = await runner.run(
            event: nil, stdin: payload("SessionStart", cwd: cwd, session: "s2"), cwd: cwd)
        #expect(next.stdout?.contains("One Norvo file") == true)
        #expect(next.stdout?.contains("commit:abc") == true)
        #expect(next.stdout?.contains("hookSpecificOutput") == true)

        // 8. And the gap is empty.
        #expect(try await review.unpersisted().isEmpty)
    }
}
