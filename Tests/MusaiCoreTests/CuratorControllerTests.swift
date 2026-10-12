import Foundation
import Testing
@testable import MusaiCore

/// A hand-driven stand-in for wall-clock time and for the detector. The controller's injected `sleep` calls
/// `nap`; the detector calls `propose`. Both block until the test releases them, so a debounce window and a
/// drain are driven step by step rather than by guessing at durations. `openProposals` lets a stage the test
/// has already driven run to completion without further intervention.
private actor Gate {
    private var naps = 0
    private var proposals = 0
    private var napWaiters: [CheckedContinuation<Void, Never>] = []
    private var proposalWaiters: [CheckedContinuation<Void, Never>] = []
    private var napObservers: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var proposalObservers: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var proposalsOpen = false

    /// The injected `sleep`: wait until the test lets this debounce window pass.
    func nap() async {
        naps += 1
        var remaining: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for observer in napObservers {
            if naps >= observer.target { observer.continuation.resume() } else { remaining.append(observer) }
        }
        napObservers = remaining
        await withCheckedContinuation { napWaiters.append($0) }
    }

    /// The detector: wait until the test lets this drain see the events it read.
    func propose() async {
        proposals += 1
        var remaining: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for observer in proposalObservers {
            if proposals >= observer.target {
                observer.continuation.resume()
            } else {
                remaining.append(observer)
            }
        }
        proposalObservers = remaining
        if proposalsOpen { return }
        await withCheckedContinuation { proposalWaiters.append($0) }
    }

    func waitForNap(_ count: Int) async {
        if naps >= count { return }
        await withCheckedContinuation { napObservers.append((count, $0)) }
    }

    func waitForProposal(_ count: Int) async {
        if proposals >= count { return }
        await withCheckedContinuation { proposalObservers.append((count, $0)) }
    }

    func releaseNaps() {
        let waiters = napWaiters
        napWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Let this and every later detector call through, so a stage the test has already driven can finish.
    func openProposals() {
        proposalsOpen = true
        let waiters = proposalWaiters
        proposalWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func napCount() -> Int { naps }
    func proposalCount() -> Int { proposals }
}

/// Proposes one decision per event that has a user turn, so proposals are countable.
private struct GatedDetector: DecisionDetector {
    let gate: Gate
    func propose(from events: [DetectedEvent]) async throws -> [DetectedDecision] {
        await gate.propose()
        return events.compactMap { event in
            event.utterance.map {
                DetectedDecision(title: "Decision", rationale: nil, act: .decision, utterance: $0)
            }
        }
    }
}

@Suite struct CuratorControllerTests {
    private let cwd = "/tmp/musai-controller"

    private func makeController(_ lib: MusaiLibrary, _ gate: Gate) -> CuratorController {
        CuratorController(
            db: lib.db, detector: GatedDetector(gate: gate),
            sleep: { _ in await gate.nap() }, debounce: 1)
    }

    private func turn(_ lib: MusaiLibrary, _ text: String, at offset: Double) async throws {
        _ = try await MusaiCapture(db: lib.db).captureUserTurn(
            text: text, at: Date(timeIntervalSince1970: 1_700_000_000 + offset),
            origin: "claude", session: "s1", cwd: cwd, as: MusaiActors.curator)
    }

    /// Polls rather than sleeping a fixed time, so a concurrent result is picked up as soon as it exists.
    private func eventually(_ condition: @Sendable () async throws -> Bool) async throws {
        for _ in 0..<300 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition did not hold in time")
    }

    @Test func aBurstOfCapturesCollapsesIntoOneDrain() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let gate = Gate()
        let controller = makeController(lib, gate)

        // A burst inside one debounce window: five captures, one scheduled drain.
        for index in 0..<5 {
            try await turn(lib, "turn \(index)", at: Double(index))
            await controller.noteCapture()
        }
        await gate.waitForNap(1)
        #expect(await gate.napCount() == 1)

        await gate.releaseNaps()
        await gate.waitForProposal(1)
        await gate.openProposals()

        try await eventually { try await lib.db.query(UndrainedEventsQuery()).events.isEmpty }
        #expect(await gate.napCount() == 1)
        #expect(await gate.proposalCount() == 1)
        let pending = try await lib.db.query(PendingDecisionsQuery()).decisions
        #expect(pending.count == 5)
    }

    @Test func twoConcurrentDrainsRunTheDrainOnce() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let gate = Gate()
        let controller = makeController(lib, gate)
        try await turn(lib, "one", at: 0)
        try await turn(lib, "two", at: 1)

        let first = Task { try await controller.drainNow() }
        await gate.waitForProposal(1)  // the first drain is inside the detector, its batch read

        let second = Task { try await controller.drainNow() }  // must coalesce with the first
        // Let the second call reach the actor and join the running drain before the first is released.
        try await Task.sleep(for: .milliseconds(100))

        await gate.openProposals()
        _ = try await first.value
        _ = try await second.value

        // The drain ran once: no second detector call over the same events.
        #expect(await gate.proposalCount() == 1)
        let undrained = try await lib.db.query(UndrainedEventsQuery()).events
        #expect(undrained.isEmpty)
    }

    @Test func aCaptureDuringADrainIsNotStranded() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let gate = Gate()
        let controller = makeController(lib, gate)

        try await turn(lib, "first", at: 0)
        await controller.noteCapture()
        await gate.waitForNap(1)
        await gate.releaseNaps()
        await gate.waitForProposal(1)  // the drain is inside the slow detector; its batch is fixed

        // A capture lands while the drain runs, and its own debounce fires and joins the running drain.
        try await turn(lib, "second", at: 1)
        await controller.noteCapture()
        await gate.waitForNap(2)
        await gate.releaseNaps()
        // Let the second debounce reach the actor and coalesce with the running drain.
        try await Task.sleep(for: .milliseconds(100))

        // The coalesced caller must notice the event that arrived after the first batch and drain it.
        await gate.openProposals()
        try await eventually { try await lib.db.query(UndrainedEventsQuery()).events.isEmpty }

        let undrained = try await lib.db.query(UndrainedEventsQuery()).events
        #expect(undrained.isEmpty)
        #expect(await gate.proposalCount() == 2)
    }
}
