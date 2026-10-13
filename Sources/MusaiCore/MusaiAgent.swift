import Foundation
import NorvoLite
import os

/// The process that owns the store. It opens the one file, serves the endpoint, publishes the record and the
/// token beside it, and starts the curator — and nothing else opens the store, so a second agent is refused
/// rather than allowed to share it.
///
/// It holds no protocol logic of its own: the endpoint is the router, the curator is the drain, and this type
/// is the lifecycle that starts and stops them.
///
/// A store it cannot open is not a reason to die, either: the process keeps its listener and says so, through
/// `/health`, the status item and its log, because a process that exits on a file it cannot open is a process
/// launchd relaunches forever and no one can ask anything.
public final class MusaiAgent: @unchecked Sendable {
    /// The system log, alongside the file. A person reading Console should see the same lines as a person
    /// reading the file.
    private static let logger = Logger(subsystem: "dev.musai.agent", category: "helper")

    /// How the store is opened. Injected so a test can meet a held lock or a fatal state without a real engine
    /// condition.
    public typealias StoreOpener = @Sendable (URL, Options) async throws -> MusaiLibrary
    /// A cheap read that tells a healthy store from one the engine has declared failed. Injected so a test can
    /// report a fatal state once.
    public typealias StoreProbe = @Sendable (Database) async throws -> Void

    /// Why the agent could not start.
    public enum Failure: Error, CustomStringConvertible, Equatable {
        /// Another process holds the store. The message names the file, so the person can see which one.
        case storeHeld(path: String)
        /// `start()` was called twice.
        case alreadyStarted

        public var description: String {
            switch self {
            case .storeHeld(let path):
                "the store at \(path) is already open in another process"
            case .alreadyStarted:
                "the agent is already started"
            }
        }
    }

    public let libraryURL: URL
    public let options: Options
    /// Beside the store: the file a client reads to find this process, and the secret it must present. The
    /// token outlives the process — a restart must not hand every client a new secret — but the record does
    /// not, because a record naming a dead port is a lie.
    public let recordURL: URL
    public let tokenURL: URL
    /// What `/health` reports and the status item shows. Built here with the default protocol version, so it
    /// can only report the protocol this process really serves.
    public let state: EndpointState
    /// The model the curator asks for proposals.
    public let detector: any DecisionDetector
    /// What files the curator's ambient memory. `nil` files none, which is the meaning `nil` has in
    /// `CuratorController` too: the process that owns the store is where a model is turned on, so a fixture —
    /// or a backend nobody configured one for — drains without a producer rather than being sent to a model by
    /// a default it did not ask for.
    public let filer: (any MemoryFiler)?

    private let log: MusaiLog
    private let open: StoreOpener
    private let probe: StoreProbe
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let attempts: Int
    private let debounce: TimeInterval

    /// `start`/`stop` and the status ticker touch these; one lock guards them.
    private let lock = NSLock()
    private var library: MusaiLibrary?
    private var listener: EndpointListener?
    private var curator: CuratorController?
    /// True between `claimStart` and `adopt`, so a concurrent second `start()` is refused.
    private var starting = false
    /// True once this process asked to be told about a fatal reported through the state, so a retried `start()`
    /// does not register a second time.
    private var observingFatal = false

    /// - Parameters:
    ///   - libraryURL: the one store this agent serves, and whose directory holds the record and the token.
    ///   - detector: what the curator asks for proposals; the real one talks to the configured model.
    ///   - filer: what files the curator's ambient memory; `nil` files none.
    ///   - logURL: where the log a person reads goes. Injectable for the same reason the store is: a test
    ///     must not write into the developer's real `~/Library/Logs/Musai`.
    ///   - open/probe/sleep/attempts: the opening and its backoff, injectable so a test drives a held lock or
    ///     a fatal state without a real wait.
    public init(
        libraryURL: URL,
        options: Options = .init(),
        detector: (any DecisionDetector)? = nil,
        filer: (any MemoryFiler)? = nil,
        logURL: URL = MusaiLog.defaultURL,
        open: @escaping StoreOpener = { url, options in
            try await MusaiLibrary.open(at: url, options: options)
        },
        probe: @escaping StoreProbe = { db in
            _ = try await db.query(UndrainedEventsQuery(.init(first: 1)))
        },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        },
        attempts: Int = 4,
        debounce: TimeInterval = 3
    ) throws {
        self.libraryURL = libraryURL
        self.options = options
        self.recordURL = libraryURL.deletingLastPathComponent().appending(path: "helper.json")
        self.tokenURL = libraryURL.deletingLastPathComponent().appending(path: "token")
        self.state = EndpointState(storePath: libraryURL.path)
        self.log = MusaiLog(url: logURL)
        self.detector =
            detector
            ?? ModelDecisionDetector(
                provider: OpenAICompatibleProvider(
                    configuration: (try? ModelConfiguration.load()) ?? .default))
        self.filer = filer
        self.open = open
        self.probe = probe
        self.sleep = sleep
        self.attempts = max(1, attempts)
        self.debounce = debounce
        // The directory that holds the store, the record and the token, made before anything is opened, so an
        // unwritable directory is this initialiser's failure, not a half-started process's.
        try FileManager.default.createDirectory(
            at: libraryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    /// Opens the store once, starts the listener, publishes the record, and returns the port the system chose.
    ///
    /// A held lock still ends the attempt: exactly one process opens the store, and a second agent has to be
    /// refused. A store that cannot be opened at all does *not* end it — see `openStore`.
    @discardableResult
    public func start() async throws -> UInt16 {
        guard claimStart() else { throw Failure.alreadyStarted }
        await observeFatalOnce()
        do {
            return try await performStart()
        } catch {
            // Nothing was published, so the instance is not started and may be tried again.
            releaseClaim()
            throw error
        }
    }

    private func performStart() async throws -> UInt16 {
        let store: MusaiEndpoint.Store
        do {
            store = try await openStore()
        } catch let held as Failure {
            // Another process holds the store. Exactly one process opens it, and this one is not it: it says
            // so, naming the file, and exits — launchd must not be asked to try again forever.
            note("the store is held by another process: \(held)")
            throw held
        } catch {
            // The store cannot be opened, and reopening it did not help. Nothing else on this Mac can
            // diagnose that, so the process stays up with no store and tells the truth: `/health` says
            // `failed`, the status item shows it, and this log names why. Exiting here is what launchd would
            // turn into a process that dies and is relaunched forever, with nothing left to ask.
            note("the store at \(libraryURL.path) could not be opened: \(Self.oneLine(error))")
            await state.setStoreState(.failed)
            store = .none
        }

        let token = try MusaiToken.loadOrCreate(at: tokenURL)
        // No store, no drain: a curator reads and writes the store, so a storeless process has none.
        var library: MusaiLibrary?
        var curator: CuratorController?
        if case .open(let db, let opened) = store {
            library = opened
            // The curator reports a mid-life fatal through the same state the endpoint does; `state` is captured
            // rather than `self`, so the controller never holds this agent alive.
            curator = CuratorController(
                db: db, detector: detector, filer: filer, sleep: sleep, debounce: debounce,
                onFatal: { [state] detail in await state.reportFatal(detail) })
        }
        let endpoint = MusaiEndpoint(
            store: store, state: state, curator: curator, token: token, logPath: log.url.path,
            probe: probe)
        let listener = EndpointListener(endpoint: endpoint)
        let port = try listener.start()

        adopt(library: library, listener: listener, curator: curator)

        let record = HelperRecord(
            port: port, token: token, pid: getpid(),
            protocolVersion: EndpointWire.protocolVersion, storePath: libraryURL.path)
        // Written only once the listener is up, so a record is never published for a port nothing owns —
        // and written even when the store did not open, because `/health` is how a person finds out why.
        try record.write(to: recordURL)
        // The last line says what is true now, which is what a person reads first in a tail.
        switch store {
        case .open:
            note("started on 127.0.0.1:\(port), serving \(libraryURL.path)")
        case .none:
            note(
                "the listener is up on 127.0.0.1:\(port) and /health says the store is not open; "
                    + "nothing is captured until it can be")
        }
        return port
    }

    /// The store this process will serve, or a thrown `Failure.storeHeld` when another process holds it.
    ///
    /// A fatal state is a moment to survive, not a death: the handle is closed, the store reopened, and the
    /// reopened one — healthy again — is what gets served, with a clean process asked for through launchd.
    /// Anything else that leaves no store to serve (permissions, a corrupt file, a fatal state that reopening
    /// did not clear) is thrown to the caller, which serves the failure instead of exiting on it.
    private func openStore() async throws -> MusaiEndpoint.Store {
        var opened = try await openWithBackoff()
        do {
            try await probe(opened.db)
        } catch let error as NorvoError where error.code == .fatal {
            note("the store reported a fatal state; reopening it")
            await state.setStoreState(.failed)
            opened.close()
            let reopened = try await openWithBackoff()
            // A reopened store that is fatal too is not a moment to survive: it is the failure the process
            // has to report, so the throw leaves `performStart` with nothing to serve and everything to say.
            try await probe(reopened.db)
            opened = reopened
            // Reopened is still a process that has been through a fatal state: ask launchd for a clean one.
            await state.requestRestart()
        }
        await state.setStoreState(.open)
        return .open(db: opened.db, library: opened)
    }

    /// Registers for a fatal reported while this process is up, once and once only: a `start()` that threw may
    /// be tried again, and a second registration would say the same failure twice.
    private func observeFatalOnce() async {
        guard claimFatalObservation() else { return }
        await state.observeFatal { [weak self] detail in
            await self?.noteFatal(detail)
        }
    }

    /// Claims the one registration, synchronously, so the lock is never held across an `await`.
    private func claimFatalObservation() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !observingFatal else { return false }
        observingFatal = true
        return true
    }

    /// The engine declared the store failed while this process was serving. One line to the log a person reads,
    /// and a clean process asked for, which the executable honours by exiting for launchd — the start-time path
    /// is what probes and reopens, and reopening in place is deliberately the app slice's repair, not this one's.
    private func noteFatal(_ detail: String) async {
        note("the store reported a fatal state while serving: \(detail)")
        await state.requestRestart()
    }

    /// One line to both places it belongs: the file a person reads with `musai doctor`, and the system log.
    /// Neither is allowed to be the reason a start fails.
    private func note(_ message: String) {
        log.write(MusaiLog.line(message))
        Self.logger.notice("\(message)")
    }

    /// One line of a failure, cut before the engine's stack dump.
    private static func oneLine(_ error: any Error) -> String {
        let text = String(describing: error)
        return text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "failed"
    }

    /// One line for the status item, read from the state `/health` serves, so the item and the wire agree.
    public func statusText() async -> String {
        await state.statusText()
    }

    /// Whether `POST /admin/restart` has been asked for. The endpoint only records it; ending the process so
    /// launchd brings it back is the executable's job.
    public func restartRequested() async -> Bool {
        await state.restartRequested
    }

    /// Stops the listener and closes the store. The record goes with them — a record naming a port nothing
    /// owns would send a client's words into a stranger — but the token stays, so a restart is not a new
    /// secret.
    ///
    /// The listener, not the store, is what proves the record is ours to remove: a process whose store never
    /// opened still published one, because `/health` is how a person learns why.
    public func stop() {
        lock.lock()
        let listener = self.listener
        let library = self.library
        self.listener = nil
        self.library = nil
        self.curator = nil
        lock.unlock()

        listener?.stop()
        library?.close()
        // Only a record this process published is its to remove: an agent that never started has no business
        // deleting the holder's.
        if listener != nil {
            try? FileManager.default.removeItem(at: recordURL)
        }
    }

    /// Claims `start()` for this instance, so a second call is told no rather than binding a second listener.
    /// Synchronous so the lock is never held across an `await`. The listener is what says this instance has
    /// started: a process whose store never opened holds one all the same.
    private func claimStart() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard listener == nil, !starting else { return false }
        starting = true
        return true
    }

    /// Gives back a claim that produced no listener, so a failed `start()` can be retried.
    private func releaseClaim() {
        lock.lock()
        defer { lock.unlock() }
        starting = false
    }

    /// Publishes what `start()` built. Synchronous, for the same reason as `claimStart`. The store is absent
    /// when it could not be opened; the listener is not.
    private func adopt(
        library: MusaiLibrary?, listener: EndpointListener, curator: CuratorController?
    ) {
        lock.lock()
        defer { lock.unlock() }
        self.library = library
        self.listener = listener
        self.curator = curator
        starting = false
    }

    /// Opens the store, retrying a held lock with bounded backoff. A lock held by a live process never
    /// releases, so waiting forever would only hide the one fact the person needs: which store is held.
    private func openWithBackoff() async throws -> MusaiLibrary {
        for attempt in 0..<attempts {
            do {
                return try await open(libraryURL, options)
            } catch let error as NorvoError where error.code == .locked || error.code == .busy {
                if attempt < attempts - 1 { await sleep(backoff(attempt)) }
            }
        }
        throw Failure.storeHeld(path: libraryURL.path)
    }

    /// Doubles from 100 ms: long enough to outlast a restarting predecessor, short enough to fail visibly.
    private func backoff(_ attempt: Int) -> TimeInterval {
        0.1 * pow(2, Double(attempt))
    }
}
