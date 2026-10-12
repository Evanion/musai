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

    /// Prints the gap first, because that is the risk the person came to see, then walks the proposals and
    /// reads one key per line. Returns how many it acted on.
    @discardableResult
    public func run(as actor: Actor) async throws -> Int {
        let gap = try await unpersisted()
        if !gap.isEmpty {
            print("\(gap.count) decision\(gap.count == 1 ? "" : "s") were settled and never recorded anywhere:")
            for entry in gap { print("  · \(entry.title)") }
            print("")
        }

        let proposals = try await pending()
        guard !proposals.isEmpty else {
            if gap.isEmpty { print("nothing pending") }
            return 0
        }

        var acted = 0
        for (index, proposal) in proposals.enumerated() {
            var headline = "[\(index + 1)/\(proposals.count)] \(proposal.title)   (\(proposal.act.displayName)"
            if let said = proposal.said { headline += ", said: \"\(said)\"" }
            print(headline + ")")
            if let rationale = proposal.rationale { print("  \(rationale)") }
            print("  [y] settled, landed nowhere   [r] settled, landed at…   [d] drop   [s] skip")

            guard let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
                break
            }
            switch answer {
            case "y":
                try await apply(.settle, to: proposal.id, as: actor)
                acted += 1
            case "r":
                guard let reference = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !reference.isEmpty
                else { continue }
                try await apply(.persist(documentRef: reference), to: proposal.id, as: actor)
                acted += 1
            case "d":
                try await apply(.drop, to: proposal.id, as: actor)
                acted += 1
            default:
                // An unrecognised key is a skip: a wrong confirmation is worse than a missed one.
                continue
            }
        }
        return acted
    }
}
