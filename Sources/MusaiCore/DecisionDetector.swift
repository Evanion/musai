import Foundation

/// One thing the hooks saw, in the order it happened. A detector sees events and never the store, so it cannot
/// write.
public struct DetectedEvent: Sendable, Equatable {
    public let id: UUID
    public let kind: EventKind
    public let text: String?
    public let tool: String?
    public let target: String?
    public let at: Date
    /// The durable record of the user's turn this event belongs to, when there is one.
    public let utterance: UUID?

    public init(id: UUID, kind: EventKind, text: String?, tool: String?, target: String?, at: Date, utterance: UUID?) {
        self.id = id
        self.kind = kind
        self.text = text
        self.tool = tool
        self.target = target
        self.at = at
        self.utterance = utterance
    }
}

/// A decision the detector believes it saw the person settle — in their words, not the agent's.
public struct DetectedDecision: Sendable, Equatable {
    public let title: String
    public let rationale: String?
    public let act: ActKind
    public let utterance: UUID?

    public init(title: String, rationale: String?, act: ActKind, utterance: UUID?) {
        self.title = title
        self.rationale = rationale
        self.act = act
        self.utterance = utterance
    }
}

public protocol DecisionDetector: Sendable {
    func propose(from events: [DetectedEvent]) async throws -> [DetectedDecision]
}
