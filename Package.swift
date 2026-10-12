// swift-tools-version: 6.1
import Foundation
import PackageDescription

// Norvo Lite is under active development; point MUSAI_NORVO_PATH at a checkout (a worktree needs it).
let norvoPath = ProcessInfo.processInfo.environment["MUSAI_NORVO_PATH"] ?? "../norvo-swift"

let package = Package(
    name: "Musai",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MusaiCore", targets: ["MusaiCore"]),
        .executable(name: "musai", targets: ["musai"]),
        .executable(name: "musai-agent", targets: ["musai-agent"]),
    ],
    dependencies: [.package(path: norvoPath)],
    targets: [
        .target(
            name: "MusaiCore",
            dependencies: [.product(name: "NorvoLite", package: "norvo-swift")],
            exclude: ["schema.nql", "migrations", "operations"],
            plugins: [.plugin(name: "NorvoCodegen", package: "norvo-swift")]
        ),
        .executableTarget(name: "musai", dependencies: ["MusaiCore"]),
        // The menu-bar agent: it owns the store and serves the endpoint. Its only dependency is the core, so
        // the protocol and the lifecycle are tested without a GUI.
        .executableTarget(name: "musai-agent", dependencies: ["MusaiCore"]),
        // The executable is a dependency so the host adapter's tests — which must live with the adapter, in
        // the CLI — can reach it through `@testable import musai`.
        .testTarget(name: "MusaiCoreTests", dependencies: ["MusaiCore", "musai"])
    ]
)
