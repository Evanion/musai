import Foundation

/// Installs the backend onto this machine: the one `Musai.app` bundle and the launch agent that keeps it
/// running. It is host-agnostic — it knows the bundle and launchd, and nothing about any particular client —
/// and it is reversible and idempotent: a second install changes nothing, and uninstalling takes back exactly
/// what installing put down.
public enum MusaiInstall {
    /// The launch agent's label. The plist is written under this name, and a client asks launchd to start the
    /// job under the same one.
    public static let agentLabel = "dev.musai.agent"

    /// The launch agent's property list: start at login, keep alive, and run the agent inside the bundle it was
    /// handed. It carries the store the agent serves, because `--library`/`MUSAI_LIBRARY` choose that store at
    /// install time rather than at every launch.
    public static func agentPlist(executable: URL, label: String, library: URL) -> Data {
        let values: [String: Any] = [
            "Label": label,
            "Program": executable.path,
            "RunAtLoad": true,
            "KeepAlive": true,
            "EnvironmentVariables": ["MUSAI_LIBRARY": library.path],
        ]
        return (try? PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0))
            ?? Data()
    }

    /// Assembles `Musai.app` where it was asked, then writes the launch agent that starts its nested agent at
    /// login. `app` and `agent` are the built executables; `resources` holds the two `Info.plist`s. Returns the
    /// bundle root. The bundle is replaced whole and the plist rewritten the same way each time, so assembling
    /// twice leaves both byte-identical.
    @discardableResult
    public static func installBundle(
        app: URL, agent: URL, into: URL, launchAgentsDirectory: URL, library: URL, resources: URL
    ) throws -> URL {
        let root = try MusaiBundle.assemble(app: app, agent: agent, into: into, resources: resources)
        let agentExecutable = root.appending(
            path: "Contents/Library/LoginItems/\(MusaiBundle.agentName).app/Contents/MacOS/\(MusaiBundle.agentName)")
        try FileManager.default.createDirectory(
            at: launchAgentsDirectory, withIntermediateDirectories: true)
        try agentPlist(executable: agentExecutable, label: agentLabel, library: library)
            .write(to: launchAgentsDirectory.appending(path: "\(agentLabel).plist"))
        return root
    }

    /// Removes the bundle and its launch agent. An already-absent file is not an error: uninstalling twice is a
    /// no-op, and a person who removed one of the two by hand can still run this to take back the other.
    public static func uninstall(bundle: URL, launchAgentsDirectory: URL) throws {
        let plist = launchAgentsDirectory.appending(path: "\(agentLabel).plist")
        if FileManager.default.fileExists(atPath: plist.path) {
            try FileManager.default.removeItem(at: plist)
        }
        if FileManager.default.fileExists(atPath: bundle.path) {
            try FileManager.default.removeItem(at: bundle)
        }
    }
}
