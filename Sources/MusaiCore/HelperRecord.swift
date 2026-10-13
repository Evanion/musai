import Darwin
import Foundation

/// Where every client learns to reach the backend: one small file in the Musai directory, written once the
/// listener is up. A client reads the port and the token from here rather than guessing either — which is why
/// the file is private, and why its fields are a contract rather than a convenient shape.
public struct HelperRecord: Sendable, Equatable, Codable {
    public let port: UInt16
    public let token: String
    public let pid: Int32
    public let protocolVersion: String
    public let storePath: String

    public init(port: UInt16, token: String, pid: Int32, protocolVersion: String, storePath: String) {
        self.port = port
        self.token = token
        self.pid = pid
        self.protocolVersion = protocolVersion
        self.storePath = storePath
    }

    /// `~/Library/Application Support/Musai/helper.json`, beside the store it names.
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Musai/helper.json")
    }

    /// Written 0600, private from creation. The token inside is the whole of the backend's authorisation, so
    /// no other user may read it — not even for the instant between create and chmod.
    public func write(to url: URL = defaultURL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writePrivate(try encoder.encode(self), to: url)
    }

    public static func read(from url: URL = defaultURL) throws -> HelperRecord {
        try JSONDecoder().decode(HelperRecord.self, from: Data(contentsOf: url))
    }

    /// Whether the process that wrote the record is still there. A stale record is a client's cue to start
    /// the agent — not to post the person's words to whatever now holds the port.
    public var isAlive: Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        // EPERM means the process exists but belongs to someone else; it is alive, however unreachable.
        return errno == EPERM
    }
}

/// The backend's shared secret: 32 random bytes as hex, kept in a 0600 file so it outlives a restart and only
/// this user can read it. The record republishes it for convenience; this file is the source of truth.
public enum MusaiToken {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Musai/token")
    }

    /// 32 random bytes, hex-encoded. `SystemRandomNumberGenerator` is the platform's secure source.
    public static func new() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        var generator = SystemRandomNumberGenerator()
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The token already on disk, or `nil` when there is none. A client reads it; only the agent mints one,
    /// so a hook that finds no backend never writes a secret as a side effect.
    public static func read(at url: URL = defaultURL) -> String? {
        guard let existing = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let token = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// The token already on disk, or a fresh one written 0600. An empty file is treated as absent — a blank
    /// token authorises no one, so it is replaced rather than honoured.
    public static func loadOrCreate(at url: URL = defaultURL) throws -> String {
        if let token = read(at: url) { return token }
        let token = new()
        try writePrivate(Data(token.utf8), to: url)
        return token
    }
}

/// Writes 0600 from birth: a file holding the token must never be readable, not even for the instant between
/// creation and a later chmod.
private func writePrivate(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard
        FileManager.default.createFile(
            atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600])
    else { throw CocoaError(.fileWriteUnknown) }
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
}
