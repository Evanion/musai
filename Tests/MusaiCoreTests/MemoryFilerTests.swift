import Foundation
import Testing
@testable import MusaiCore

/// The producer, stubbed: it offers exactly what a test says, and keeps the batches it was asked about, so a
/// test can prove the drain handed it the events it consumed rather than assuming it.
actor OfferingFiler: MemoryFiler {
    private let offered: [DetectedMemory]
    private var batches: [[DetectedEvent]] = []

    init(offering offered: [DetectedMemory]) { self.offered = offered }

    func file(from events: [DetectedEvent]) async throws -> [DetectedMemory] {
        batches.append(events)
        return offered
    }

    /// The batches the drain asked about, in order.
    var asked: [[DetectedEvent]] { batches }
}

/// A producer that fails the way a model does — unreachable, or an answer nothing can be read out of. It counts
/// its calls, so a test can tell "the failure was survived" from "the filer was never asked".
actor FailingFiler: MemoryFiler {
    struct Failure: Error {}

    private var asked = 0
    var calls: Int { asked }

    func file(from events: [DetectedEvent]) async throws -> [DetectedMemory] {
        asked += 1
        throw Failure()
    }
}

/// A transport that answers with one fixed completion, so a test reaches the producer's parser without a model.
private struct AnsweringTransport: ModelTransport {
    let content: String

    func send(_ request: URLRequest, body: Data) async throws -> Data {
        (try? JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]]))
            ?? Data()
    }
}

/// Proposes one decision per turn in the batch, so a drain has a countable decision of its own to lose.
struct ProposingDetector: DecisionDetector {
    func propose(from events: [DetectedEvent]) async throws -> [DetectedDecision] {
        events.compactMap { event in
            event.utterance.map {
                DetectedDecision(title: "One Norvo file", rationale: nil, act: .decision, utterance: $0)
            }
        }
    }
}

/// The producer's rules, exercised through a real drain: what a filer offers is not what lands. A filer sees
/// events and never the store, so the anti-goals are the write boundary's — no filer's answer can mint a
/// decision or an authored memory, and no filer's answer is written whole. The two drain-mechanics tests live
/// in `CuratorControllerTests`; the stubs above are shared with them.
@Suite struct MemoryFilerTests {
    private let cwd = "/tmp/musai-producer"
    private let at = Date(timeIntervalSince1970: 1_700_000_000)

    /// A turn captured the way the hooks capture one, in a directory that resolves to a project of its own.
    private func turn(_ lib: MusaiLibrary, _ text: String = "we will use one Norvo file") async throws {
        _ = try await MusaiCapture(db: lib.db).captureUserTurn(
            text: text, at: at, origin: "claude", session: "s1", cwd: cwd, as: MusaiActors.curator)
    }

    /// The project the captured session bound to — where the drain's memories have to land.
    private func slug(_ lib: MusaiLibrary) async throws -> String {
        try #require(
            try await lib.db.query(SessionByMemoryIdQuery(.init(memorySessionId: "s1"))).session?.project?.slug)
    }

    private func drain(_ lib: MusaiLibrary, filer: any MemoryFiler) async throws {
        let controller = CuratorController(
            db: lib.db, detector: SilentDetector(), filer: filer, sleep: { _ in }, debounce: 1)
        _ = try await controller.drainNow()
    }

    private func filed(_ lib: MusaiLibrary) async throws -> [MemoriesForProjectQuery.Data.Memories] {
        try await lib.db.query(MemoriesForProjectQuery(.init(slug: try await slug(lib)))).memories
    }

    /// Every decision the store holds, whichever list a client would read it from.
    private func decisions(_ lib: MusaiLibrary) async throws -> Int {
        let slug = try await slug(lib)
        let proposed = try await lib.db.query(PendingDecisionsQuery(.init(first: 1_000))).decisions.count
        let migrated = try await lib.db.query(MigratedDecisionsQuery(.init(first: 1_000))).decisions.count
        let settled = try await lib.db.query(
            DecisionsForProjectQuery(.init(slug: slug, first: 1_000))).decisions.count
        return proposed + migrated + settled
    }

    /// The anti-goal, pinned at the write: a filer that names a decision gets an ambient memory, and the
    /// authored layer is untouched — no `Decision` exists anywhere in the store.
    @Test func theProducerNeverMintsADecision() async throws {
        let lib = try await MusaiLibrary.inMemory()
        try await turn(lib)
        try await drain(
            lib,
            filer: OfferingFiler(offering: [
                DetectedMemory(
                    kind: .decision, text: "we will use one Norvo file", narrative: nil, concepts: ["norvo"])
            ]))

        let memories = try await filed(lib)
        // Written, and written as ambient: what the session's events said happened is worth keeping, and the
        // kind it may not keep is the decision's.
        #expect(memories.count == 1)
        #expect(memories.first?.origin == .ambient)
        #expect(memories.first?.kind == .fact)
        #expect(try await decisions(lib) == 0)
    }

    /// Origin is the person's. Whatever a filer offers, every memory this producer files is ambient.
    @Test func theProducerNeverWritesAuthored() async throws {
        let lib = try await MusaiLibrary.inMemory()
        try await turn(lib)
        try await drain(
            lib,
            filer: OfferingFiler(offering: [
                DetectedMemory(kind: .fact, text: "one file holds the graph", narrative: nil, concepts: []),
                DetectedMemory(kind: .lesson, text: "two files cost a lock", narrative: nil, concepts: []),
            ]))

        let memories = try await filed(lib)
        #expect(memories.count == 2)
        // And every memory the store holds, bound or loose: this producer writes ambient, and only ambient —
        // `.authored` is the person's, and it never writes one.
        let loose = try await lib.db.query(MemoriesWithoutProjectQuery(.init(first: 1_000))).memories
        #expect((memories.map(\.origin) + loose.map(\.origin)).allSatisfy { $0 == .ambient })
    }

    /// Bounded per drain: however many a filer offers, only `maxPerDrain` land, so a long session backfills
    /// the graph rather than flooding it.
    @Test func theProducerIsBoundedPerDrain() async throws {
        let lib = try await MusaiLibrary.inMemory()
        try await turn(lib)
        try await drain(
            lib,
            filer: OfferingFiler(
                offering: (0..<50).map {
                    DetectedMemory(kind: .fact, text: "memory \($0)", narrative: nil, concepts: [])
                }))

        let memories = try await filed(lib)
        // Exactly the bound: one filer asked fifty, and fifty written would mean the bound is a promise rather
        // than a limit.
        #expect(memories.count == AmbientMemory.maxPerDrain)
    }

    /// The model half of the same rules, read the way the decision detector's answer is read: a kind the
    /// producer may not file is a fact, a lesson survives, a line with nothing in it is not a memory, and an
    /// answer that is not the promised shape files nothing at all.
    @Test func aModelAnswerThatNamesADecisionIsReadAsAFact() async throws {
        let events = [
            DetectedEvent(
                id: UUID(), kind: .userTurn, text: "we will use one Norvo file", tool: nil, target: nil,
                at: Date(timeIntervalSince1970: 1_700_000_000), utterance: UUID())
        ]
        let answer = #"""
            {"memories":[{"kind":"DECISION","text":"one file holds the graph"},
                         {"kind":"LESSON","text":"two files cost a lock"},
                         {"kind":"fact","text":"   "}]}
            """#
        let filer = ModelMemoryFiler(
            configuration: .default, transport: AnsweringTransport(content: answer))

        let memories = try await filer.file(from: events)
        #expect(memories.map(\.kind) == [.fact, .lesson])
        #expect(memories.map(\.text) == ["one file holds the graph", "two files cost a lock"])

        let unreadable = ModelMemoryFiler(
            configuration: .default, transport: AnsweringTransport(content: "I think maybe one memory?"))
        #expect(try await unreadable.file(from: events).isEmpty)
    }
}
