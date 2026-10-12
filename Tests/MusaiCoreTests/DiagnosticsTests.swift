import Darwin
import Foundation
import NorvoLite
import Testing
@testable import MusaiCore

/// `musai doctor`, in the five states it must not conflate: the agent has never run; it ran and the process
/// that wrote the record is gone; it is alive but nothing answers `/health`; `/health` answers; `/health`
/// answers with a store that could not be opened. A person who cannot tell those apart cannot fix any of
/// them, and `doctor` is the thing they run when the backend is broken.
///
/// Plus the agent's half of it: a store that cannot be opened leaves a process that keeps answering, rather
/// than one that exits and is relaunched by launchd forever.
@Suite struct DiagnosticsTests {
    private static let token = "a-token-a-test-chose"

    /// The one line a refusal is: `{"error": "…"}`.
    private struct Refusal: Decodable {
        let error: String
    }

    /// A pid no process can hold, so the record is a corpse whatever this machine happens to be running.
    /// The same idiom as `ListenerTests.aDeadPidsRecordIsNotAlive`.
    private static let gonePid = Int32.max

    private static func record(pid: Int32, port: UInt16 = 51_234) -> HelperRecord {
        HelperRecord(
            port: port, token: token, pid: pid, protocolVersion: EndpointWire.protocolVersion,
            storePath: "/tmp/musai-doctor/Musai.norvo")
    }

    private static func healthy(
        storeState: StoreState = .open, backlog: Int = 3, curator: CuratorState = .draining,
        startedAt: Date = Date()
    ) -> EndpointHealth {
        EndpointHealth(
            protocolVersion: EndpointWire.protocolVersion, storePath: "/tmp/musai-doctor/Musai.norvo",
            startedAt: startedAt, storeState: storeState, backlogDepth: backlog, curatorState: curator)
    }

    // MARK: - The five states

    /// No record at all: the agent has never run here, and the screen has to say how to install it.
    @Test func anAgentThatHasNeverRunSaysSoAndSaysHowToInstallIt() {
        let screen = MusaiDiagnostics.screen(record: nil, health: nil, logTail: [], bundlePath: nil)

        #expect(screen.contains("has never run"))
        #expect(screen.contains("musai install"))
        // The bundle is what the launch agent names, so a missing one is why it never appears.
        #expect(screen.contains("Musai.app"))
    }

    /// A record left by a process that is gone: not running, with the pid that wrote it — and the last log
    /// lines, because that is where the reason is.
    @Test func aDeadProcessIsNotRunningAndTheLogIsShown() {
        let screen = MusaiDiagnostics.screen(
            record: Self.record(pid: Self.gonePid), health: nil, logTail: ["the store was here", "and then"],
            bundlePath: URL(fileURLWithPath: "/Applications/Musai.app"))

        #expect(screen.contains("not running (pid \(Self.gonePid) is gone)"))
        #expect(screen.contains("the store was here"))
        #expect(screen.contains("and then"))
    }

    /// The record's pid is alive but nothing answers: a different fact from a dead pid, and the one a
    /// person otherwise cannot see — "it is running" and "it works" are not the same sentence.
    @Test func aLiveProcessThatDoesNotAnswerIsToldApartFromADeadOne() {
        let screen = MusaiDiagnostics.screen(
            record: Self.record(pid: getpid()), health: nil, logTail: [], bundlePath: nil)

        #expect(screen.contains("alive"))
        #expect(screen.contains("not answering"))
        #expect(!screen.contains("is gone"))
    }

    /// `/health` answers: everything a person needs to see that the backend is well, and which build of it.
    @Test func aHealthyBackendShowsTheStoreTheUptimeTheBacklogTheCuratorAndTheProtocol() {
        let health = Self.healthy(startedAt: Date().addingTimeInterval(-7_200))
        let screen = MusaiDiagnostics.screen(
            record: Self.record(pid: getpid()), health: health, logTail: [],
            bundlePath: URL(fileURLWithPath: "/Applications/Musai.app"))

        #expect(screen.contains("/tmp/musai-doctor/Musai.norvo"))
        // Two hours, as a person measures it.
        #expect(screen.contains("up 2h 0m"))
        #expect(screen.contains("backlog: 3"))
        #expect(screen.contains("draining"))
        #expect(screen.contains(EndpointWire.protocolVersion))
        #expect(screen.contains("/Applications/Musai.app"))
    }

    /// The amendment's other half: `/health` answering `failed` must be visible to the person, and must name
    /// the file that has the reason in it.
    @Test func anUnopenableStoreIsVisibleAndNamesTheLog() {
        let screen = MusaiDiagnostics.screen(
            record: Self.record(pid: getpid()), health: Self.healthy(storeState: .failed, backlog: 0, curator: .idle),
            logTail: ["the store at /tmp/musai-doctor/Musai.norvo could not be opened: no such file"],
            bundlePath: nil)

        #expect(screen.contains("could not be opened"))
        #expect(screen.contains(MusaiLog.defaultURL.path))
        #expect(screen.contains("no such file"))
        // It must not claim the store is open when it is not.
        #expect(!screen.contains("— open"))
    }

    // MARK: - The log

    /// The log a person reads: bounded to the last few thousand lines, created on first write, and readable
    /// from the tail without knowing its size.
    @Test func theLogCreatesItsDirectoryAndKeepsOnlyItsLastLines() {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "nested/deeper/helper.log")
        let log = MusaiLog(url: url, limit: 3)

        // Nowhere to write to yet: writing is what makes the directory.
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        for index in 1...5 { log.write("line \(index)") }

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(log.tail(10) == ["line 3", "line 4", "line 5"])
        #expect(log.tail(2) == ["line 4", "line 5"])

        // A second reader of the same file sees the same bound, and the plan's number is the default.
        #expect(MusaiLog(url: url).tail(10) == ["line 3", "line 4", "line 5"])
        #expect(MusaiLog().limit == 2_000)
        #expect(MusaiLog.defaultURL.path.hasSuffix("/Library/Logs/Musai/helper.log"))

        // One line carries the time it happened: the first thing a person looks for in a log.
        #expect(MusaiLog.line("started").contains("started"))
        #expect(MusaiLog.line("started", at: Date(timeIntervalSince1970: 1_700_000_000)).hasPrefix("2023-11-14"))
    }

    // MARK: - The process that stays up

    /// The endpoint exists with no store open at all: `/health` answers with the truth, every other route
    /// says why it cannot, and a stranger still learns nothing.
    @Test func anEndpointWithNoStoreAnswersHealthAndRefusesEveryOtherRoute() async throws {
        let state = EndpointState(storePath: "/tmp/musai-doctor/Musai.norvo")
        await state.setStoreState(.failed)
        let endpoint = MusaiEndpoint(
            store: .none, state: state, token: Self.token, logPath: "/tmp/musai-doctor/helper.log")

        let health = await endpoint.respond(
            to: EndpointRequest(method: "GET", path: "/health", token: Self.token))
        #expect(health.status == 200)
        let decoded = try EndpointWire.decoder().decode(EndpointHealth.self, from: health.body)
        #expect(decoded.storeState == .failed)
        #expect(decoded.storePath == "/tmp/musai-doctor/Musai.norvo")

        let capture = await endpoint.respond(
            to: EndpointRequest(method: "POST", path: "/capture", token: Self.token))
        #expect(capture.status == 503)
        let line = try JSONDecoder().decode(Refusal.self, from: capture.body).error
        #expect(line.contains("/tmp/musai-doctor/helper.log"))

        let stranger = await endpoint.respond(
            to: EndpointRequest(method: "GET", path: "/health", token: "an-impostor"))
        #expect(stranger.status == 401)
    }

    /// Resolution 2's third case, and the one the amendment exists for: a fatal state that reopening does
    /// not clear must not propagate out of `start()`. The process keeps its listener, `/health` says the
    /// store is not open, and a person — or `doctor` — can read why.
    @Test func aPersistentStoreFailureIsServedRatherThanFatal() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-doctor-agent-\(UUID().uuidString)")
        let store = directory.appending(path: "Musai.norvo")
        let logURL = directory.appending(path: "helper.log")
        // Every probe says fatal, so the reopen cannot clear the state either.
        let agent = try MusaiAgent(
            libraryURL: store, detector: SilentDetector(), logURL: logURL,
            probe: { _ in throw NorvoError(code: .fatal, message: "the store reported a fatal state") },
            sleep: { _ in })
        defer {
            agent.stop()
            try? FileManager.default.removeItem(at: directory)
        }

        // It returns a port instead of throwing: the process stays up, so a person can ask it what is wrong
        // rather than watching launchd relaunch a process that dies on the same file forever.
        let port = try await agent.start()
        #expect(port != 0)
        #expect(await agent.statusText() == "storeFailed")

        // `/health` answers — the record's port is live — and says the store is not open.
        let record = try HelperRecord.read(from: agent.recordURL)
        let client = MusaiClient(record: record, token: record.token)
        let health = try #require(await client.health())
        #expect(health.storeState == .failed)
        #expect(health.storePath == store.path)

        // Nothing is stored into a store that is not open, and the client is told so once, in a line naming
        // the log — not left waiting, and not answered with a lie.
        var refusal: MusaiClient.Failure?
        do {
            _ = try await client.capture(
                NormalizedEvent(
                    kind: .userTurn, session: "s1", cwd: "/tmp/musai-doctor", at: Date(),
                    text: "words that must not be stored"))
        } catch let failure as MusaiClient.Failure {
            refusal = failure
        }
        guard case .unexpectedStatus(let status, let body) = refusal else {
            Issue.record("a capture into a store that is not open must be refused")
            return
        }
        #expect(status == 503)
        #expect(body.contains("helper.log"))

        // The log holds the reason, which is all a person has left to read.
        let tail = MusaiLog(url: logURL).tail(20)
        #expect(tail.contains { $0.contains(store.path) })

        // And the screen says it, from what `doctor` would have read.
        let screen = MusaiDiagnostics.screen(
            record: record, health: health, logTail: tail, bundlePath: nil)
        #expect(screen.contains("could not be opened"))
    }
}
