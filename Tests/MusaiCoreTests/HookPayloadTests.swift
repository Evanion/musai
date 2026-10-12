import Foundation
import Testing
@testable import MusaiCore

@Suite struct HookPayloadTests {
    @Test func aUserPromptSubmitPayloadDecodesItsTurn() throws {
        let json = """
        {"session_id":"s1","transcript_path":"/tmp/t.jsonl","cwd":"/tmp/musai-hook",
         "permission_mode":"ask","hook_event_name":"UserPromptSubmit","user_prompt":"do the thing"}
        """
        let payload = try HookPayload.decode(Data(json.utf8))
        #expect(payload.event == "UserPromptSubmit")
        #expect(payload.sessionId == "s1")
        #expect(payload.cwd == "/tmp/musai-hook")
        #expect(payload.prompt == "do the thing")
    }

    @Test func aToolResultIsNotCarried() throws {
        let json = """
        {"session_id":"s1","cwd":"/tmp/musai-hook","hook_event_name":"PostToolUse",
         "tool_name":"Edit","tool_input":{"file_path":"a.swift"},"tool_result":"WHOLE FILE CONTENTS"}
        """
        let payload = try HookPayload.decode(Data(json.utf8))
        #expect(payload.toolName == "Edit")
        #expect(payload.toolTarget == "a.swift")
        // The payload carries a result and `HookPayload` has no way to hand it on. The end-to-end test in
        // Task 10 is what proves the store itself never sees it.
        #expect(payload.capturesToolResult == false)
    }

    @Test func aMalformedOrUnexpectedPayloadNeverBreaksTheSession() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let runner = HookRunner(capture: MusaiCapture(db: lib.db), library: lib)
        let bad: [String] = [
            "{not json",
            #"{"hook_event_name":"Stop","cwd":"/tmp"}"#,
            "{}",
        ]
        for stdin in bad {
            let outcome = await runner.run(event: nil, stdin: Data(stdin.utf8), cwd: "/tmp/musai-hook")
            #expect(outcome.stdout == nil)
            #expect(outcome.diagnostic != nil)
        }

        // An event the host adds later, which we do not implement.
        let unknown = await runner.run(
            event: "SomethingNew", stdin: Data(#"{"session_id":"s1","cwd":"/tmp"}"#.utf8), cwd: "/tmp")
        #expect(unknown.stdout == nil)
        #expect(unknown.diagnostic == nil)
    }
    @Test func aPayloadMissingItsSessionIsRejected() {
        #expect(throws: (any Error).self) {
            try HookPayload.decode(Data(#"{"hook_event_name":"Stop","cwd":"/tmp"}"#.utf8))
        }
    }
}
