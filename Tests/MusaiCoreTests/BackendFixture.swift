import Darwin
import Foundation
@testable import MusaiCore

/// Proposes nothing: the drain is not these tests' subject, and the curator must stay out of the way.
struct SilentDetector: DecisionDetector {
    func propose(from events: [DetectedEvent]) async throws -> [DetectedDecision] { [] }
}

/// The curator's debounce window, driven by hand: the first window the curator opens parks until the test
/// lets it pass, so a test can prove the queue is holding something before anything drains. `opened` is read
/// by the test rather than waited on, so a drain that never comes fails a test in seconds instead of parking
/// it forever.
actor WindowGate {
    private var count = 0
    private var open = false
    private var parked: [CheckedContinuation<Void, Never>] = []

    /// How many debounce windows the curator has opened.
    var opened: Int { count }

    /// The injected `sleep`: park the first window, and let every later one pass at once.
    func nap() async {
        count += 1
        if open { return }
        await withCheckedContinuation { parked.append($0) }
    }

    /// Lets the parked window pass; a later one returns at once rather than parking a drain nobody resumes.
    func openWindows() {
        open = true
        let waiting = parked
        parked = []
        for waiter in waiting { waiter.resume() }
    }
}

/// A real endpoint behind a real loopback listener — the wire, not the router — for tests that call a client.
/// Everything one of these starts, its `close()` stops.
struct BackendFixture {
    static let token = "a-token-the-backend-fixture-chose"

    let library: MusaiLibrary
    let listener: EndpointListener
    let controller: CuratorController
    let store: URL
    let port: UInt16

    /// A file-backed store (serving one is the endpoint's whole job), a state that knows its path, and a
    /// curator whose debounce is parked so no drain runs mid-test. `protocolVersion` is what `/health`
    /// reports, so a test can stand a helper the client must refuse; `sleep` is how the window passes, for
    /// the tests that want the endpoint to drain on its own debounce rather than a parked one.
    static func make(
        detector: any DecisionDetector = SilentDetector(),
        protocolVersion: String = EndpointWire.protocolVersion,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { _ in
            try? await Task.sleep(for: .seconds(3_600))
        }
    ) async throws -> BackendFixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-client-\(UUID().uuidString)")
        let store = directory.appending(path: "Musai.norvo")
        let library = try await MusaiLibrary.open(at: store)
        let state = EndpointState(storePath: store.path, protocolVersion: protocolVersion)
        let controller = CuratorController(
            db: library.db, detector: detector, sleep: sleep, debounce: 1)
        let endpoint = MusaiEndpoint(
            store: .open(db: library.db, library: library), state: state, curator: controller, token: token)
        let listener = EndpointListener(endpoint: endpoint)
        let port = try listener.start()
        return BackendFixture(
            library: library, listener: listener, controller: controller, store: store, port: port)
    }

    /// The record a client discovers: the live port, this process's pid, and the version the helper advertises.
    func record(protocolVersion: String = EndpointWire.protocolVersion) -> HelperRecord {
        HelperRecord(
            port: port, token: Self.token, pid: getpid(), protocolVersion: protocolVersion,
            storePath: store.path)
    }

    func close() {
        listener.stop()
        library.close()
        try? FileManager.default.removeItem(at: store.deletingLastPathComponent())
    }
}
