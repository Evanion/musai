import Foundation
import NorvoLite

/// The process that owns the store. It opens the one file, serves the endpoint, publishes the record and the
/// token beside it, and starts the curator — and nothing else opens the store, so a second agent is refused
/// rather than allowed to share it.
///
/// It holds no protocol logic of its own: the endpoint is the router, the curator is the drain, and this type
/// is the lifecycle that starts and stops them.
public final class MusaiAgent: @unchecked Sendable {
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

    /// - Parameters:
    ///   - libraryURL: the one store this agent serves, and whose directory holds the record and the token.
    ///   - detector: what the curator asks for proposals; the real one talks to the configured model.
    ///   - open/probe/sleep/attempts: the opening and its backoff, injectable so a test drives a held lock or
    ///     a fatal state without a real wait.
    public init(
        libraryURL: URL,
        options: Options = .init(),
        detector: (any DecisionDetector)? = nil,
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
        self.detector =
            detector
            ?? ModelDecisionDetector(
                provider: OpenAICompatibleProvider(
                    configuration: (try? ModelConfiguration.load()) ?? .default))
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
    /// A store the engine has declared failed is reopened — the process asks launchd for a clean replacement
    /// but does not die here, so the moment is not lost.
    @discardableResult
    public func start() async throws -> UInt16 {
        guard claimStart() else { throw Failure.alreadyStarted }
        do {
            return try await performStart()
        } catch {
            // Nothing was published, so the instance is not started and may be tried again.
            releaseClaim()
            throw error
        }
    }

    private func performStart() async throws -> UInt16 {
        var opened = try await openWithBackoff()
        do {
            try await probe(opened.db)
        } catch let error as NorvoError where error.code == .fatal {
            // The engine's fatal state: close, reopen, and check again. The reopened handle is the one served.
            await state.setStoreState(.failed)
            opened.close()
            opened = try await openWithBackoff()
            try await probe(opened.db)
            // Reopened is still a process that has been through a fatal state: ask launchd for a clean one.
            await state.requestRestart()
        }
        await state.setStoreState(.open)

        let token = try MusaiToken.loadOrCreate(at: tokenURL)
        let curator = CuratorController(
            db: opened.db, detector: detector, sleep: sleep, debounce: debounce)
        let endpoint = MusaiEndpoint(
            db: opened.db, library: opened, state: state, curator: curator, token: token)
        let listener = EndpointListener(endpoint: endpoint)
        let port = try listener.start()

        adopt(library: opened, listener: listener, curator: curator)

        let record = HelperRecord(
            port: port, token: token, pid: getpid(),
            protocolVersion: EndpointWire.protocolVersion, storePath: libraryURL.path)
        // Written only once the listener is up, so a record is never published for a port nothing owns.
        try record.write(to: recordURL)
        return port
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
        if library != nil {
            try? FileManager.default.removeItem(at: recordURL)
        }
    }

    /// Claims `start()` for this instance, so a second call is told no rather than binding a second listener.
    /// Synchronous so the lock is never held across an `await`.
    private func claimStart() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard library == nil, !starting else { return false }
        starting = true
        return true
    }

    /// Gives back a claim that produced no listener, so a failed `start()` can be retried.
    private func releaseClaim() {
        lock.lock()
        defer { lock.unlock() }
        starting = false
    }

    /// Publishes what `start()` built. Synchronous, for the same reason as `claimStart`.
    private func adopt(library: MusaiLibrary, listener: EndpointListener, curator: CuratorController) {
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
