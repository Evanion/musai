import Foundation
import Testing
import MusaiCore
@testable import musai

/// The host's payloads become normalized events here and nowhere else: MusaiCore never learns Claude Code's
/// shape, so these tests live with the adapter, in the CLI.
@Suite struct HostAdapterTests {
    private let at = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func aUserPromptBecomesOneUserTurn() throws {
        let payload = try HostAdapter.payload(Data("""
            {"session_id":"s1","cwd":"/tmp/musai-host","hook_event_name":"UserPromptSubmit",
             "user_prompt":"do the thing"}
            """.utf8))
        let events = try HostAdapter.events(for: payload, at: at)
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.kind == .userTurn)
        #expect(event.text == "do the thing")
        #expect(event.session == "s1")
        #expect(event.cwd == "/tmp/musai-host")
        #expect(event.at == at)
        #expect(event.tool == nil)
    }

    @Test func aToolUseKeepsTheReferenceAndNeverTheResult() throws {
        let payload = try HostAdapter.payload(Data("""
            {"session_id":"s1","cwd":"/tmp/musai-host","hook_event_name":"PostToolUse",
             "tool_name":"Edit","tool_input":{"file_path":"a.swift"},"tool_result":"WHOLE FILE CONTENTS"}
            """.utf8))
        let events = try HostAdapter.events(for: payload, at: at)
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.kind == .toolUse)
        #expect(event.tool == "Edit")
        #expect(event.target == "a.swift")
        // The result is in the payload and there is nowhere for it to go: a tool use is a reference, never
        // what the tool produced.
        #expect(event.text == nil)
        #expect(event.digest == HostAdapter.digest("Edit", "a.swift"))
    }

    @Test func aStopReadsTheTranscriptsLastMessage() throws {
        let transcript = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-host-\(UUID().uuidString).jsonl")
        try #"{"type":"assistant","message":{"content":[{"type":"text","text":"I changed a.swift"}]}}"#
            .write(to: transcript, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: transcript) }

        let payload = try HostAdapter.payload(Data("""
            {"session_id":"s1","cwd":"/tmp/musai-host","hook_event_name":"Stop",
             "transcript_path":"\(transcript.path)"}
            """.utf8))
        let events = try HostAdapter.events(for: payload, at: at)
        #expect(events.count == 1)
        let event = try #require(events.first)
        #expect(event.kind == .agentTurn)
        #expect(event.text == "I changed a.swift")
    }

    @Test func anUnknownEventBecomesNoEvents() throws {
        let payload = try HostAdapter.payload(
            Data(#"{"session_id":"s1","cwd":"/tmp/musai-host","hook_event_name":"SomethingNew"}"#.utf8))
        #expect(try HostAdapter.events(for: payload, at: at).isEmpty)
    }

    /// The host's stdout shape is the adapter's, so the test that a control character in the slice cannot
    /// break it lives here with the shape rather than with `MusaiCore`.
    @Test func controlCharactersInATitleCannotBreakTheHandover() async throws {
        let library = try await MusaiLibrary.inMemory()
        _ = try await library.db.mutate(
            CreateProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user)
        let said = try await MusaiCapture(db: library.db).captureUserTurn(
            text: "we will use one Norvo file", at: at, origin: "claude", session: "s1",
            cwd: "/tmp/musai-host", as: MusaiActors.curator)
        let id = try await library.db.mutate(
            RecordProposalMutation(.init(
                title: "tabs\tand\rreturns", rationale: nil, act: .constraint,
                utterance: said, project: "musai")),
            as: MusaiActors.curator).createDecision.id
        _ = try await library.db.mutate(
            PersistDecisionOutsideMutation(.init(id: id, documentRef: "docs/\ta.swift", persistedAt: Date())),
            as: MusaiActors.user)

        let text = try #require(try await MusaiSlice.render(project: "musai", budget: 2_000, db: library.db))
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(HostAdapter.additionalContext(text).utf8))
                as? [String: Any])
        let specific = json["hookSpecificOutput"] as? [String: Any]
        let context = try #require(specific?["additionalContext"] as? [String])
        #expect(context.first?.contains("tabs\tand") == true)
    }
}
