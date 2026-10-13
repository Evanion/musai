import Foundation
import Testing
@testable import MusaiCore

@Suite struct BundleTests {
    /// The `Info.plist`s live in the repository, not in this test, so the test reads the real ones.
    private static var resources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MusaiCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // the package root
            .appending(path: "Resources")
    }

    /// Assembles a bundle from stand-in executables into its own temporary directory.
    private func assembled() throws -> (root: URL, workspace: URL) {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-bundle-\(UUID().uuidString)")
        let built = workspace.appending(path: "built")
        try FileManager.default.createDirectory(at: built, withIntermediateDirectories: true)
        let app = built.appending(path: "Musai")
        let agent = built.appending(path: "MusaiAgent")
        try Data("app binary".utf8).write(to: app)
        try Data("agent binary".utf8).write(to: agent)
        let root = try MusaiBundle.assemble(
            app: app, agent: agent, into: workspace, resources: Self.resources)
        return (root, workspace)
    }

    @Test func assembleWritesTheBundleTree() throws {
        let made = try assembled()
        defer { try? FileManager.default.removeItem(at: made.workspace) }

        #expect(made.root.lastPathComponent == "Musai.app")
        let contents = made.root.appending(path: "Contents")
        let expected = [
            "Info.plist",
            "MacOS/Musai",
            "Library/LoginItems/MusaiAgent.app/Contents/Info.plist",
            "Library/LoginItems/MusaiAgent.app/Contents/MacOS/MusaiAgent",
        ]
        for relative in expected {
            let path = contents.appending(path: relative).path
            #expect(FileManager.default.fileExists(atPath: path), "missing \(relative)")
        }
    }

    @Test func theNestedAgentIsAMenuBarApp() throws {
        let made = try assembled()
        defer { try? FileManager.default.removeItem(at: made.workspace) }

        let plist = made.root.appending(
            path: "Contents/Library/LoginItems/MusaiAgent.app/Contents/Info.plist")
        let values = try Self.parsed(plist)
        // `LSUIElement` is what keeps the agent out of the Dock: it is a menu-bar item, not an app.
        #expect(values["LSUIElement"] as? Bool == true)
        #expect(values["CFBundleExecutable"] as? String == "MusaiAgent")
    }

    @Test func theOuterBundleNamesMusaiAndCarriesThePackageVersion() throws {
        let made = try assembled()
        defer { try? FileManager.default.removeItem(at: made.workspace) }

        let values = try Self.parsed(made.root.appending(path: "Contents/Info.plist"))
        #expect(values["CFBundleName"] as? String == "Musai")
        #expect(values["CFBundleExecutable"] as? String == "Musai")
        #expect(values["CFBundleShortVersionString"] as? String == MusaiBundle.version)
    }

    private static func parsed(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any])
    }
}
