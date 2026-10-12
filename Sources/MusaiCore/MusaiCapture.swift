import Foundation
import NorvoLite

/// Writes the exchange into the graph: the user's turns verbatim as `Utterance`s, and everything else as
/// `Event`s — the expiring queue the curator drains. A tool's result is never captured.
public struct MusaiCapture: Sendable {
    /// Over this size a captured text is truncated, never written whole.
    public static let maxTextBytes = 65_536

    public let db: Database
    public init(db: Database) { self.db = db }

    /// Returns the `Utterance`'s id — of the row it created, or of the one already there.
    @discardableResult
    public func captureUserTurn(
        text: String, at: Date, origin: String?, session: String, cwd: String, as actor: Actor
    ) async throws -> UUID {
        try await bind(session: session, cwd: cwd, origin: origin, at: at, as: actor)
        let capped = Self.truncated(text, to: Self.maxTextBytes)
        let rows = try await db.query(UtterancesForSessionQuery(.init(session: session))).utterances
        let utterance: UUID
        if let found = rows.first(where: {
            $0.speaker == .user && $0.text == capped && Self.sameInstant($0.at, at)
        }) {
            utterance = found.id
        } else {
            utterance = try await db.mutate(
                RecordUtteranceMutation(
                    .init(text: capped, at: at, speaker: .user, origin: origin, session: session)),
                as: actor).createUtterance.id
        }
        // The queue holds the exchange in order, so the user's turn is there too — and its durable copy is the
        // row a proposal links to, which is why it is written first.
        let queued = try await db.query(EventsForSessionQuery(.init(session: session))).events
        if !queued.contains(where: {
            $0.kind == .userTurn && $0.text == capped && Self.sameInstant($0.at, at)
        }) {
            _ = try await db.mutate(
                RecordEventMutation(.init(kind: .userTurn, at: at, text: capped, session: session)), as: actor)
        }
        return utterance
    }

    /// The agent's own account of its turn. Kept as an `Event`; the curator decides how much of it survives.
    @discardableResult
    public func captureAgentTurn(text: String?, at: Date, session: String, cwd: String, as actor: Actor) async throws -> UUID? {
        guard let text, !text.isEmpty else { return nil }
        try await bind(session: session, cwd: cwd, origin: nil, at: at, as: actor)
        let capped = Self.truncated(text, to: Self.maxTextBytes)
        let rows = try await db.query(EventsForSessionQuery(.init(session: session))).events
        if rows.contains(where: { $0.kind == .agentTurn && $0.text == capped && Self.sameInstant($0.at, at) }) {
            return nil
        }
        let made = try await db.mutate(
            RecordEventMutation(.init(kind: .agentTurn, at: at, text: capped, session: session)), as: actor)
        return made.createEvent.id
    }

    /// A tool use, as a reference: what ran and on what, never what it produced.
    public func captureToolUse(
        tool: String, target: String?, digest: String?, at: Date, session: String, cwd: String, as actor: Actor
    ) async throws {
        try await bind(session: session, cwd: cwd, origin: nil, at: at, as: actor)
        let rows = try await db.query(EventsForSessionQuery(.init(session: session))).events
        if rows.contains(where: {
            $0.kind == .toolUse && $0.tool == tool && $0.target == target && $0.digest == digest
                && Self.sameInstant($0.at, at)
        }) {
            return
        }
        _ = try await db.mutate(
            RecordEventMutation(
                .init(kind: .toolUse, at: at, tool: tool, target: target, digest: digest, session: session)),
            as: actor)
    }

    /// The session must exist before anything links to it, and binding is idempotent.
    private func bind(session: String, cwd: String, origin: String?, at: Date, as actor: Actor) async throws {
        _ = try await ProjectBinder(db: db).bind(
            cwd: URL(fileURLWithPath: cwd), memorySessionId: session, platform: origin ?? "unknown",
            startedAt: at, as: actor)
    }

    /// Truncates on a UTF-8 boundary, never mid-scalar.
    public static func truncated(_ text: String, to bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        var out = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > bytes { break }
            out.append(character)
            used += size
        }
        return out
    }

    /// Norvo stores a `DateTime` to the millisecond, so that is the granularity two captures can be compared at.
    static func sameInstant(_ lhs: Date, _ rhs: Date) -> Bool {
        Int((lhs.timeIntervalSince1970 * 1_000).rounded()) == Int((rhs.timeIntervalSince1970 * 1_000).rounded())
    }
}
