import Darwin
import Foundation
@testable import MusaiCore

/// Proposes nothing: the drain is not these tests' subject, and the curator must stay out of the way.
struct SilentDetector: DecisionDetector {
    func propose(from events: [DetectedEvent]) async throws -> [DetectedDecision] { [] }
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
    /// reports, so a test can stand a helper the client must refuse.
    static func make(
        detector: any DecisionDetector = SilentDetector(),
        protocolVersion: String = EndpointWire.protocolVersion
    ) async throws -> BackendFixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-client-\(UUID().uuidString)")
        let store = directory.appending(path: "Musai.norvo")
        let library = try await MusaiLibrary.open(at: store)
        let state = EndpointState(storePath: store.path, protocolVersion: protocolVersion)
        let controller = CuratorController(
            db: library.db, detector: detector,
            sleep: { _ in try? await Task.sleep(for: .seconds(3_600)) }, debounce: 1)
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
