import Foundation
import NorvoLite
import Testing
@testable import MusaiCore

/// Counts how many times the store was opened, so "reopened" is proven rather than assumed.
private actor OpenCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

/// Reports the engine's fatal state on the first check and is healthy after: exactly the state a reopened
/// store leaves behind, without needing a real corrupt file.
private actor FatalOnceProbe {
    private var reported = false
    func check(_ db: Database) async throws {
        if !reported {
            reported = true
            throw NorvoError(code: .fatal, message: "the store reported a fatal state")
        }
    }
}

/// Collects the status strings an `EndpointState` publishes. Lock-protected, because an observer runs on
/// whichever executor mutated the state.
private final class StatusRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func record(_ text: String) {
        lock.lock()
        values.append(text)
        lock.unlock()
    }

    var seen: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@Suite struct AgentTests {
    /// A store in its own temporary directory, so every test's record, token and lock are its own.
    private static func temporaryStore() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-agent-\(UUID().uuidString)")
            .appending(path: "Musai.norvo")
    }

    /// The log beside that store, for the same reason: an agent test must not write into the developer's real
    /// `~/Library/Logs/Musai`.
    private static func log(for store: URL) -> URL {
        store.deletingLastPathComponent().appending(path: "helper.log")
    }

    @Test func itOpensTheStoreOnceAndServes() async throws {
        let store = Self.temporaryStore()
        let agent = try MusaiAgent(libraryURL: store, detector: SilentDetector(), logURL: Self.log(for: store))
        defer {
            agent.stop()
            try? FileManager.default.removeItem(at: store.deletingLastPathComponent())
        }

        let port = try await agent.start()
        #expect(port != 0)

        // The record is how a client finds the process, and it sits beside the store it names.
        #expect(FileManager.default.fileExists(atPath: agent.recordURL.path))
        let record = try HelperRecord.read(from: agent.recordURL)
        #expect(record.storePath == store.path)
        #expect(record.pid == getpid())

        // The token is minted once and published in the record, so a client can present it.
        let token = try #require(MusaiToken.read(at: agent.tokenURL))
        #expect(token == record.token)

        let client = MusaiClient(record: record, token: token)
        let health = try #require(await client.health())
        #expect(health.storePath == store.path)
        // The agent builds its state with the default, so it can only report the protocol it really serves.
        #expect(health.protocolVersion == EndpointWire.protocolVersion)
        #expect(health.storeState == .open)
    }

    @Test func aSecondAgentRefusesToOpenTheStoreOnTheSameFile() async throws {
        let store = Self.temporaryStore()
        let first = try MusaiAgent(libraryURL: store, detector: SilentDetector(), logURL: Self.log(for: store))
        defer {
            first.stop()
            try? FileManager.default.removeItem(at: store.deletingLastPathComponent())
        }
        _ = try await first.start()

        // The backoff is real in production; the wait is not this test's subject.
        let second = try MusaiAgent(
            libraryURL: store, detector: SilentDetector(), logURL: Self.log(for: store), sleep: { _ in })
        var thrown: (any Error)?
        do {
            _ = try await second.start()
        } catch {
            thrown = error
        }
        second.stop()

        // It must not open the store twice: it says so, naming the file that is held.
        let error = try #require(thrown)
        #expect(String(describing: error).contains(store.path))

        // And the holder is untouched: it still answers.
        let record = try HelperRecord.read(from: first.recordURL)
        let client = MusaiClient(record: record, token: record.token)
        #expect(await client.health() != nil)
    }

    @Test func statusTextReportsWhatTheBackendIsDoing() async throws {
        let store = Self.temporaryStore()
        let agent = try MusaiAgent(libraryURL: store, detector: SilentDetector(), logURL: Self.log(for: store))
        defer {
            agent.stop()
            try? FileManager.default.removeItem(at: store.deletingLastPathComponent())
        }

        #expect(await agent.statusText() == "running")
        await agent.state.setBacklogDepth(2)
        #expect(await agent.statusText() == "backlog(2)")
        await agent.state.setStoreState(.failed)
        #expect(await agent.statusText() == "storeFailed")
        await agent.state.requestRestart()
        #expect(await agent.statusText() == "needsRestart")
    }

    /// The status item is driven by this seam instead of a timer, so it has to be true that a change publishes
    /// and an idle state stays silent.
    @Test func aStatusChangeIsPublishedAndIdleIsSilent() async throws {
        let store = Self.temporaryStore()
        let agent = try MusaiAgent(libraryURL: store, detector: SilentDetector(), logURL: Self.log(for: store))
        defer {
            agent.stop()
            try? FileManager.default.removeItem(at: store.deletingLastPathComponent())
        }

        let recorder = StatusRecorder()
        await agent.state.observeStatus { text in recorder.record(text) }
        // Nothing has happened yet: an idle state publishes nothing.
        #expect(recorder.seen.isEmpty)

        await agent.state.setBacklogDepth(2)
        #expect(recorder.seen == ["backlog(2)"])

        // Setting the value it already holds is not a change.
        await agent.state.setBacklogDepth(2)
        #expect(recorder.seen == ["backlog(2)"])

        await agent.state.requestRestart()
        #expect(recorder.seen == ["backlog(2)", "needsRestart"])
    }

    @Test func itReopensAfterAFailedStoreState() async throws {
        let store = Self.temporaryStore()
        let opens = OpenCounter()
        let probe = FatalOnceProbe()
        let agent = try MusaiAgent(
            libraryURL: store, detector: SilentDetector(), logURL: Self.log(for: store),
            open: { url, options in
                await opens.bump()
                return try await MusaiLibrary.open(at: url, options: options)
            },
            probe: { db in try await probe.check(db) })
        defer {
            agent.stop()
            try? FileManager.default.removeItem(at: store.deletingLastPathComponent())
        }

        _ = try await agent.start()

        // A fatal state is a reopen, not a death: the store was opened twice.
        #expect(await opens.count == 2)
        // The failure leaves a restart pending, which is what the status item shows.
        #expect(await agent.statusText() == "needsRestart")

        // And it serves on the reopened store, which is healthy again.
        let record = try HelperRecord.read(from: agent.recordURL)
        let client = MusaiClient(record: record, token: record.token)
        let health = try #require(await client.health())
        #expect(health.storeState == .open)
    }
}
