import Foundation

/// One thing a drain judged worth remembering: what a session's events said happened, in the words of a filer
/// that never sees the store. The producer's output, as `DetectedDecision` is the decision detector's.
public struct DetectedMemory: Sendable, Equatable {
    public let kind: MemoryKind
    public let text: String
    public let narrative: String?
    public let concepts: [String]

    public init(kind: MemoryKind, text: String, narrative: String?, concepts: [String]) {
        self.kind = kind
        self.text = text
        self.narrative = narrative
        self.concepts = concepts
    }
}

/// The curator's second output: ambient memory filed from the events a drain consumed. A filer sees events and
/// never the store, so it cannot write — and what it offers is an offer, not a row. `CuratorController` decides
/// what lands, which is what makes the producer's anti-goals structural rather than a filer's promise.
///
/// An event's `utterance` is not resolved for a filer: a memory belongs to the session its events came from,
/// not to one thing the person said.
public protocol MemoryFiler: Sendable {
    /// What this session's events are worth remembering. Few and confident, or nothing — an empty answer is
    /// the ordinary one.
    func file(from events: [DetectedEvent]) async throws -> [DetectedMemory]
}

/// What the producer may put in the graph, named once so the prompt a model is asked with, the schema that
/// shapes its answer and the boundary that writes it cannot drift apart.
public enum AmbientMemory {
    /// The most one filer call may add. A long session backfills the graph; it does not flood it, and Lite's
    /// single writer is shared with capture.
    public static let maxPerDrain = 3

    /// The longest a memory's text may be, in characters: an ambient memory is read at a glance.
    public static let maxTextCharacters = 600

    /// The kind an offered memory is filed under. The producer writes what happened and what was learned from
    /// it — a fact, or a lesson. Anything else a filer names is filed as a fact: a decision is authored, and
    /// the ambient layer may not mint one.
    public static func filedKind(_ offered: MemoryKind) -> MemoryKind {
        offered == .lesson ? .lesson : .fact
    }
}
