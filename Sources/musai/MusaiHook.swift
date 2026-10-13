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
                diagnose(noBackend)
                return
            }
            emit(
                await HookDispatch(client: client).run(
                    event: event, stdin: stdin, cwd: FileManager.default.currentDirectoryPath))
        case "review":
            await Review(
                migrated: arguments.contains("--migrated"),
                first: option("--first", in: arguments).flatMap(Int.init)
            ).run()
        case "import":
            await Import(arguments: arguments).run()
        case "recall":
            await Recall(arguments: arguments).run()
        case "ideas":
            await Ideas(arguments: arguments).run()
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

    /// The one line every command says when no backend answers. It names `musai install` because that is what
    /// starts the agent, and it is a diagnostic rather than a failure: this is the same executable a hook
    /// calls, and a hook that failed would fail the session it reports on.
    static let noBackend = "the backend is not running; run `musai install` once"

    /// The value of `--name <value>` in an argument list, or `nil` when the flag is absent or came last with
    /// nothing after it.
    static func option(_ name: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: name).flatMap { index in
            index + 1 < arguments.count ? arguments[index + 1] : nil
        }
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
        option("--settings", in: arguments).map { URL(fileURLWithPath: $0) } ?? claudeSettingsURL()
    }

    /// Where the bundle goes: `--app <dir>`, else `~/Applications`.
    private static func appDirectory(in arguments: [String]) -> URL {
        option("--app", in: arguments).map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications")
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

/// `musai review`, over the endpoint instead of the store: the gap first, then one key per proposal. The live
/// list and the imported one wear the same surface — the keys are the same and the acts are the same, because
/// settling an imported entry *is* settling a decision — and which list it walks is the only thing that
/// differs. Input and output are injected so the loop can be driven by a test, not only by a person at a
/// terminal.
struct Review {
    /// `musai review --migrated`: the imported, one-sided history, in the view of its own — the live review
    /// list deliberately does not carry it, and a review of ~6 900 imported entries would bury it.
    var migrated: Bool = false
    /// `--first <n>`: how much of the migration view to show. Optional, and the endpoint clamps it: this is a
    /// page of a long backlog, and the reply says whether it is showing all of it.
    var first: Int? = nil
    /// How the subcommand reaches the backend: a closure, so the missing-backend path is a test and not a
    /// launchd kickstart against whatever machine happens to be running this.
    var connect: () async -> MusaiClient? = MusaiHook.connectedClient
    var read: () -> String? = { readLine() }
    var write: (String) -> Void = { print($0) }
    var diagnose: (String) -> Void = { FileHandle.standardError.write(Data("musai: \($0)\n".utf8)) }

    func run() async {
        guard let client = await connect() else {
            diagnose(MusaiHook.noBackend)
            return
        }
        do {
            if migrated {
                try await reviewMigrated(client)
            } else {
                try await reviewLive(client)
            }
        } catch {
            diagnose(oneLine(error))
        }
    }

    /// The live review: the gap first — the risk the person came to see — then one key per proposal.
    private func reviewLive(_ client: MusaiClient) async throws {
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

        try await confirm(
            proposals.map { Entry(id: $0.id, title: $0.title, act: $0.act, said: $0.said, note: $0.rationale) },
            of: client)
    }

    /// `musai review --migrated`: the imported, one-sided history, as the page it is — and, now, a page the
    /// person can work down.
    ///
    /// The reply says whether it is showing all of it — the endpoint knows by fetching one more than it
    /// returns — and this says so too, because a view of the first 50 of ~6 900 with nothing on it would read
    /// as the whole backlog. The one option it offers is `--first`, which the endpoint bounds; at that bound
    /// the advice turns to what advances the list, rather than naming a `--first` the endpoint would clamp
    /// back to this same page.
    private func reviewMigrated(_ client: MusaiClient) async throws {
        let reply = try await client.migrated(first: first)
        guard !reply.proposals.isEmpty else {
            write("nothing imported is waiting")
            return
        }
        let shown = reply.proposals.count
        let entries = "imported entr\(shown == 1 ? "y" : "ies")"
        write(
            reply.hasMore
                ? "the first \(shown) \(entries) await your word:"
                : "\(shown) \(entries) await your word:")
        try await confirm(
            reply.proposals.map {
                Entry(id: $0.id, title: $0.title, act: $0.act, said: nil, note: "imported from \($0.origin)")
            },
            of: client)
        write(reply.hasMore ? Self.migratedMoreLine(shown: shown) : "that is all of them")
    }

    /// One entry the confirm loop can act on. Both lists feed the same loop: which list it walked is decided
    /// by the caller, and everything the loop needs is here — so settling a live proposal and settling an
    /// imported one are one code path rather than two idioms that could drift.
    private struct Entry {
        let id: UUID
        let title: String
        let act: ActKind
        /// The person's own words, from the turn the proposal came from. `nil` for an imported entry:
        /// claude-mem recorded no utterance for those, and a field that was always empty would read as a
        /// missing one.
        let said: String?
        /// The line under the headline: a live proposal's rationale, or where an imported entry came from.
        let note: String?
    }

    /// One key per entry, applied as the person over the endpoint. An unrecognised key is a skip: a wrong
    /// confirmation is worse than a missed one, and the person can always come back to it.
    private func confirm(_ entries: [Entry], of client: MusaiClient) async throws {
        for (index, entry) in entries.enumerated() {
            var headline = "[\(index + 1)/\(entries.count)] \(entry.title)   (\(entry.act.displayName)"
            if let said = entry.said { headline += ", said: \"\(said)\"" }
            write(headline + ")")
            if let note = entry.note { write("  \(note)") }
            write("  [y] settled, landed nowhere   [r] settled, landed at…   [d] drop   [s] skip")

            guard let answer = read()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            else { break }
            switch answer {
            case "y":
                try await client.apply(.settle, to: entry.id)
            case "r":
                guard let reference = read()?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !reference.isEmpty
                else { continue }
                try await client.apply(.persist(documentRef: reference), to: entry.id)
            case "d":
                try await client.apply(.drop, to: entry.id)
            default:
                continue
            }
        }
    }

    /// The line under a migration page that is not the whole of the imported history.
    ///
    /// `--first` is offered only while asking for double the page is still inside the endpoint's cap. At the
    /// cap the endpoint clamps every larger ask back to the same page, and that page's own footer would name
    /// the same impossible ask again — a circle. So there, the line says what does advance the list instead:
    /// the ascending page exposes the next rows only once the shown ones are worked through, which moves them
    /// out of the imported view. That advice is now true of this surface, which offers the keys to work
    /// through them.
    static func migratedMoreLine(shown: Int) -> String {
        guard shown < MusaiEndpoint.migratedFirstCap else {
            return "more than these \(shown) are waiting — that is the whole page, so the rest appear only "
                + "as these are worked through: settle or drop some, and `musai review --migrated` shows what follows"
        }
        let next = min(shown * 2, MusaiEndpoint.migratedFirstCap)
        return "more than these \(shown) are waiting — `musai review --migrated --first \(next)` shows further"
    }
}

/// `musai import`: the first run, from the person's side.
///
/// One request to the endpoint is **one pass** over the corpus — one batch of each stage, deliberately not a
/// whole corpus, because the backend serves one request at a time and an import that ran to the end would hold
/// every capture behind it — so this repeats the call until a pass imports nothing left. That empty report is
/// the stop signal the protocol defines; the pass totals are added up here, because a report's numbers are
/// *that pass's*, never a running total.
///
/// The corpus is claude-mem's own database, opened read-only on the agent's side: this never opens it, never
/// writes it, and `--dry-run` writes nothing at all — no memory, and no cursor either, so a dry run leaves the
/// real one exactly where it was.
struct Import {
    /// The subcommand's arguments, after the command's name.
    var arguments: [String]
    /// How the subcommand reaches the backend: a closure, so the missing-backend path is a test and not a
    /// launchd kickstart against whatever machine happens to be running this.
    var connect: () async -> MusaiClient? = MusaiHook.connectedClient
    var write: (String) -> Void = { print($0) }
    var diagnose: (String) -> Void = { FileHandle.standardError.write(Data("musai: \($0)\n".utf8)) }

    /// Where claude-mem keeps its corpus, for a machine that never moved it.
    static let defaultSource = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".claude-mem/claude-mem.db")

    /// `--from <path>`, else claude-mem's own database.
    var source: URL {
        MusaiHook.option("--from", in: arguments).map { URL(fileURLWithPath: $0) } ?? Self.defaultSource
    }

    /// `--dry-run`: report what a run would do, and write none of it.
    var dryRun: Bool { arguments.contains("--dry-run") }

    func run() async {
        guard let client = await connect() else {
            diagnose(MusaiHook.noBackend)
            return
        }
        let corpus = source
        write("musai: importing \(corpus.path) — read only, and nothing is ever written back to it")

        var total = ImportReport(dryRun: dryRun)
        var passes = 0
        while true {
            passes += 1
            let report: ImportReport
            do {
                report = try await client.importHistory(from: corpus, dryRun: dryRun)
            } catch {
                // Stopping is not failing: every cursor sits after the last batch it committed, so running it
                // again resumes there rather than starting over.
                diagnose("\(oneLine(error)) — the import stopped in pass \(passes); run `musai import` again")
                return
            }
            total = totalling(total, report)
            // A dry run is exactly one pass: it moves no cursor, so a second pass would report the same
            // numbers and a loop on it would never end.
            if dryRun || importedNothing(report) { break }
            write("musai: pass \(passes): \(counts(report))")
        }

        guard !importedNothing(total) else {
            write("musai: nothing to import from \(corpus.path)")
            return
        }
        write("musai: \(dryRun ? "would import" : "imported") \(counts(total))")
        if let names = discoveryNames(total) { write("musai: discovery names \(names)") }
        if dryRun {
            write("musai: nothing was written, not even a cursor — this is exactly what a run would do")
            write("musai: run `musai import` to do it")
        } else {
            write("musai: stop it any time; each stage keeps a cursor, so `musai import` again resumes there")
        }
    }
}

/// `musai recall [--project <slug>] <words…>`: what a person half remembers.
///
/// The words are joined into one query, and each memory found is printed as its text — the search's own answer,
/// not a reformatting of it, so the output is what can be read and searched again. Finding nothing prints
/// nothing and succeeds, exactly as the endpoint treats an empty result: no hits is an answer, not an error,
/// and this is the same executable a hook calls.
struct Recall {
    var arguments: [String]
    var connect: () async -> MusaiClient? = MusaiHook.connectedClient
    var write: (String) -> Void = { print($0) }
    var diagnose: (String) -> Void = { FileHandle.standardError.write(Data("musai: \($0)\n".utf8)) }

    /// `--project <slug>`: narrow the search to one project's memories.
    var project: String? { MusaiHook.option("--project", in: arguments) }

    /// Everything that is not a flag or a flag's value. `--project musai` is a project, never two more words
    /// to search for.
    var words: [String] {
        var collected: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--project", index + 1 < arguments.count {
                index += 2
                continue
            }
            if !argument.hasPrefix("--") { collected.append(argument) }
            index += 1
        }
        return collected
    }

    func run() async {
        let query = words.joined(separator: " ")
        // A `--project` alone is the project's memories; no words and no project is not a search at all, and
        // saying so beats listing the memories that belong to nothing as though they were an answer.
        guard !query.isEmpty || project != nil else {
            diagnose("give me a word to look for: `musai recall [--project <slug>] <words…>`")
            return
        }
        guard let client = await connect() else {
            diagnose(MusaiHook.noBackend)
            return
        }
        do {
            for memory in try await client.memories(project: project, q: query.isEmpty ? nil : query) {
                // A memory may hold only a narrative; a hit is still a hit, so it is named rather than
                // silently left out of the answer.
                write(memory.text ?? "(a memory with no text: \(memory.id.uuidString))")
            }
        } catch {
            diagnose(oneLine(error))
        }
    }
}

/// `musai ideas`: what the first run discovered, listed — and, with a key, corrected.
///
/// An idea is what the import makes of a corpus label that named no working tree: a thread that lived only in
/// conversation. Until this verb there was no way to see the ideas in the store or to act on one, even though
/// the dry-run report named them and the README told a person to run the import that creates them. Listing is
/// the read; `--drop` deletes one and `--promote` turns one into the project it was pointing at, the arc the
/// data model already has. A rename and a merge are deliberately absent: an idea's title comes from the
/// corpus, and a merge is a decision with a target rather than a verb on one row. This is a client of the
/// backend and never opens the store.
struct Ideas {
    var arguments: [String]
    var connect: () async -> MusaiClient? = MusaiHook.connectedClient
    var write: (String) -> Void = { print($0) }
    var diagnose: (String) -> Void = { FileHandle.standardError.write(Data("musai: \($0)\n".utf8)) }

    /// `--project <slug>`: list one project's ideas rather than every idea the store holds.
    var project: String? { MusaiHook.option("--project", in: arguments) }
    /// `--drop <id>`: delete one idea. Nothing references an idea, so the row goes without a trace.
    var drop: UUID? { MusaiHook.option("--drop", in: arguments).flatMap(UUID.init(uuidString:)) }
    /// `--promote <id>`: turn one idea into a project — the data model's own arc.
    var promote: UUID? { MusaiHook.option("--promote", in: arguments).flatMap(UUID.init(uuidString:)) }

    func run() async {
        guard let client = await connect() else {
            diagnose(MusaiHook.noBackend)
            return
        }
        do {
            if arguments.contains("--drop") {
                guard let id = drop else {
                    diagnose("`--drop` needs the id of an idea: `musai ideas --drop <id>`")
                    return
                }
                let reply = try await client.drop(idea: id)
                write("musai: dropped \"\(reply.title)\"")
            } else if arguments.contains("--promote") {
                guard let id = promote else {
                    diagnose("`--promote` needs the id of an idea: `musai ideas --promote <id>`")
                    return
                }
                let reply = try await client.promote(idea: id)
                write("musai: \"\(reply.title)\" is now project \"\(reply.spawnedProject ?? "")\"")
            } else {
                try await list(client)
            }
        } catch {
            diagnose(oneLine(error))
        }
    }

    /// The listing: one idea to a line, its id included because that is what the two keys act on, and where
    /// it sits — the project it came from, the project it became, or neither.
    private func list(_ client: MusaiClient) async throws {
        let ideas = try await client.ideas(project: project)
        guard !ideas.isEmpty else {
            write("no ideas")
            return
        }
        write("\(ideas.count) idea\(ideas.count == 1 ? "" : "s"):")
        for idea in ideas {
            write("  · \(idea.title)   (\(place(idea)))   [\(idea.id.uuidString)]")
        }
    }

    /// Where one idea sits.
    private func place(_ idea: IdeaSummary) -> String {
        if let spawned = idea.spawnedProject { return "spawned: \(spawned)" }
        if let project = idea.project { return project }
        return "no project"
    }
}

// MARK: - What a report reads like

/// `1 session`, `2 sessions` — a count and its noun, so a line reads as English at one and at many.
private func plural(_ count: Int, _ singular: String, _ many: String? = nil) -> String {
    "\(count) \(count == 1 ? singular : (many ?? singular + "s"))"
}

/// A report's numbers as one line: what the pass wrote, then what it read and deliberately did not write, and
/// only when there is something to say — a zero is not news.
private func counts(_ report: ImportReport) -> String {
    var parts = [
        plural(report.sessions, "session"), plural(report.evidence, "memory", "memories"),
        plural(report.prompts, "prompt"), plural(report.workStates, "work state"),
        plural(report.proposals, "proposal"),
    ]
    if report.machinePrompts > 0 {
        parts.append("\(plural(report.machinePrompts, "machine payload")) dropped")
    }
    if report.skipped > 0 { parts.append("\(plural(report.skipped, "row")) skipped") }
    if report.unbound > 0 { parts.append("\(plural(report.unbound, "session")) with no project") }
    return parts.joined(separator: ", ")
}

/// Discovery's verdict as a person reads it, or `nil` when it named nothing: what the corpus names as a
/// project or an idea, its counts included, and the labels that are a filing habit rather than a unit of work.
private func discoveryNames(_ report: ImportReport) -> String? {
    guard !report.projects.isEmpty || !report.ideas.isEmpty || !report.buckets.isEmpty else { return nil }
    return [
        plural(report.projects.count, "project") + listed(report.projects),
        plural(report.ideas.count, "idea") + listed(report.ideas),
        plural(report.buckets.count, "filing label") + listed(report.buckets),
    ].joined(separator: ", ")
}

/// The names behind a count, in parentheses, or nothing at all when there are none.
private func listed(_ values: [String]) -> String {
    values.isEmpty ? "" : " (\(values.joined(separator: ", ")))"
}

/// A pass's report on top of the run's: the numbers added, and discovery's three arrays kept in the order the
/// corpus first named them and deduped, because two batches can name the same project.
private func totalling(_ total: ImportReport, _ pass: ImportReport) -> ImportReport {
    ImportReport(
        dryRun: pass.dryRun,
        sessions: total.sessions + pass.sessions,
        evidence: total.evidence + pass.evidence,
        prompts: total.prompts + pass.prompts,
        workStates: total.workStates + pass.workStates,
        proposals: total.proposals + pass.proposals,
        projects: merged(total.projects, pass.projects),
        ideas: merged(total.ideas, pass.ideas),
        buckets: merged(total.buckets, pass.buckets),
        unbound: total.unbound + pass.unbound,
        machinePrompts: total.machinePrompts + pass.machinePrompts,
        skipped: total.skipped + pass.skipped)
}

private func merged(_ first: [String], _ second: [String]) -> [String] {
    var seen = Set(first)
    var all = first
    for value in second where seen.insert(value).inserted { all.append(value) }
    return all
}

/// Whether a pass imported nothing left: every number zero and discovery silent.
///
/// An idle pass is what the endpoint answers with once each stage's cursor is at the end of its table — every
/// stage reads nothing, so nothing is counted — and that is the stop signal the protocol defines and the CLI
/// loops on. What the report cannot say is whether a pass *read* rows and counted none: the counters are the
/// only signal the endpoint gives about the import's progress.
private func importedNothing(_ report: ImportReport) -> Bool {
    report.sessions == 0 && report.evidence == 0 && report.prompts == 0 && report.workStates == 0
        && report.proposals == 0 && report.unbound == 0 && report.machinePrompts == 0 && report.skipped == 0
        && report.projects.isEmpty && report.ideas.isEmpty && report.buckets.isEmpty
}

