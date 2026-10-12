import CryptoKit
import Foundation
import NorvoLite

/// What a hook hands back: stdout for the host, or a one-line diagnostic for the log.
public struct HookOutcome: Sendable, Equatable {
    public let stdout: String?
    public let diagnostic: String?

    public init(stdout: String?, diagnostic: String?) {
        self.stdout = stdout
        self.diagnostic = diagnostic
    }

    public static let silent = HookOutcome(stdout: nil, diagnostic: nil)
}

/// Dispatches one hook invocation. It lives here, in the library, rather than in the executable, so that
/// "a hook can never break the host's session" is something a test can prove: `run` never throws — a failure
/// comes back as a diagnostic.
public struct HookRunner: Sendable {
    /// stdin beyond this is ignored: a hook is not a place to read a large file.
    public static let maxStdinBytes = 1 << 20

    public let capture: MusaiCapture
    public let library: MusaiLibrary

    public init(capture: MusaiCapture, library: MusaiLibrary) {
        self.capture = capture
        self.library = library
    }

    public func run(event: String?, stdin: Data, cwd: String, at: Date = Date()) async -> HookOutcome {
        do {
            let payload = try HookPayload.decode(Self.bounded(stdin))
            let name = event ?? payload.event
            let cwd = payload.cwd ?? cwd
            let session = payload.sessionId ?? ""
            switch name {
            case "UserPromptSubmit":
                guard let prompt = payload.prompt, !prompt.isEmpty else { return .silent }
                try await capture.captureUserTurn(
                    text: prompt, at: at, origin: "claude", session: session, cwd: cwd, as: MusaiActors.curator)
                return .silent
            case "PostToolUse":
                guard let tool = payload.toolName, !tool.isEmpty else { return .silent }
                try await capture.captureToolUse(
                    tool: tool, target: payload.toolTarget, digest: Self.digest(tool, payload.toolTarget),
                    at: at, session: session, cwd: cwd, as: MusaiActors.curator)
                return .silent
            case "Stop":
                // The agent's own account of its turn. The curator joins this in Task 6.
                var text: String?
                if let path = payload.transcriptPath, !path.isEmpty {
                    text = try? TranscriptTail.lastAssistantText(at: URL(fileURLWithPath: path))
                }
                try await capture.captureAgentTurn(
                    text: text, at: at, session: session, cwd: cwd, as: MusaiActors.curator)
                // The curator drains what the queue now holds. A model that is down must not fail the hook and
                // must not lose the events: nothing is marked drained unless the proposals were written, so the
                // next drain retries them.
                if let project = try? await ProjectBinder(db: library.db).bind(
                    cwd: URL(fileURLWithPath: cwd), memorySessionId: session, platform: "claude",
                    startedAt: at, as: MusaiActors.curator).projectSlug,
                    let configuration = try? ModelConfiguration.load()
                {
                    let curator = ProposalCurator(
                        db: library.db,
                        detector: ModelDecisionDetector(
                            provider: OpenAICompatibleProvider(configuration: configuration)))
                    _ = try? await curator.drain(project: project, as: MusaiActors.curator)
                }
                return .silent
            case "SessionStart":
                let bound = try await ProjectBinder(db: library.db).bind(
                    cwd: URL(fileURLWithPath: cwd), memorySessionId: session, platform: "claude",
                    startedAt: at, as: MusaiActors.curator)
                guard let text = try await MusaiSlice.render(project: bound.projectSlug, db: library.db) else {
                    return .silent
                }
                return HookOutcome(stdout: MusaiSlice.additionalContext(text), diagnostic: nil)
            default:
                return .silent
            }
        } catch {
            return HookOutcome(stdout: nil, diagnostic: "musai: \(Self.oneLine(error))")
        }
    }

    static func bounded(_ data: Data) -> Data {
        data.count > maxStdinBytes ? data.prefix(maxStdinBytes) : data
    }

    /// The same tool on the same target twice is one digest, so a retried hook is recognisable without
    /// storing what the tool produced.
    static func digest(_ tool: String, _ target: String?) -> String {
        let material = tool + "\u{1F}" + (target ?? "")
        return SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func oneLine(_ error: any Error) -> String {
        let text = String(describing: error)
        return text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "failed"
    }
}
