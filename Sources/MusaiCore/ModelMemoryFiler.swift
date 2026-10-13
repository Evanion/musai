import Foundation

/// The producer behind whatever provider is configured — the metered observer, replaced locally. The prompt and
/// the parsing live here; which model answers, and where it runs, do not.
public struct ModelMemoryFiler: MemoryFiler {
    public let provider: any ModelProvider

    /// The transport is injectable exactly as the provider's own initialiser injects it, so a test can answer
    /// with a fixed completion rather than a model.
    public init(configuration: ModelConfiguration, transport: any ModelTransport = URLSessionTransport()) {
        self.provider = OpenAICompatibleProvider(configuration: configuration, transport: transport)
    }

    public func file(from events: [DetectedEvent]) async throws -> [DetectedMemory] {
        guard !events.isEmpty else { return [] }
        // The transcript is rendered exactly as the decision detector renders it: one queue has one shape, so
        // the two prompts cannot drift apart.
        let content = try await provider.complete(
            system: Self.system, user: ModelDecisionDetector.render(events), schema: Self.schema)
        return Self.decode(content)
    }

    /// The shape the answer must fit. Kept here so the provider stays generic, and enumerated so a model is
    /// refused a kind the producer may not file rather than merely coerced out of it.
    static let schema = Data(
        #"{"type":"object","additionalProperties":false,"required":["memories"],"properties":{"memories":{"type":"array","maxItems":\#(AmbientMemory.maxPerDrain),"items":{"type":"object","additionalProperties":false,"required":["kind","text"],"properties":{"kind":{"type":"string","enum":["FACT","LESSON"]},"text":{"type":"string"},"narrative":{"type":"string"},"concepts":{"type":"array","items":{"type":"string"}}}}}}}"#
            .utf8)

    static let system = """
        You are given the transcript of one working session between a person and a coding agent, and you report
        only what that session is worth remembering by.

        Rules, in order of importance:
        - Report only what will still be true, and still worth knowing, in a later session. When you are
          unsure, report nothing.
        - Few and confident beats many and doubtful: report at most \(AmbientMemory.maxPerDrain).
        - Never report a decision. A decision is the person's to make, and it is recorded when they settle it.
        - kind is FACT for what happened or what is so, and LESSON for what was learned the hard way. Nothing
          else is a kind.
        - text is one line, at most \(AmbientMemory.maxTextCharacters) characters, in plain words.
        - narrative carries the detail when the reason or the rule is worth keeping.
        - concepts are a few short words naming what the memory is about.
        """

    /// Anything that is not the promised shape files nothing: an unreadable answer is not a memory.
    static func decode(_ content: String) -> [DetectedMemory] {
        guard let data = content.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let memories = object["memories"] as? [[String: Any]]
        else { return [] }
        return memories.compactMap { entry in
            // A memory with nothing to say is not one, whatever the model thought.
            guard let text = cleaned(entry["text"] as? String) else { return nil }
            let named = MemoryKind(rawValue: (entry["kind"] as? String ?? "").uppercased())
            return DetectedMemory(
                kind: AmbientMemory.filedKind(named),
                text: String(text.prefix(AmbientMemory.maxTextCharacters)),
                narrative: cleaned(entry["narrative"] as? String).map {
                    String($0.prefix(AmbientMemory.maxTextCharacters))
                },
                concepts: entry["concepts"] as? [String] ?? [])
        }
    }

    /// A trimmed string, or `nil` when there is nothing in it.
    static func cleaned(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}
