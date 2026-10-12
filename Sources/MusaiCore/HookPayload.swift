import Foundation

/// One hook invocation's payload, as the host hands it over on stdin.
///
/// The fields are Claude Code 2.1.295's: a common set of `session_id`, `transcript_path`, `cwd`,
/// `permission_mode`, `hook_event_name`, plus `user_prompt` on `UserPromptSubmit`,
/// `tool_name`/`tool_input`/`tool_result` on `PostToolUse`, and `reason` on `Stop`.
public struct HookPayload: Sendable, Equatable {
    public enum Failure: Error { case malformed, missingSession }

    public let event: String?
    public let sessionId: String?
    public let cwd: String?
    public let transcriptPath: String?
    public let prompt: String?
    public let toolName: String?
    public let toolTarget: String?
    public let reason: String?

    /// Always false. A tool's result is decoded by nothing and stored nowhere, and this is the assertion of it.
    public var capturesToolResult: Bool { false }

    /// `tool_result` is deliberately absent from this list, and must never be added.
    public static func decode(_ data: Data) throws -> HookPayload {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure.malformed
        }
        guard let session = object["session_id"] as? String, !session.isEmpty else {
            throw Failure.missingSession
        }
        let input = object["tool_input"] as? [String: Any]
        return HookPayload(
            event: object["hook_event_name"] as? String,
            sessionId: session,
            cwd: object["cwd"] as? String,
            transcriptPath: object["transcript_path"] as? String,
            prompt: object["user_prompt"] as? String,
            toolName: object["tool_name"] as? String,
            toolTarget: (input?["file_path"] as? String) ?? (input?["path"] as? String),
            reason: object["reason"] as? String)
    }

    /// Always nil. It exists so that a caller cannot pass a tool's result through by accident.
    public func text(forToolResult result: String) -> String? { nil }
}
