import Foundation
import Testing
@testable import MusaiCore
@testable import musai

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
        // The payload carries a result and `HookPayload` has no way to hand it on; the end-to-end test proves
        // the store itself never sees it.
        #expect(payload.capturesToolResult == false)
    }

    /// The property is unchanged: a malformed or missing-session payload must never break the host's session.
    /// The machinery is new — the adapter decodes, the client posts over a real socket — and the session goes
    /// on to store a valid turn.
    @Test func aMalformedOrUnexpectedPayloadNeverBreaksTheSession() async throws {
        let backend = try await BackendFixture.make()
        defer { backend.close() }
        let dispatch = HookDispatch(
            client: MusaiClient(record: backend.record(), token: BackendFixture.token))

        let bad: [String] = [
            "{not json",
            #"{"hook_event_name":"Stop","cwd":"/tmp"}"#,
            "{}",
        ]
        for stdin in bad {
            let outcome = await dispatch.run(event: nil, stdin: Data(stdin.utf8), cwd: "/tmp/musai-hook")
            #expect(outcome.stdout == nil)
            #expect(outcome.diagnostic != nil)
        }

        // An event the host adds later, which we do not implement.
        let unknown = await dispatch.run(
            event: "SomethingNew", stdin: Data(#"{"session_id":"s1","cwd":"/tmp"}"#.utf8), cwd: "/tmp")
        #expect(unknown.stdout == nil)
        #expect(unknown.diagnostic == nil)

        // The bad payloads left the store alone.
        let before = try await backend.library.db.query(EventsForSessionQuery(.init(session: "s1"))).events
        #expect(before.isEmpty)

        // And the session carries on: a valid turn still reaches the store, through the adapter, the client and
        // the socket.
        let good = await dispatch.run(
            event: nil,
            stdin: Data(
                #"{"session_id":"s1","cwd":"/tmp/musai-hook","hook_event_name":"UserPromptSubmit","user_prompt":"do the thing"}"#
                    .utf8),
            cwd: "/tmp/musai-hook")
        #expect(good.stdout == nil)
        #expect(good.diagnostic == nil)
        let rows = try await backend.library.db.query(UtterancesForSessionQuery(.init(session: "s1"))).utterances
        #expect(rows.map(\.text) == ["do the thing"])
    }

    @Test func aPayloadMissingItsSessionIsRejected() {
        #expect(throws: (any Error).self) {
            try HookPayload.decode(Data(#"{"hook_event_name":"Stop","cwd":"/tmp"}"#.utf8))
        }
    }
}
