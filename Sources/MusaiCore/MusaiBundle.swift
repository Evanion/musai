import Foundation

/// Assembles the one `.app` the window app and the menu-bar agent ship in, from the built executables and the
/// `Info.plist`s kept in the repository — because SwiftPM cannot produce an `.app` itself.
///
///     Musai.app/Contents/
///       Info.plist                                  the window app
///       MacOS/Musai                                 the window app
///       Library/LoginItems/MusaiAgent.app/          the menu-bar agent
///         Contents/Info.plist                       LSUIElement = true
///         Contents/MacOS/MusaiAgent
///
/// The agent is a nested `.app` rather than a second bare executable, so it gets its own `Info.plist` and
/// `LSUIElement` instead of relying on a runtime activation policy.
public enum MusaiBundle {
    /// The version this build ships as. SwiftPM gives a library target no version, so the number is declared
    /// here and must match the committed `App-Info.plist`; `assemble` refuses a plist that disagrees, and the
    /// bundle tests assert it, so the agent, the app and the code cannot drift apart.
    public static let version = "0.1.0"

    /// The bundle's name and the names of the two executables it holds.
    public static let appName = "Musai"
    public static let agentName = "MusaiAgent"

    /// Files the caller must supply from the repository.
    public static let appInfoPlistName = "App-Info.plist"
    public static let agentInfoPlistName = "Agent-Info.plist"

    /// Writes `Musai.app` under `into` and returns its root. `app` and `agent` are the built executables;
    /// `resources` holds the two `Info.plist`s. An existing bundle at the destination is replaced whole, so
    /// assembly is idempotent rather than layered.
    @discardableResult
    public static func assemble(app: URL, agent: URL, into: URL, resources: URL) throws -> URL {
        let root = into.appending(path: "\(appName).app")
        let contents = root.appending(path: "Contents")
        let nested = contents.appending(path: "Library/LoginItems/\(agentName).app")

        // Replaced whole, so assembling over an existing bundle is idempotent rather than layered, and a file
        // a previous build left behind cannot survive into the new one.
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: contents.appending(path: "MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: nested.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)

        let appPlist = resources.appending(path: appInfoPlistName)
        let agentPlist = resources.appending(path: agentInfoPlistName)
        try requireVersion(of: appPlist, equalTo: version)
        try FileManager.default.copyItem(
            at: appPlist, to: contents.appending(path: "Info.plist"))
        try FileManager.default.copyItem(
            at: agentPlist, to: nested.appending(path: "Contents/Info.plist"))

        try installExecutable(app, at: contents.appending(path: "MacOS/\(appName)"))
        try installExecutable(agent, at: nested.appending(path: "Contents/MacOS/\(agentName)"))
        return root
    }

    /// Copies a built executable into place and makes it runnable: a bundle's `MacOS/` file is executed, not
    /// read.
    private static func installExecutable(_ source: URL, at destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }

    /// Refuses to build a bundle whose committed plist carries a different version from this code, so a
    /// person never gets a `Musai.app` that lies about what it is.
    private static func requireVersion(of plist: URL, equalTo expected: String) throws {
        let data = try Data(contentsOf: plist)
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
        guard let values = object as? [String: Any],
            let found = values["CFBundleShortVersionString"] as? String
        else { throw Failure.plistIsNotADictionary(plist.lastPathComponent) }
        guard found == expected else {
            throw Failure.versionMismatch(plist: plist.lastPathComponent, found: found, expected: expected)
        }
    }

    public enum Failure: Error, Equatable {
        case plistIsNotADictionary(String)
        case versionMismatch(plist: String, found: String, expected: String)
    }
}
