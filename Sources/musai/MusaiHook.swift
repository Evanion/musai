import Foundation
import MusaiCore

/// The `musai` executable: the seam the host's hooks call, and the person's way in. It is a client of the
/// backend now — it never opens the store — and every hook path exits 0, because a hook that fails must not
/// fail the session it is reporting on.
@main
struct MusaiHook {
    /// The launch agent's label. A client that finds no backend asks launchd to start it under this name.
    static let agentLabel = "dev.musai.agent"
    /// How long a hook waits for the agent it just asked launchd to start, before it gives up.
    static let startWait: TimeInterval = 2

    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else { return }
        arguments.removeFirst()
        // `--library` is still accepted and consumed, but it no longer reaches a hook: it chooses the store at
        // install time, and a client learns the store from the record instead.
        if let index = arguments.firstIndex(of: "--library"), index + 1 < arguments.count {
            arguments.removeSubrange(index...(index + 1))
        }

        switch command {
        case "hook":
            let event: String? = arguments.first
            let stdin = FileHandle.standardInput.readDataToEndOfFile()
            guard let client = await connectedClient() else {
                diagnose("the backend is not running; run `musai install --helper` once")
                return
            }
            emit(
                await HookDispatch(client: client).run(
                    event: event, stdin: stdin, cwd: FileManager.default.currentDirectoryPath))
        case "review":
            guard let client = await connectedClient() else {
                diagnose("the backend is not running; run `musai install --helper` once")
                return
            }
            await Review(client: client).run()
        case "install":
            guard arguments.contains("--claude-code") else {
                FileHandle.standardError.write(
                    Data("musai: install --claude-code [--settings <path>]\n".utf8))
                return
            }
            let settings = arguments.firstIndex(of: "--settings").flatMap { index in
                index + 1 < arguments.count ? URL(fileURLWithPath: arguments[index + 1]) : nil
            } ?? Self.claudeSettingsURL()
            let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
            do {
                print(try MusaiInstall.install(executable: executable, settingsURL: settings))
            } catch {
                diagnose(oneLine(error))
            }
        default:
            return
        }
    }

    /// The client the backend is reachable through, or `nil` when it is not running. A missing or stale record
    /// is the cue to ask launchd to start the agent and wait a moment; if it still does not answer, the caller
    /// reports the fact rather than posting into a port it does not own.
    static func connectedClient() async -> MusaiClient? {
        if let client = recordedClient(), await client.health() != nil { return client }
        startAgent()
        let deadline = Date().addingTimeInterval(startWait)
        while Date() < deadline {
            if let client = recordedClient(), await client.health() != nil { return client }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// The client the record and the token describe, without asking whether it answers yet.
    static func recordedClient() -> MusaiClient? {
        guard let record = try? HelperRecord.read(), let token = MusaiToken.read() else { return nil }
        return MusaiClient(record: record, token: token)
    }

    /// Ask launchd for the agent. Its own failure is a diagnostic the person can read elsewhere, not a crash.
    static func startAgent() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "gui/\(getuid())/\(agentLabel)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private static func claudeSettingsURL() -> URL {
        let configDirectory = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude").path
        return URL(fileURLWithPath: configDirectory).appending(path: "settings.json")
    }

    private static func emit(_ outcome: HookOutcome) {
        if let stdout = outcome.stdout {
            FileHandle.standardOutput.write(Data("\(stdout)\n".utf8))
        }
        if let diagnostic = outcome.diagnostic {
            FileHandle.standardError.write(Data("\(diagnostic)\n".utf8))
        }
    }

    private static func diagnose(_ message: String) {
        FileHandle.standardError.write(Data("musai: \(message)\n".utf8))
    }
}

/// `musai review`, over the endpoint instead of the store: the gap first, then one key per proposal. Its shape
/// mirrors `ReviewSession.run`, because it is the same conversation with a different door.
struct Review: Sendable {
    let client: MusaiClient

    func run() async {
        do {
            let gap = try await client.gap()
            if !gap.isEmpty {
                print("\(gap.count) decision\(gap.count == 1 ? "" : "s") were settled and never recorded anywhere:")
                for entry in gap { print("  · \(entry.title)") }
                print("")
            }

            let proposals = try await client.proposals()
            guard !proposals.isEmpty else {
                if gap.isEmpty { print("nothing pending") }
                return
            }

            for (index, proposal) in proposals.enumerated() {
                var headline = "[\(index + 1)/\(proposals.count)] \(proposal.title)   (\(proposal.act.displayName)"
                if let said = proposal.said { headline += ", said: \"\(said)\"" }
                print(headline + ")")
                if let rationale = proposal.rationale { print("  \(rationale)") }
                print("  [y] settled, landed nowhere   [r] settled, landed at…   [d] drop   [s] skip")

                guard let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                else { break }
                switch answer {
                case "y":
                    try await client.apply(.settle, to: proposal.id)
                case "r":
                    guard let reference = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
                        !reference.isEmpty
                    else { continue }
                    try await client.apply(.persist(documentRef: reference), to: proposal.id)
                case "d":
                    try await client.apply(.drop, to: proposal.id)
                default:
                    // An unrecognised key is a skip: a wrong confirmation is worse than a missed one.
                    continue
                }
            }
        } catch {
            FileHandle.standardError.write(Data("musai: \(oneLine(error))\n".utf8))
        }
    }
}
