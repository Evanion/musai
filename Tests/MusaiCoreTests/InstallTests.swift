import Foundation
import Testing
@testable import MusaiCore
@testable import musai

/// Installing the backend is one act: the bundle and the launch agent on disk, and the host's hooks still
/// merged. These tests exercise the host-agnostic half — where the bundle and the plist land, and that doing it
/// twice changes nothing — plus the one seam that joins them to the adapter's hooks.
@Suite struct InstallTests {
    /// The `Info.plist`s the install copies live in the repository, not in this test.
    private static var resources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MusaiCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // the package root
            .appending(path: "Resources")
    }

    /// A temporary directory of its own for one test, so nothing it writes reaches the person's machine.
    private func workspace() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Stand-in built executables, so an install has two halves to place without building anything.
    private func built(in workspace: URL) throws -> (app: URL, agent: URL) {
        let directory = workspace.appending(path: "built")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = directory.appending(path: "musai")
        let agent = directory.appending(path: "musai-agent")
        try Data("app binary".utf8).write(to: app)
        try Data("agent binary".utf8).write(to: agent)
        return (app, agent)
    }

    private func plist(_ data: Data) throws -> [String: Any] {
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(parsed as? [String: Any])
    }

    private func hooks(_ data: Data) -> [String: Any] {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (object?["hooks"] as? [String: Any]) ?? [:]
    }

    private func commands(_ hooks: [String: Any], _ event: String) -> [String] {
        let entries = (hooks[event] as? [[String: Any]]) ?? []
        return entries.flatMap { entry in
            ((entry["hooks"] as? [[String: Any]]) ?? []).compactMap { $0["command"] as? String }
        }
    }

    @Test func theAgentPlistSaysRunAtLoadAndKeepAlive() throws {
        let executable = URL(
            fileURLWithPath:
                "/tmp/Applications/Musai.app/Contents/Library/LoginItems/MusaiAgent.app/Contents/MacOS/MusaiAgent")
        let library = URL(fileURLWithPath: "/tmp/Musai.norvo")
        let values = try plist(
            MusaiInstall.agentPlist(executable: executable, label: "dev.musai.agent", library: library))

        #expect(values["Label"] as? String == "dev.musai.agent")
        #expect(values["RunAtLoad"] as? Bool == true)
        #expect(values["KeepAlive"] as? Bool == true)
        let program = try #require(values["Program"] as? String)
        #expect(program == executable.path)
        #expect(program.hasSuffix("MusaiAgent.app/Contents/MacOS/MusaiAgent"))
        // `--library`/`MUSAI_LIBRARY` choose the store at install time, so the agent must be told which one.
        let environment = values["EnvironmentVariables"] as? [String: String]
        #expect(environment?["MUSAI_LIBRARY"] == library.path)
    }

    @Test func installingTwiceChangesNothing() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let built = try built(in: workspace)
        let into = workspace.appending(path: "Applications")
        let launchAgents = workspace.appending(path: "LaunchAgents")
        let library = workspace.appending(path: "Musai.norvo")

        func install() throws -> URL {
            try MusaiInstall.installBundle(
                app: built.app, agent: built.agent, into: into,
                launchAgentsDirectory: launchAgents, library: library, resources: Self.resources)
        }

        let first = try install()
        let firstPlist = try Data(contentsOf: launchAgents.appending(path: "dev.musai.agent.plist"))
        let firstBinary = try Data(contentsOf: first.appending(path: "Contents/MacOS/Musai"))

        let second = try install()
        let secondPlist = try Data(contentsOf: launchAgents.appending(path: "dev.musai.agent.plist"))
        let secondBinary = try Data(contentsOf: second.appending(path: "Contents/MacOS/Musai"))

        #expect(first == second)
        #expect(firstPlist == secondPlist)
        #expect(firstBinary == secondBinary)
    }

    @Test func installWritesTheBundleWhereItWasAsked() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let built = try built(in: workspace)
        let into = workspace.appending(path: "Elsewhere")
        let launchAgents = workspace.appending(path: "LaunchAgents")

        let root = try MusaiInstall.installBundle(
            app: built.app, agent: built.agent, into: into,
            launchAgentsDirectory: launchAgents, library: workspace.appending(path: "Musai.norvo"),
            resources: Self.resources)

        #expect(root == into.appending(path: "Musai.app"))
        #expect(
            FileManager.default.fileExists(
                atPath: into.appending(path: "Musai.app/Contents/MacOS/Musai").path))
        #expect(
            FileManager.default.fileExists(
                atPath: launchAgents.appending(path: "dev.musai.agent.plist").path))
    }

    @Test func uninstallRemovesThePlistAndTheBundle() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let built = try built(in: workspace)
        let into = workspace.appending(path: "Applications")
        let launchAgents = workspace.appending(path: "LaunchAgents")
        let root = try MusaiInstall.installBundle(
            app: built.app, agent: built.agent, into: into,
            launchAgentsDirectory: launchAgents, library: workspace.appending(path: "Musai.norvo"),
            resources: Self.resources)

        try MusaiInstall.uninstall(bundle: root, launchAgentsDirectory: launchAgents)

        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(
            !FileManager.default.fileExists(
                atPath: launchAgents.appending(path: "dev.musai.agent.plist").path))
    }

    /// Installing the bundle must not cost the host its hooks, and taking the bundle out must take ours with
    /// it — while leaving the other host's hook exactly where it was.
    @Test func installingKeepsTheClaudeCodeHooks() throws {
        let workspace = try workspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let built = try built(in: workspace)
        let into = workspace.appending(path: "Applications")
        let launchAgents = workspace.appending(path: "LaunchAgents")
        let settings = workspace.appending(path: "settings.json")
        try Data(
            #"""
            {"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash '/Users/x/.claude/hooks/herdr-agent-state.sh' stop","timeout":10}]}]}}
            """#.utf8
        ).write(to: settings)

        let root = try MusaiInstall.installBundle(
            app: built.app, agent: built.agent, into: into,
            launchAgentsDirectory: launchAgents, library: workspace.appending(path: "Musai.norvo"),
            resources: Self.resources)
        try ClaudeCodeHooks.install(executable: "/usr/local/bin/musai", settingsURL: settings)

        let installed = hooks(try Data(contentsOf: settings))
        #expect(commands(installed, "Stop").contains { $0.contains("musai") })
        #expect(commands(installed, "Stop").contains { $0.contains("herdr-agent-state.sh") })

        try MusaiInstall.uninstall(bundle: root, launchAgentsDirectory: launchAgents)
        try ClaudeCodeHooks.uninstall(settingsURL: settings)

        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(
            !FileManager.default.fileExists(
                atPath: launchAgents.appending(path: "dev.musai.agent.plist").path))
        let after = hooks(try Data(contentsOf: settings))
        #expect(!commands(after, "Stop").contains { $0.contains("musai") })
        #expect(commands(after, "Stop").contains { $0.contains("herdr-agent-state.sh") })
    }
}
