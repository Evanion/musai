import Foundation
import NorvoLite

/// Drains the queue into proposals. The model runs before anything is written, and then each project's
/// proposals and the drained marks of the events that produced them are written in one transaction, so a
/// crash can neither double-file a decision nor half-file it.
public struct ProposalCurator: Sendable {
    /// Longer than this and a proposal is not something a person reads at a glance.
    public static let maxTitleCharacters = 200
    /// The queue keeps a drained event at least this long; older ones are dropped by `expireDrainedEvents`.
    public static let retentionWindow: TimeInterval = 30 * 24 * 60 * 60
    /// How many of the queue's events one drain reads. Named so the producer's own read of the queue is the
    /// same batch this drain consumes, rather than a second bound that can drift from it.
    public static let defaultBatch = 50

    public let db: Database
    public let detector: any DecisionDetector
    public let batch: Int

    public init(db: Database, detector: any DecisionDetector, batch: Int = ProposalCurator.defaultBatch) {
        self.db = db
        self.detector = detector
        self.batch = batch
    }

    /// Drains the queue: one detector call per project — its prompt is one working session — and every
    /// proposal filed under the project of the session its event belongs to. Each project's proposals are
    /// written together with the drained marks of its events, in one transaction; the model call stays
    /// outside it, so it never holds Lite's single writer.
    @discardableResult
    public func drain(as actor: Actor) async throws -> Int {
        let events = try await db.query(UndrainedEventsQuery(.init(first: batch))).events
        guard !events.isEmpty else { return 0 }

        // Group the queue by the project each event's session belongs to, in queue order. An event whose
        // session resolves to no project is left for a later drain rather than filed anywhere wrong.
        var projects: [String] = []
        var groups: [String: [UndrainedEventsQuery.Data.Events]] = [:]
        for event in events {
            guard let slug = event.session?.project?.slug else { continue }
            if groups[slug] == nil { projects.append(slug) }
            groups[slug, default: []].append(event)
        }

        var turnsBySession: [String: [(at: Date, id: UUID)]] = [:]
        var written = 0
        for project in projects {
            let group = groups[project] ?? []
            var detected: [DetectedEvent] = []
            for event in group {
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

            // The queue event a proposal came from: the turn the detector linked it to names that event, and
            // its id is the proposal's origin. The first event carrying the turn wins, so a replay picks the
            // same one.
            var origins: [UUID: String] = [:]
            for event in detected {
                if let utterance = event.utterance, origins[utterance] == nil {
                    origins[utterance] = event.id.uuidString
                }
            }

            // Before any write: a throw here leaves the queue intact for the next drain.
            let proposed = try await detector.propose(from: detected)

            written += try await db.transaction(as: actor) { tx in
                let candidates: [(decision: DetectedDecision, origin: String)] = proposed.compactMap { candidate in
                    guard let utterance = candidate.utterance, let origin = origins[utterance] else { return nil }
                    return (candidate, origin)
                }
                // Read before writing: what a previous drain already filed under these origins. Reading inside
                // the transaction is serializable, so the skip is decided against a settled store.
                var alreadyFiled: Set<String> = []
                for origin in Set(candidates.map { $0.origin }) {
                    if try await tx.query(DecisionByOriginQuery(.init(origin: origin))).decisions.first != nil {
                        alreadyFiled.insert(origin)
                    }
                }
                var filed = 0
                for candidate in candidates {
                    if alreadyFiled.contains(candidate.origin) { continue }
                    let title = candidate.decision.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !title.isEmpty, title.count <= Self.maxTitleCharacters,
                        let utterance = candidate.decision.utterance
                    else { continue }
                    _ = try await tx.mutate(
                        RecordProposalMutation(
                            .init(
                                title: title, rationale: candidate.decision.rationale,
                                act: candidate.decision.act, utterance: utterance, project: project,
                                origin: candidate.origin)))
                    filed += 1
                }
                let now = Date()
                for event in group {
                    _ = try await tx.mutate(MarkEventDrainedMutation(.init(id: event.id, drainedAt: now)))
                }
                return filed
            }
        }
        return written
    }

    /// The queue's own retention, in one mutation: drop the drained events older than `retentionWindow`.
    /// Undrained events are never touched — only the queue's redundancy expires, and the decisions it
    /// produced survive. Returns how many it dropped.
    @discardableResult
    public func expireDrainedEvents(now: Date, as actor: Actor) async throws -> Int {
        let cutoff = now.addingTimeInterval(-Self.retentionWindow)
        let dropped = try await db.mutate(DeleteDrainedEventsMutation(.init(before: cutoff)), as: actor)
        return dropped.deleteEvents.count
    }
}
