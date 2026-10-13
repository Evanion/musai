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
        // install time, and a client learns the store from the record instead. `install` is the one command
        // that still needs its value, so it is kept before the flag is consumed below.
        var library: String?
        if let index = arguments.firstIndex(of: "--library"), index + 1 < arguments.count {
            library = arguments[index + 1]
            arguments.removeSubrange(index...(index + 1))
        }

        switch command {
        case "hook":
            let event: String? = arguments.first
            let stdin = FileHandle.standardInput.readDataToEndOfFile()
            guard let client = await connectedClient() else {
                diagnose("the backend is not running; run `musai install` once")
                return
            }
            emit(
                await HookDispatch(client: client).run(
                    event: event, stdin: stdin, cwd: FileManager.default.currentDirectoryPath))
        case "review":
            guard let client = await connectedClient() else {
                diagnose("the backend is not running; run `musai install` once")
                return
            }
            await Review(client: client).run()
        case "doctor":
            await doctor(arguments: arguments)
        case "mcp":
            await mcp()
        case "install":
            if arguments.contains("--uninstall") {
                uninstall(arguments: arguments)
            } else {
                install(arguments: arguments, library: library.map { URL(fileURLWithPath: $0) })
            }
        default:
            return
        }
    }

    /// `musai mcp`: line-delimited JSON-RPC over stdio, one message in and one out. The record and the token
    /// are re-read for **every** message rather than once at startup, because this server outlives the agent
    /// it was started beside: the agent restarts under launchd and takes a fresh port with it, and a server
    /// that read the record once would spend the rest of its life calling a port nothing owns. stdout
    /// carries protocol messages and nothing else — a stray write there corrupts the session — so every
    /// diagnostic goes to stderr, and a message with no answer (`nil`) simply gets none.
    static func mcp() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty else { continue }
            let client = await handshakenClient()
            guard let reply = await MusaiMCP(client: client).handle(Data(line.utf8)) else { continue }
            FileHandle.standardOutput.write(reply)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    /// `musai install`: assemble the bundle, register the launch agent, and merge the host's hooks. `--claude-code`
    /// is still accepted for the command's documented spelling, but it is no longer required — this is the whole
    /// install by default.
    static func install(arguments: [String], library: URL?) {
        // Our own path as the loader resolved it, not the invocation string: under a PATH lookup `argv[0]` is a
        // bare name, and deriving an install from it would look for the agent and the plists in whichever
        // directory the shell happened to be in.
        guard let executable = Bundle.main.executableURL?.standardizedFileURL else {
            diagnose("cannot find my own executable; run this from the checkout you built")
            return
        }
        let built = executable.deletingLastPathComponent()
        let agent = built.appending(path: "musai-agent")
        guard let resources = repositoryResources(from: executable) else {
            diagnose(
                "cannot find Resources/App-Info.plist above \(built.path); run this from the checkout you built")
            return
        }
        for (what, path) in [
            ("the musai executable", executable),
            ("the musai-agent executable", agent),
            ("Resources/App-Info.plist", resources.appending(path: MusaiBundle.appInfoPlistName)),
        ] {
            guard FileManager.default.fileExists(atPath: path.path) else {
                diagnose("cannot find \(what) at \(path.path); run `swift build` first")
                return
            }
        }

        let appDirectory = appDirectory(in: arguments)
        let launchAgents = launchAgentsDirectory()
        let store = library ?? MusaiLibrary.defaultFileURL
        let settings = settingsURL(in: arguments)

        do {
            let root = try MusaiInstall.installBundle(
                app: executable, agent: agent, into: appDirectory,
                launchAgentsDirectory: launchAgents, library: store, resources: resources)
            loadAgent(plistAt: launchAgents.appending(path: "\(MusaiInstall.agentLabel).plist"))
            print("musai: installed Musai.app at \(root.path)")
            print("musai: registered \(MusaiInstall.agentLabel) to start at login, serving \(store.path)")
            print("musai: moving or deleting Musai.app breaks that registration; run `musai install` again after moving it")
            print(try ClaudeCodeHooks.install(executable: executable.path, settingsURL: settings))
        } catch {
            diagnose(oneLine(error))
        }
    }

    /// `musai doctor`: reads the record, asks `/health` when the process behind it is still alive, reads the
    /// log's tail and looks for the bundle, and prints what `MusaiDiagnostics` makes of it all. It changes
    /// nothing and starts nothing — a diagnosis that acted would hide the state it was called to show — and
    /// it exits 0 whatever it finds: this is not a check, whatever the exit code would otherwise mean.
    static func doctor(arguments: [String]) async {
        let record = try? HelperRecord.read()
        var health: EndpointHealth?
        if let record, record.isAlive {
            // The token file is the source of truth; the record republishes it too, because a record that
            // could not be used to reach the backend would be a strange thing to publish.
            let token = MusaiToken.read() ?? record.token
            health = await MusaiClient(record: record, token: token).health()
        }
        let bundle = appDirectory(in: arguments).appending(path: "\(MusaiBundle.appName).app")
        let found = FileManager.default.fileExists(atPath: bundle.path) ? bundle : nil

        print(
            MusaiDiagnostics.screen(
                record: record, health: health,
                logTail: MusaiLog().tail(MusaiDiagnostics.logLines), bundlePath: found))
    }

    /// `musai install --uninstall`: stop the agent, remove the plist and the bundle, and take our hooks back out.
    /// It is the exact reverse of the install above, and it always tells the person what it did.
    static func uninstall(arguments: [String]) {
        let appDirectory = appDirectory(in: arguments)
        let launchAgents = launchAgentsDirectory()
        let settings = settingsURL(in: arguments)

        // Booted out first, so `KeepAlive` cannot bring the agent straight back while its plist is being removed.
        launchctl(["bootout", "gui/\(getuid())/\(MusaiInstall.agentLabel)"])
        do {
            try MusaiInstall.uninstall(
                bundle: appDirectory.appending(path: "\(MusaiBundle.appName).app"),
                launchAgentsDirectory: launchAgents)
            print("musai: removed Musai.app from \(appDirectory.path) and its launch agent")
            print(try ClaudeCodeHooks.uninstall(settingsURL: settings))
        } catch {
            diagnose(oneLine(error))
        }
    }

    /// The client the backend is reachable through, or `nil` when it is not running. A missing or stale record
    /// is the cue to ask launchd to start the agent and wait a moment; if it still does not answer, the caller
    /// reports the fact rather than posting into a port it does not own.
    static func connectedClient() async -> MusaiClient? {
        if let client = await handshakenClient() { return client }
        startAgent()
        let deadline = Date().addingTimeInterval(startWait)
        while Date() < deadline {
            if let client = await handshakenClient() { return client }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    /// The client, with the handshake it just made attached: the operation's own compatibility check then
    /// costs no second round trip. `nil` when the record or the token is missing, or nothing answers.
    static func handshakenClient() async -> MusaiClient? {
        guard let record = try? HelperRecord.read(), let token = MusaiToken.read() else { return nil }
        let probe = MusaiClient(record: record, token: token)
        guard let health = await probe.health() else { return nil }
        return MusaiClient(record: record, token: token, handshake: health)
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

    /// The host's settings file: `--settings <path>`, else the Claude Code default with its `CLAUDE_CONFIG_DIR`
    /// override honoured.
    private static func settingsURL(in arguments: [String]) -> URL {
        arguments.firstIndex(of: "--settings").flatMap { index in
            index + 1 < arguments.count ? URL(fileURLWithPath: arguments[index + 1]) : nil
        } ?? claudeSettingsURL()
    }

    /// Where the bundle goes: `--app <dir>`, else `~/Applications`.
    private static func appDirectory(in arguments: [String]) -> URL {
        arguments.firstIndex(of: "--app").flatMap { index in
            index + 1 < arguments.count ? URL(fileURLWithPath: arguments[index + 1]) : nil
        } ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications")
    }

    private static func launchAgentsDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/LaunchAgents")
    }

    /// The repository's `Resources` directory, found above the built executable (`.build/<config>/musai`). It is
    /// derived from the executable's own path so a run from the checkout finds the `Info.plist`s it was built
    /// beside, and `nil` when there is none — an install must say it cannot find its own halves, not guess.
    private static func repositoryResources(from executable: URL) -> URL? {
        var directory = executable.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = directory.appending(path: "Resources")
            if FileManager.default.fileExists(
                atPath: candidate.appending(path: MusaiBundle.appInfoPlistName).path)
            {
                return candidate
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    /// Loads the freshly written job and starts it: `bootout` first so re-installing reloads rather than fails
    /// with "service already loaded", then `bootstrap`, which `RunAtLoad` starts. launchd's own errors are not
    /// ours to raise — the plist and the person's next login are the durable part.
    private static func loadAgent(plistAt plist: URL) {
        launchctl(["bootout", "gui/\(getuid())/\(MusaiInstall.agentLabel)"])
        launchctl(["bootstrap", "gui/\(getuid())", plist.path])
    }

    private static func launchctl(_ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
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

/// `musai review`, over the endpoint instead of the store: the gap first, then one key per proposal. Input and
/// output are injected so the loop can be driven by a test, not only by a person at a terminal.
struct Review {
    let client: MusaiClient
    var read: () -> String? = { readLine() }
    var write: (String) -> Void = { print($0) }
    var diagnose: (String) -> Void = { FileHandle.standardError.write(Data("musai: \($0)\n".utf8)) }

    func run() async {
        do {
            let gap = try await client.gap()
            if !gap.isEmpty {
                write("\(gap.count) decision\(gap.count == 1 ? "" : "s") were settled and never recorded anywhere:")
                for entry in gap { write("  · \(entry.title)") }
                write("")
            }

            let proposals = try await client.proposals()
            guard !proposals.isEmpty else {
                if gap.isEmpty { write("nothing pending") }
                return
            }

            for (index, proposal) in proposals.enumerated() {
                var headline = "[\(index + 1)/\(proposals.count)] \(proposal.title)   (\(proposal.act.displayName)"
                if let said = proposal.said { headline += ", said: \"\(said)\"" }
                write(headline + ")")
                if let rationale = proposal.rationale { write("  \(rationale)") }
                write("  [y] settled, landed nowhere   [r] settled, landed at…   [d] drop   [s] skip")

                guard let answer = read()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                else { break }
                switch answer {
                case "y":
                    try await client.apply(.settle, to: proposal.id)
                case "r":
                    guard let reference = read()?.trimmingCharacters(in: .whitespacesAndNewlines),
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
            diagnose(oneLine(error))
        }
    }
}
