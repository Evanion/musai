import CryptoKit
import Foundation
import NorvoLite

/// A session bound to the project its working directory resolved to.
public struct BoundSession: Sendable, Equatable {
    public let id: UUID
    public let memorySessionId: String
    public let projectSlug: String
}

/// Resolves a working directory to a Project and binds a Session to it.
public struct ProjectBinder: Sendable {
    public let db: Database
    public init(db: Database) { self.db = db }

    /// A remote in one canonical form, so an SSH clone and an HTTPS clone of one repository match.
    public static func normalizedRemote(_ remote: String) -> String {
        var text = remote.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasSuffix(".git") { text.removeLast(4) }
        if text.contains("://") {
            for scheme in ["https://", "http://", "ssh://", "git://"] where text.hasPrefix(scheme) {
                text.removeFirst(scheme.count)
                break
            }
            // Drop the userinfo: `git@`, and any credentials a remote URL carries, so they never reach the store.
            if let at = text.firstIndex(of: "@"), at < (text.firstIndex(of: "/") ?? text.endIndex) {
                text = String(text[text.index(after: at)...])
            }
            return text
        }
        if let at = text.firstIndex(of: "@"), let colon = text.firstIndex(of: ":"), at < colon {
            let host = text[text.index(after: at)..<colon]
            let path = text[text.index(after: colon)...]
            return "\(host)/\(path)"
        }
        return text
    }

    /// Walks up from `cwd` for a repository and reads its `origin` URL, normalized. Handles a worktree's
    /// `.git` file, and returns `nil` when there is no repository or no origin.
    public static func gitRemote(for cwd: URL) -> String? {
        var directory = cwd.standardizedFileURL
        while true {
            let dotGit = directory.appending(path: ".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                guard let config = configFile(for: dotGit, isDirectory: isDirectory.boolValue, in: directory),
                    let text = try? String(contentsOf: config, encoding: .utf8),
                    let url = originURL(in: text)
                else { return nil }
                return normalizedRemote(url)
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
    }

    /// Walks up from `cwd`, finds or creates the Project, then upserts the Session bound to it.
    public func bind(cwd: URL, memorySessionId: String, platform: String, title: String? = nil,
        startedAt: Date, as actor: Actor
    ) async throws -> BoundSession {
        let slug = try await resolveProject(cwd: cwd, as: actor)
        // Re-binding a session must not resurrect one that already finished.
        let existing = try await db.query(SessionByMemoryIdQuery(.init(memorySessionId: memorySessionId))).session
        let session = try await db.mutate(
            UpsertSessionMutation(
                .init(
                    memorySessionId: memorySessionId,
                    platform: platform,
                    cwd: cwd.path,
                    title: title,
                    status: existing?.status ?? .active,
                    startedAt: startedAt,
                    slug: slug)),
            as: actor)
        return BoundSession(id: session.upsertSession.id, memorySessionId: memorySessionId, projectSlug: slug)
    }

    /// The project a working directory belongs to, creating it when it is not known yet — the same
    /// resolution `bind` makes, without upserting a session. The capture path and the drain use this.
    public func resolveProject(cwd: URL, as actor: Actor) async throws -> String {
        try await projectSlug(cwd: cwd, remote: Self.gitRemote(for: cwd), as: actor)
    }

    /// The project a working directory belongs to, when one is already known. A read must not write: a
    /// typo'd `cwd` gets nothing, not a junk project left behind.
    public func knownProject(cwd: URL) async throws -> String? {
        try await lookupProject(cwd: cwd, remote: Self.gitRemote(for: cwd))
    }

    /// The bound project's slug: by normalized remote, then by root path, then a new Project.
    private func projectSlug(cwd: URL, remote: String?, as actor: Actor) async throws -> String {
        if let known = try await lookupProject(cwd: cwd, remote: remote) { return known }
        let name = cwd.lastPathComponent
        let base = Self.slugBase(name)
        let taken = try await db.query(ProjectBySlugQuery(.init(slug: base))).project != nil
        let slug = taken ? "\(base)-\(Self.pathSuffix(cwd.path))" : base
        _ = try await db.mutate(
            UpsertProjectMutation(.init(name: name, slug: slug, repoRemote: remote, rootPath: cwd.path)),
            as: actor)
        return slug
    }

    /// The known project's slug, by normalized remote, then by root path.
    private func lookupProject(cwd: URL, remote: String?) async throws -> String? {
        if let remote,
            let found = try await db.query(ProjectByRemoteQuery(.init(remote: remote))).projects.first {
            return found.slug
        }
        return try await db.query(ProjectByRootQuery(.init(root: cwd.path))).projects.first?.slug
    }

    /// The ASCII-alphanumeric-and-dash base of a directory name; `project` when nothing is left of it.
    static func slugBase(_ name: String) -> String {
        var out = ""
        var pendingDash = false
        for character in name.lowercased() {
            if character.isASCII && (character.isLetter || character.isNumber) {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(character)
            } else {
                pendingDash = true
            }
        }
        return out.isEmpty ? "project" : out
    }

    /// Four bytes of the path's SHA-256 as hex, so two directories of one name get distinct slugs.
    static func pathSuffix(_ path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// The config file for a `.git` directory, or the one a `.git` file leads to, through `commondir` when the
    /// `.git` file names a linked worktree (whose own gitdir holds no config).
    private static func configFile(for dotGit: URL, isDirectory: Bool, in directory: URL) -> URL? {
        if isDirectory { return dotGit.appending(path: "config") }
        guard let contents = try? String(contentsOf: dotGit, encoding: .utf8),
            let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
        else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        let gitDir = resolved(path.hasPrefix("/") ? path : directory.appending(path: path).path)
        let direct = gitDir.appending(path: "config")
        if FileManager.default.fileExists(atPath: direct.path) { return direct }
        guard let common = try? String(contentsOf: gitDir.appending(path: "commondir"), encoding: .utf8) else {
            return direct
        }
        let relative = common.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !relative.isEmpty else { return direct }
        let commonDir = resolved(relative.hasPrefix("/") ? relative : gitDir.appending(path: relative).path)
        return commonDir.appending(path: "config")
    }

    /// A path with `.` and `..` resolved, which `URL.appending(path:)` leaves in place.
    private static func resolved(_ path: String) -> URL {
        URL(fileURLWithPath: path).standardizedFileURL
    }

    /// The `url` of the `[remote "origin"]` section.
    private static func originURL(in config: String) -> String? {
        var inOrigin = false
        for raw in config.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inOrigin = line == "[remote \"origin\"]"
                continue
            }
            guard inOrigin, let equals = line.firstIndex(of: "=") else { continue }
            if line[..<equals].trimmingCharacters(in: .whitespaces) == "url" {
                return line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
