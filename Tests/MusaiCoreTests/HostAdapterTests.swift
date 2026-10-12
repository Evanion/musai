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
}
