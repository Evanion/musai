import Foundation
import NorvoLite

/// What the person chose in front of one proposal.
public enum ReviewAction: Sendable, Equatable {
    /// Settled, and landed nowhere: the gap.
    case settle
    /// Settled, and recorded where it landed, outside Musai.
    case persist(documentRef: String)
    case drop
    case skip
}

public struct Proposal: Sendable, Equatable, Codable {
    public let id: UUID
    public let title: String
    public let rationale: String?
    public let act: ActKind
    /// The person's own words, from the turn the proposal came from.
    public let said: String?
}

/// A decision that was settled and recorded nowhere. This set is the risk the loop exists to close.
public struct Gap: Sendable, Equatable, Codable {
    public let id: UUID
    public let title: String
    public let act: ActKind
    public let said: String?
    public let settledAt: Date?
}

public struct ReviewSession: Sendable {
    public let db: Database
    public init(db: Database) { self.db = db }

    public func pending() async throws -> [Proposal] {
        try await db.query(PendingDecisionsQuery()).decisions.map {
            Proposal(id: $0.id, title: $0.title, rationale: $0.rationale, act: $0.act, said: $0.utterance?.text)
        }
    }

    public func unpersisted() async throws -> [Gap] {
        try await db.query(UnpersistedDecisionsQuery()).decisions.map {
            Gap(id: $0.id, title: $0.title, act: $0.act, said: $0.utterance?.text, settledAt: $0.settledAt)
        }
    }

    /// One action maps to one operation. `actor` is the person: the history should record who confirmed it,
    /// not the curator that proposed it.
    public func apply(_ action: ReviewAction, to id: UUID, as actor: Actor) async throws {
        switch action {
        case .settle:
            _ = try await db.mutate(SettleDecisionMutation(.init(id: id, settledAt: Date())), as: actor)
        case .persist(let documentRef):
            _ = try await db.mutate(
                PersistDecisionOutsideMutation(.init(id: id, documentRef: documentRef, persistedAt: Date())),
                as: actor)
        case .drop:
            _ = try await db.mutate(DropProposalMutation(.init(id: id)), as: actor)
        case .skip:
            break
        }
    }
}
