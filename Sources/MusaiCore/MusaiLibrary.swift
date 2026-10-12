import Foundation
import NorvoLite

/// A Musai library: the single Norvo Lite file holding every project.
public final class MusaiLibrary: Sendable {
    public let db: Database

    private init(db: Database) { self.db = db }

    public static func open(at url: URL, options: Options = .init()) async throws -> MusaiLibrary {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let library = MusaiLibrary(db: try Database.open(at: url, options: options))
        _ = try await library.db.migrate(NorvoSchema.migrations)
        return library
    }

    public static func inMemory(options: Options = .init()) async throws -> MusaiLibrary {
        let library = MusaiLibrary(db: try Database.inMemory(options: options))
        _ = try await library.db.migrate(NorvoSchema.migrations)
        return library
    }

    public static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Musai/Musai.norvo")
    }

    public func close() { db.close() }
}
