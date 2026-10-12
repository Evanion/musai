import Foundation

/// The first real detector: a model behind whatever provider is configured. The prompt and the parsing live
/// here; which model answers, and where it runs, do not.
public struct ModelDecisionDetector: DecisionDetector {
    public let provider: any ModelProvider

    public init(provider: any ModelProvider) {
        self.provider = provider
    }

    public func propose(from events: [DetectedEvent]) async throws -> [DetectedDecision] {
        guard !events.isEmpty else { return [] }
        let content = try await provider.complete(
            system: Self.system, user: Self.render(events), schema: Self.schema)
        return Self.decode(content, events: events)
    }

    /// The shape the answer must fit. Kept here so the provider stays generic.
    static let schema = Data(
        #"{"type":"object","additionalProperties":false,"required":["decisions"],"properties":{"decisions":{"type":"array","maxItems":5,"items":{"type":"object","additionalProperties":false,"required":["title","act"],"properties":{"title":{"type":"string"},"rationale":{"type":"string"},"act":{"type":"string","enum":["PROPOSAL","OBJECTION","EXAMPLE","CONSTRAINT","DECISION","QUESTION"]},"utterance_index":{"type":"integer"}}}}},"#
            .utf8)

    static let system = """
        You are given the transcript of one working session between a person and a coding agent, and you report         only the decisions the person actually settled.

        Rules, in order of importance:
        - Propose only what the person decided. When you are unsure, propose nothing.
        - Never propose an idea the agent raised unless the person agreed to it. An agent's suggestion that was         never answered is not a decision.
        - Write the title in the person's own words where you can, and put their sentence in rationale when it         carries a constraint, an example or a rule.
        - Set utterance_index to the number of the person's turn the decision came from.
        - Propose at most five. Few and certain beats many and doubtful.
        """

    static func render(_ events: [DetectedEvent]) -> String {
        events.enumerated().map { index, event in
            switch event.kind {
            case .userTurn:
                return "[\(index)] person: \(event.text ?? "")"
            case .agentTurn:
                return "[\(index)] agent: \(event.text ?? "")"
            case .toolUse:
                return "[\(index)] tool \(event.tool ?? "?") \(event.target ?? "")"
            default:
                return "[\(index)] \(event.kind)"
            }
        }.joined(separator: "\n")
    }

    /// Anything that is not the promised shape proposes nothing: an unreadable answer is not a decision.
    static func decode(_ content: String, events: [DetectedEvent]) -> [DetectedDecision] {
        guard let data = content.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let decisions = object["decisions"] as? [[String: Any]]
        else { return [] }
        return decisions.compactMap { entry in
            guard let title = entry["title"] as? String else { return nil }
            var utterance: UUID?
            if let index = entry["utterance_index"] as? Int, events.indices.contains(index) {
                utterance = events[index].utterance
            }
            return DetectedDecision(
                title: title,
                rationale: entry["rationale"] as? String,
                act: act(from: entry["act"] as? String),
                utterance: utterance)
        }
    }

    /// An act we cannot read is a proposal, not a decision: the person may only have floated it, and calling
    /// an unknown act settled is the failure this whole design exists to prevent.
    static func act(from raw: String?) -> ActKind {
        switch raw?.uppercased() {
        case "DECISION": return .decision
        case "CONSTRAINT": return .constraint
        case "EXAMPLE": return .example
        case "OBJECTION": return .objection
        case "QUESTION": return .question
        default: return .proposal
        }
    }
}
