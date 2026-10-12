import Foundation
import Network
import Testing
@testable import MusaiCore

/// Proposes nothing: the drain is not this test's subject, and the curator must stay out of the way.
private struct ListenerQuietDetector: DecisionDetector {
    func propose(from events: [DetectedEvent]) async throws -> [DetectedDecision] { [] }
}

/// The listener is the one piece that genuinely needs a socket, so these tests send real requests over
/// loopback and read what comes back — the wire, not the router.
@Suite struct ListenerTests {
    private static let token = "a-token-the-listener-test-chose"

    private struct Made {
        let library: MusaiLibrary
        let endpoint: MusaiEndpoint
        let store: URL
    }

    /// The endpoint behind the listener is a real one: a file-backed store (serving one is the endpoint's
    /// whole job), a state that knows its path, and a curator parked so no drain runs mid-test.
    private func made() async throws -> Made {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-listener-\(UUID().uuidString)")
        let store = directory.appending(path: "Musai.norvo")
        let library = try await MusaiLibrary.open(at: store)
        let state = EndpointState(storePath: store.path)
        let controller = CuratorController(
            db: library.db, detector: ListenerQuietDetector(),
            sleep: { _ in try? await Task.sleep(for: .seconds(3_600)) }, debounce: 1)
        let endpoint = MusaiEndpoint(
            db: library.db, library: library, state: state, curator: controller, token: Self.token)
        return Made(library: library, endpoint: endpoint, store: store)
    }

    /// One real request through the socket, which is the whole point of a listener test.
    private func get(
        _ port: UInt16, _ path: String, token: String?
    ) async throws -> (status: Int, body: Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (body, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, body)
    }

    @Test func theListenerServesTheEndpoint() async throws {
        let made = try await made()
        defer {
            made.library.close()
            try? FileManager.default.removeItem(at: made.store.deletingLastPathComponent())
        }
        let listener = EndpointListener(endpoint: made.endpoint)
        // Port 0: the system chooses, and `start` is where the chosen port is learned.
        let port = try listener.start()
        defer { listener.stop() }
        #expect(port != 0)

        let response = try await get(port, "/health", token: Self.token)
        #expect(response.status == 200)
        let health = try EndpointWire.decoder().decode(EndpointHealth.self, from: response.body)
        #expect(health.storePath == made.store.path)
        #expect(health.protocolVersion == EndpointWire.protocolVersion)
    }

    @Test func aBadTokenIsRefused() async throws {
        let made = try await made()
        defer {
            made.library.close()
            try? FileManager.default.removeItem(at: made.store.deletingLastPathComponent())
        }
        let listener = EndpointListener(endpoint: made.endpoint)
        let port = try listener.start()
        defer { listener.stop() }

        // The token is checked inside the router, on every route including this one; the listener only has to
        // carry the bearer it was given.
        let response = try await get(port, "/health", token: "an-impostor")
        #expect(response.status == 401)
    }

    @Test func theRecordRoundTripsAndIsPrivate() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-record-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "helper.json")
        let record = HelperRecord(
            port: 51_234, token: "a-token", pid: 4_242,
            protocolVersion: EndpointWire.protocolVersion, storePath: "/tmp/Musai.norvo")

        try record.write(to: url)
        let read = try HelperRecord.read(from: url)
        #expect(read == record)

        // The token inside is the whole of the backend's authorisation, so the file is the person's alone.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func aDeadPidsRecordIsNotAlive() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-dead-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "helper.json")
        // A pid no process can hold, so the record is a corpse whatever this machine is running.
        let record = HelperRecord(
            port: 1, token: "a-token", pid: Int32.max,
            protocolVersion: EndpointWire.protocolVersion, storePath: "/tmp/Musai.norvo")
        try record.write(to: url)

        let read = try HelperRecord.read(from: url)
        #expect(read.isAlive == false)
    }

    @Test func theTokenIsCreatedOnceAndIsPrivate() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-token-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "token")

        let first = try MusaiToken.loadOrCreate(at: url)
        // 32 random bytes as hex: 64 characters, and the value on disk is the value handed back.
        #expect(first.count == 64)
        let allHex = first.allSatisfy(\.isHexDigit)
        #expect(allHex)
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == first)

        // The token file is 0600: it is the whole of the backend's authorisation.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)

        // A restart must not hand every client a new secret.
        let second = try MusaiToken.loadOrCreate(at: url)
        #expect(second == first)
    }

    @Test func aSecondListenerOnTheSamePortFails() async throws {
        let made = try await made()
        defer {
            made.library.close()
            try? FileManager.default.removeItem(at: made.store.deletingLastPathComponent())
        }
        let first = EndpointListener(endpoint: made.endpoint)
        let port = try first.start()
        defer { first.stop() }

        // One ephemeral port, one owner: a second listener on it must be told no, not quietly steal a share.
        let second = EndpointListener(endpoint: made.endpoint, port: port)
        #expect(throws: (any Error).self) { try second.start() }
        second.stop()
    }

    /// The bound this task exists to hold: a body past the limit is refused from its headers, never read —
    /// a client that declares an endless body must get an answer, not a hang. (Beyond the brief's five, and
    /// deliberately so: the bound is otherwise unproven.)
    @Test func anOversizedBodyIsRefusedRatherThanRead() async throws {
        let made = try await made()
        defer {
            made.library.close()
            try? FileManager.default.removeItem(at: made.store.deletingLastPathComponent())
        }
        let listener = EndpointListener(endpoint: made.endpoint)
        let port = try listener.start()
        defer { listener.stop() }

        // A `Content-Length` past the bound, with no body at all: only an answer taken from the headers —
        // rather than a read of a body that is not coming — can come back.
        let request = "POST /capture HTTP/1.1\r\nHost: 127.0.0.1\r\n"
            + "Authorization: Bearer \(Self.token)\r\n"
            + "Content-Length: \(EndpointListener.maxBodyBytes + 1)\r\n\r\n"
        let status = try await Self.rawStatus(port: port, request: request)
        #expect(status == 413)
    }

    /// A raw socket, because `URLSession` will not declare a `Content-Length` larger than the body it holds.
    private static func rawStatus(port: UInt16, request: String) async throws -> Int {
        let connection = NWConnection(
            host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "musai.listener.test.raw")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    continuation.resume()
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: data ?? Data())
                }
            }
        }
        connection.cancel()

        let line = String(decoding: data, as: UTF8.self).split(separator: "\r\n").first ?? ""
        return Int(line.split(separator: " ").dropFirst().first ?? "") ?? -1
    }
}
