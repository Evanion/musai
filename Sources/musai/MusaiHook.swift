import Foundation
import MusaiCore

/// The `musai` executable: the seam the host's hooks call. Every path exits 0, because a hook that fails must not
/// fail the session it is reporting on.
@main
struct MusaiHook {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        guard let command = arguments.first else { return }
        arguments.removeFirst()

        var libraryPath: String?
        if let index = arguments.firstIndex(of: "--library"), index + 1 < arguments.count {
            libraryPath = arguments[index + 1]
            arguments.removeSubrange(index...(index + 1))
        }
        let path = libraryPath ?? ProcessInfo.processInfo.environment["MUSAI_LIBRARY"]
        let url = path.map { URL(fileURLWithPath: $0) } ?? MusaiLibrary.defaultFileURL

        do {
            switch command {
            case "hook":
                let event: String? = arguments.first
                let stdin = FileHandle.standardInput.readDataToEndOfFile()
                let library = try await MusaiLibrary.open(at: url)
                let runner = HookRunner(capture: MusaiCapture(db: library.db), library: library)
                emit(
                    await runner.run(
                        event: event, stdin: stdin,
                        cwd: FileManager.default.currentDirectoryPath))
            case "review":
                let library = try await MusaiLibrary.open(at: url)
                _ = try await ReviewSession(db: library.db).run(as: MusaiActors.user)
            default:
                return
            }
        } catch {
            FileHandle.standardError.write(Data("musai: \(error)\n".utf8))
        }
    }

    private static func emit(_ outcome: HookOutcome) {
        if let stdout = outcome.stdout {
            FileHandle.standardOutput.write(Data("\(stdout)\n".utf8))
        }
        if let diagnostic = outcome.diagnostic {
            FileHandle.standardError.write(Data("\(diagnostic)\n".utf8))
        }
    }
}
