import Foundation
import NorvoLite

/// Drains the queue into proposals. The detector runs before anything is marked drained, so a failed run leaves
/// the queue intact and the next drain retries it.
public struct ProposalCurator: Sendable {
    /// Longer than this and a proposal is not something a person reads at a glance.
    public static let maxTitleCharacters = 200

    public let db: Database
    public let detector: any DecisionDetector
    public let batch: Int

    public init(db: Database, detector: any DecisionDetector, batch: Int = 50) {
        self.db = db
        self.detector = detector
        self.batch = batch
    }

    @discardableResult
    public func drain(project: String, as actor: Actor) async throws -> Int {
        let events = try await db.query(UndrainedEventsQuery(.init(first: batch))).events
        guard !events.isEmpty else { return 0 }

        var turnsBySession: [String: [(at: Date, id: UUID)]] = [:]
        var detected: [DetectedEvent] = []
        for event in events {
            let session = event.session?.memorySessionId ?? ""
            let turns: [(at: Date, id: UUID)]
            if let known = turnsBySession[session] {
                turns = known
            } else {
                let rows = try await db.query(UtterancesForSessionQuery(.init(session: session))).utterances
                turns = rows.map { (at: $0.at, id: $0.id) }.sorted { $0.at < $1.at }
                turnsBySession[session] = turns
            }
            detected.append(
                DetectedEvent(
                    id: event.id, kind: event.kind, text: event.text, tool: event.tool,
                    target: event.target, at: event.at,
                    utterance: turns.last(where: { $0.at <= event.at })?.id))
        }

        // Before marking anything drained: a throw here must leave the queue for the next drain.
        let proposed = try await detector.propose(from: detected)

        var written = 0
        for candidate in proposed {
            let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
            // A proposal the person cannot trace to their own words, or cannot read, is clerk work.
            guard let utterance = candidate.utterance,
                !title.isEmpty,
                title.count <= Self.maxTitleCharacters
            else { continue }
            _ = try await db.mutate(
                RecordProposalMutation(
                    .init(
                        title: title, rationale: candidate.rationale, act: candidate.act,
                        utterance: utterance, project: project)),
                as: actor)
            written += 1
        }

        let now = Date()
        for event in events {
            _ = try await db.mutate(MarkEventDrainedMutation(.init(id: event.id, drainedAt: now)), as: actor)
        }
        return written
    }
}
