import CryptoKit
import Foundation
import MusaiCore

/// Everything Claude Code knows that the core does not: how a host payload is decoded, what a `Stop`'s
/// transcript says, and how an event becomes a normalized one. It lives in the CLI because knowing a host is
/// the CLI's job; MusaiCore knows no host at all, and a new host is a new adapter here, not a backend change.
enum HostAdapter {
    /// The host's payload, decoded. Throws `HookPayload.Failure` for a malformed body or a missing session.
    static func payload(_ stdin: Data) throws -> HookPayload {
        try HookPayload.decode(stdin)
    }

    /// The events one payload becomes. `event` is the name the command was called with, and it wins over the
    /// payload's own because the installed hook names the event; an event we do not implement becomes none.
    static func events(for payload: HookPayload, at date: Date, event: String? = nil) throws -> [NormalizedEvent] {
        let session = payload.sessionId ?? ""
        let cwd = payload.cwd ?? ""
        switch event ?? payload.event {
        case "UserPromptSubmit":
            guard let prompt = payload.prompt, !prompt.isEmpty else { return [] }
            return [NormalizedEvent(kind: .userTurn, session: session, cwd: cwd, at: date, text: prompt)]
        case "PostToolUse":
            guard let tool = payload.toolName, !tool.isEmpty else { return [] }
            return [
                NormalizedEvent(
                    kind: .toolUse, session: session, cwd: cwd, at: date, tool: tool,
                    target: payload.toolTarget, digest: digest(tool, payload.toolTarget))
            ]
        case "Stop":
            // The agent's own account of its turn, from the file the host hands over. Only the text is taken —
            // never a tool call, never a tool's result.
            var text: String?
            if let path = payload.transcriptPath, !path.isEmpty {
                text = try? TranscriptTail.lastAssistantText(at: URL(fileURLWithPath: path))
            }
            return [NormalizedEvent(kind: .agentTurn, session: session, cwd: cwd, at: date, text: text)]
        default:
            return []
        }
    }

    /// The same tool on the same target twice is one digest, so a retried hook is recognisable without
    /// storing what the tool produced.
    static func digest(_ tool: String, _ target: String?) -> String {
        let material = tool + "\u{1F}" + (target ?? "")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The host's own stdout shape for the session-start hook. It lives with the adapter rather than in
    /// `MusaiCore`, because a new host needs a different shape and the core knows no host at all.
    static func additionalContext(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            case let control where control.value < 0x20:
                escaped += String(format: "\\u%04x", control.value)
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return #"{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":["\#(escaped)"]}}"#
    }
}

/// What one hook invocation hands back: stdout for the host, or a one-line diagnostic for the log. It never
/// throws, because a hook that fails must not fail the session it reports on.
struct HookOutcome: Sendable, Equatable {
    let stdout: String?
    let diagnostic: String?

    static let silent = HookOutcome(stdout: nil, diagnostic: nil)
}

/// Dispatches one hook invocation to the backend through a client. The dispatch table mirrors the host's
/// events; the store is the agent's, reached only over the socket.
struct HookDispatch: Sendable {
    let client: MusaiClient

    func run(event: String?, stdin: Data, cwd: String, at: Date = Date()) async -> HookOutcome {
        do {
            let payload = try HostAdapter.payload(stdin)
            // `SessionStart` hands the agent the slice; a store with nothing to say stays quiet.
            if (event ?? payload.event) == "SessionStart" {
                guard let text = try await client.context(cwd: payload.cwd ?? cwd) else { return .silent }
                return HookOutcome(stdout: HostAdapter.additionalContext(text), diagnostic: nil)
            }
            for normalized in try HostAdapter.events(for: payload, at: at, event: event) {
                _ = try await client.capture(normalized)
            }
            return .silent
        } catch {
            return HookOutcome(stdout: nil, diagnostic: "musai: \(oneLine(error))")
        }
    }
}

/// The one line of a failure a person will read, cut before a stack dump.
func oneLine(_ error: any Error) -> String {
    let text = String(describing: error)
    return text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "failed"
}
