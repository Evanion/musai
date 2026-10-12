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
        .testTarget(name: "MusaiCoreTests", dependencies: ["MusaiCore"])
    ]
)
