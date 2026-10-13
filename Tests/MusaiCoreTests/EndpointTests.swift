import Foundation
import Testing
@testable import MusaiCore

/// Proposes nothing: the drain is Task 4's subject, and these tests must not depend on it.
private struct QuietDetector: DecisionDetector {
    func propose(from events: [DetectedEvent]) async throws -> [DetectedDecision] { [] }
}

/// A model call a test holds open: `enter` blocks until `release`, so a capture can be shown landing while
/// the curator is inside the detector.
private actor ModelGate {
    private var entered = 0
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        entered += 1
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters = []
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitForEntry() async {
        if entered > 0 { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        for waiter in releaseWaiters { waiter.resume() }
        releaseWaiters = []
    }
}

private struct HoldingDetector: DecisionDetector {
    let gate: ModelGate
    func propose(from events: [DetectedEvent]) async throws -> [DetectedDecision] {
        await gate.enter()
        return []
    }
}

/// A debounce window a test passes by hand.
private actor NapGate {
    private var naps = 0
    private var napWaiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func nap() async {
        naps += 1
        var remaining: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []
        for observer in observers {
            if naps >= observer.target { observer.continuation.resume() } else { remaining.append(observer) }
        }
        observers = remaining
        await withCheckedContinuation { napWaiters.append($0) }
    }

    func waitForNap(_ count: Int) async {
        if naps >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    func releaseNaps() {
        let waiters = napWaiters
        napWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    func napCount() -> Int { naps }
}

@Suite struct EndpointTests {
    private static let token = "a-token-a-test-chose"

    /// Every test's endpoint: a real file-backed store (serving one is the endpoint's whole job), a state
    /// that knows its path, and a curator whose debounce is parked — no drain may run mid-test. The drain
    /// is Task 4's subject; here it only has to stay out of the way.
    private func made(
        detector: any DecisionDetector = QuietDetector(),
        filer: (any MemoryFiler)? = nil,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { _ in
            try? await Task.sleep(for: .seconds(3_600))
        }
    ) async throws -> (library: MusaiLibrary, endpoint: MusaiEndpoint, store: URL, controller: CuratorController) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-endpoint-\(UUID().uuidString)")
        let store = directory.appending(path: "Musai.norvo")
        let library = try await MusaiLibrary.open(at: store)
        let state = EndpointState(storePath: store.path)
        let controller = CuratorController(
            db: library.db, detector: detector, filer: filer, sleep: sleep, debounce: 1)
        let endpoint = MusaiEndpoint(
            store: .open(db: library.db, library: library), state: state, curator: controller,
            token: Self.token)
        return (library, endpoint, store, controller)
    }

    private func request(
        _ method: String, _ path: String, query: [String: String] = [:], body: Data = Data(),
        token: String = EndpointTests.token
    ) -> EndpointRequest {
        EndpointRequest(method: method, path: path, query: query, body: body, token: token)
    }

    private func userTurn(_ text: String) throws -> Data {
        try EndpointWire.encoder().encode(
            NormalizedEvent(
                kind: .userTurn, session: "s1", cwd: "/tmp/musai-endpoint",
                at: Date(timeIntervalSince1970: 1_700_000_000), text: text))
    }

    @Test func healthReportsTheStoreAndTheBacklog() async throws {
        let made = try await made()
        defer {
            made.library.close()
            try? FileManager.default.removeItem(at: made.store.deletingLastPathComponent())
        }
        let capture = MusaiCapture(db: made.library.db)
        for index in 0..<3 {
            _ = try await capture.captureUserTurn(
                text: "turn \(index)", at: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                origin: "claude", session: "s1", cwd: "/tmp/musai-endpoint", as: MusaiActors.curator)
        }

        let response = await made.endpoint.respond(to: request("GET", "/health"))
        #expect(response.status == 200)
        let health = try EndpointWire.decoder().decode(EndpointHealth.self, from: response.body)
        #expect(health.protocolVersion == "1.0")
        #expect(health.storePath == made.store.path)
        let undrained = try await made.library.db.query(UndrainedEventsQuery()).events
        #expect(health.backlogDepth == undrained.count)
        #expect(health.backlogDepth == 3)
        let status = await made.endpoint.state.statusText()
        #expect(status == "backlog(3)")
    }

    /// The producer's failure mode, on the wire: a model that is not answering costs each drain its ambient
    /// memory while the store stays healthy, so `/health` staying green is not enough — the count has to
    /// reach the person, and this pins it reaching the wire. The drain really ran and really lost its batch;
    /// a controller that never called the filer would pass vacuously.
    @Test func healthCarriesTheProducersFailures() async throws {
        let made = try await made(filer: FailingFiler())
        defer {
            made.library.close()
            try? FileManager.default.removeItem(at: made.store.deletingLastPathComponent())
        }
        _ = try await MusaiCapture(db: made.library.db).captureUserTurn(
            text: "we will use one Norvo file", at: Date(timeIntervalSince1970: 1_700_000_000),
            origin: "claude", session: "s1", cwd: "/tmp/musai-endpoint", as: MusaiActors.curator)

        _ = try await made.controller.drainNow()
        #expect(await made.controller.filerFailures == 1)

        let response = await made.endpoint.respond(to: request("GET", "/health"))
        let health = try EndpointWire.decoder().decode(EndpointHealth.self, from: response.body)
        #expect(health.filerFailures == 1)
        // And the healthy store it happened to is not a lie about the producer: both are reported.
        #expect(health.storeState == .open)
    }

    @Test func captureStoresAnEvent() async throws {
        let made = try await made()
        defer {
            made.library.close()
            try? FileManager.default.removeItem(at: made.store.deletingLastPathComponent())
        }

        let response = await made.endpoint.respond(to: request("POST", "/capture", body: try userTurn("we will use one Norvo file")))
        #expect(response.status == 200)
        #expect(String(data: response.body, encoding: .utf8) == #"{"stored":"created"}"#)
        let reply = try EndpointWire.decoder().decode(CaptureReply.self, from: response.body)
        #expect(reply.stored == .created)

        let rows = try await made.library.db.query(UtterancesForSessionQuery(.init(session: "s1"))).utterances
        #expect(rows.first?.text == "we will use one Norvo file")
    }

    @Test func captureIsIdempotent() async throws {
        let made = try await made()
        defer {
            made.library.close()
            try? FileManager.default.removeItem(at: made.store.deletingLastPathComponent())
        }

        let first = await made.endpoint.respond(to: request("POST", "/capture", body: try userTurn("same words")))
        let second = await made.endpoint.respond(to: request("POST", "/capture", body: try userTurn("same words")))
        let firstReply = try EndpointWire.decoder().decode(CaptureReply.self, from: first.body)
        let secondReply = try EndpointWire.decoder().decode(CaptureReply.self, from: second.body)
        #expect(firstReply.stored == .created)
        #expect(secondReply.stored == .duplicate)

        let rows = try await made.library.db.query(UtterancesForSessionQuery(.init(session: "s1"))).utterances
        #expect(rows.count == 1)
    }

    @Test func captureRefusesABadToken() async throws {
        let made = try await made()
        defer {
            made.library.close()
            try? FileManager.default.removeItem(at: made.store.deletingLastPathComponent())
        }

        // Every route refuses a stranger, `/health` included: a caller without the token must not learn so
        // much as the store's path.
        let capture = await made.endpoint.respond(
            to: request("POST", "/capture", body: try userTurn("words a stranger sent"), token: "an-impostor"))
        let health = await made.endpoint.respond(to: request("GET", "/health", token: "an-impostor"))
        #expect(capture.status == 401)
        #expect(health.status == 401)

        let utterances = try await made.library.db.query(UtterancesForSessionQuery(.init(session: "s1"))).utterances
        let events = try await made.library.db.query(EventsForSessionQuery(.init(session: "s1"))).events
        #expect(utterances.isEmpty)
        #expect(events.isEmpty)
    }

    @Test func contextReturnsTheSlice() async throws {
        let full = try await made()
        defer {
            full.library.close()
            try? FileManager.default.removeItem(at: full.store.deletingLastPathComponent())
        }
        let cwd = "/tmp/musai-endpoint-context"
        let said = try await MusaiCapture(db: full.library.db).captureUserTurn(
            text: "we will use one Norvo file", at: Date(timeIntervalSince1970: 1_700_000_000),
            origin: "claude", session: "s1", cwd: cwd, as: MusaiActors.curator)
        let found = try await full.library.db.query(ProjectByRootQuery(.init(root: cwd))).projects
        let slug = try #require(found.first?.slug)
        let proposal = try await full.library.db.mutate(
            RecordProposalMutation(
                .init(title: "One Norvo file", rationale: nil, act: .decision, utterance: said, project: slug)),
            as: MusaiActors.curator)
        try await ReviewSession(db: full.library.db).apply(.settle, to: proposal.createDecision.id, as: MusaiActors.user)

        let response = await full.endpoint.respond(to: request("GET", "/context", query: ["cwd": cwd]))
        #expect(response.status == 200)
        let body = String(data: response.body, encoding: .utf8) ?? ""
        #expect(body.contains("One Norvo file"))

        // An empty store has nothing to say, and says it with an empty body, not an error.
        let empty = try await made()
        defer {
            empty.library.close()
            try? FileManager.default.removeItem(at: empty.store.deletingLastPathComponent())
        }
        let silence = await empty.endpoint.respond(
            to: request("GET", "/context", query: ["cwd": "/tmp/musai-endpoint-nowhere"]))
        #expect(silence.status == 200)
        #expect(silence.body.isEmpty)
    }

    @Test func proposalsListsAndSettles() async throws {
        let made = try await made()
        defer {
            made.library.close()
            try? FileManager.default.removeItem(at: made.store.deletingLastPathComponent())
        }
        let cwd = "/tmp/musai-endpoint-proposals"
        let said = try await MusaiCapture(db: made.library.db).captureUserTurn(
            text: "we will use one Norvo file", at: Date(timeIntervalSince1970: 1_700_000_000),
            origin: "claude", session: "s1", cwd: cwd, as: MusaiActors.curator)
        let found = try await made.library.db.query(ProjectByRootQuery(.init(root: cwd))).projects
        let slug = try #require(found.first?.slug)
        let settled = try await made.library.db.mutate(
            RecordProposalMutation(
                .init(title: "Keep one file", rationale: nil, act: .decision, utterance: said, project: slug)),
            as: MusaiActors.curator).createDecision.id
        let pending = try await made.library.db.mutate(
            RecordProposalMutation(
                .init(title: "No vault", rationale: nil, act: .decision, utterance: said, project: slug)),
            as: MusaiActors.curator).createDecision.id
        try await ReviewSession(db: made.library.db).apply(.settle, to: settled, as: MusaiActors.user)

        // The gap is what the person came to see, and the listing leads with it.
        let list = await made.endpoint.respond(to: request("GET", "/proposals"))
        #expect(list.status == 200)
        let listed = try EndpointWire.decoder().decode(ProposalsReply.self, from: list.body)
        #expect(listed.gap.map(\.title) == ["Keep one file"])
        #expect(listed.pending.map(\.title) == ["No vault"])

        let response = await made.endpoint.respond(to: request("POST", "/proposals/\(pending)/settle"))
        #expect(response.status == 200)
        let reply = try EndpointWire.decoder().decode(DecisionReply.self, from: response.body)
        #expect(reply.state == "SETTLED")

        let after = await made.endpoint.respond(to: request("GET", "/proposals"))
        let moved = try EndpointWire.decoder().decode(ProposalsReply.self, from: after.body)
        #expect(moved.gap.map(\.title) == ["Keep one file", "No vault"])
        #expect(moved.pending.isEmpty)
    }

    @Test func theRouterAnswersAnUnknownPathWith404() async throws {
        let made = try await made()
        defer {
            made.library.close()
            try? FileManager.default.removeItem(at: made.store.deletingLastPathComponent())
        }

        let unknown = await made.endpoint.respond(to: request("GET", "/nowhere"))
        #expect(unknown.status == 404)

        // A route we serve, asked for under a method it does not speak.
        let wrongMethod = await made.endpoint.respond(to: request("GET", "/capture"))
        #expect(wrongMethod.status == 405)
    }

    /// The drain is off the request path: a capture that arrives while a model call is in flight is stored
    /// and answered at once, and the backlog grows rather than the request waiting.
    @Test func aCaptureDuringAModelCallReturnsAtOnce() async throws {
        let gate = ModelGate()
        let made = try await made(detector: HoldingDetector(gate: gate))
        defer {
            made.library.close()
            try? FileManager.default.removeItem(at: made.store.deletingLastPathComponent())
        }

        _ = try await MusaiCapture(db: made.library.db).captureUserTurn(
            text: "first", at: Date(timeIntervalSince1970: 1_700_000_000), origin: "claude", session: "s1",
            cwd: "/tmp/musai-endpoint", as: MusaiActors.curator)

        let drain = Task { try await made.controller.drainNow() }
        await gate.waitForEntry()  // the drain is inside the model, its batch already read

        let started = Date()
        let response = await made.endpoint.respond(to: request("POST", "/capture", body: try userTurn("second")))
        let elapsed = Date().timeIntervalSince(started)
        let reply = try EndpointWire.decoder().decode(CaptureReply.self, from: response.body)
        #expect(response.status == 200)
        #expect(reply.stored == .created)
        #expect(elapsed < 1.0)  // answered while the model call was still held

        // The backlog grew: the new turn is waiting for the next pass, not lost behind the model call.
        let undrained = try await made.library.db.query(UndrainedEventsQuery()).events
        #expect(undrained.contains { $0.text == "second" })

        await gate.release()
        _ = try await drain.value
        #expect(try await made.library.db.query(UndrainedEventsQuery()).events.isEmpty)
    }

    /// A burst of captures inside one debounce window collapses into a single drain.
    @Test func theDebounceCollapsesABurst() async throws {
        let gate = NapGate()
        let made = try await made(sleep: { _ in await gate.nap() })
        defer {
            made.library.close()
            try? FileManager.default.removeItem(at: made.store.deletingLastPathComponent())
        }

        for index in 0..<5 {
            _ = try await MusaiCapture(db: made.library.db).captureUserTurn(
                text: "turn \(index)", at: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                origin: "claude", session: "s1", cwd: "/tmp/musai-endpoint", as: MusaiActors.curator)
            await made.controller.noteCapture()
        }
        await gate.waitForNap(1)
        #expect(await gate.napCount() == 1)  // five captures, one scheduled window

        await gate.releaseNaps()
        try await eventually { try await made.library.db.query(UndrainedEventsQuery()).events.isEmpty }
        #expect(await made.controller.drainCount == 1)
    }

    /// Polls rather than sleeping a fixed time, so a concurrent result is picked up as soon as it exists.
    private func eventually(_ condition: @Sendable () async throws -> Bool) async throws {
        for _ in 0..<300 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("condition did not hold in time")
    }
}