import Foundation

/// The store, as a client reads it. `failed` is the engine's fatal state (§ "the store can enter a failed
/// state"): the agent reopens and says so, because a client cannot.
public enum StoreState: String, Sendable, Codable {
    case open
    case failed
}

/// What the curator is doing. The controller makes the transitions; a request mirrors them into the state.
public enum CuratorState: String, Sendable, Codable {
    case idle
    case pending
    case draining
}

/// What the endpoint knows about itself: the facts `/health` reports and the status item shows. An actor,
/// because captures, drains and reads all touch it, and none may block another.
public actor EndpointState {
    /// When this process started serving, so a client can show uptime.
    public let startedAt: Date
    /// The one store this process serves. A client that expected another reads this and says so, rather
    /// than writing where it was not expected.
    public let storePath: String
    /// The protocol this process serves. It is the wire's own by default; a test injects another so a client
    /// can be shown refusing a helper of a different major.
    public let protocolVersion: String

    private var storeState: StoreState = .open
    private var backlogDepth = 0
    private var curatorState: CuratorState = .idle
    private var askedToRestart = false

    /// Handlers the status item drives itself from. Called synchronously from a mutation with the same string
    /// `statusText()` returns, and never while nothing changes, so the item needs no timer and an idle agent
    /// does nothing at all.
    private var statusObservers: [@Sendable (String) -> Void] = []

    public init(
        storePath: String, startedAt: Date = Date(),
        protocolVersion: String = EndpointWire.protocolVersion
    ) {
        self.storePath = storePath
        self.startedAt = startedAt
        self.protocolVersion = protocolVersion
    }

    /// Registers a handler for every future status change. It is not called on registration; the caller reads
    /// `statusText()` once for the current value.
    public func observeStatus(_ handler: @escaping @Sendable (String) -> Void) {
        statusObservers.append(handler)
    }

    /// Tells every observer the new line. Called only by a mutation that actually changed something, so an
    /// unchanged state — an idle agent — publishes nothing.
    private func publishStatus() {
        let text = statusText()
        for observer in statusObservers { observer(text) }
    }

    public func setStoreState(_ value: StoreState) {
        guard storeState != value else { return }
        storeState = value
        publishStatus()
    }

    /// Mirrored from the queue at request time; the store is the truth.
    public func setBacklogDepth(_ value: Int) {
        guard backlogDepth != value else { return }
        backlogDepth = value
        publishStatus()
    }

    public func setCuratorState(_ value: CuratorState) {
        guard curatorState != value else { return }
        curatorState = value
        publishStatus()
    }

    /// A restart was asked for. Answering the request is still this process's job — an endpoint that killed
    /// its own process could not answer the request it was given — so the request is recorded, and the agent
    /// (Task 5), which reads this, ends the process.
    public func requestRestart() {
        guard !askedToRestart else { return }
        askedToRestart = true
        publishStatus()
    }

    public var restartRequested: Bool { askedToRestart }

    /// The `/health` body.
    public func health() -> EndpointHealth {
        EndpointHealth(
            protocolVersion: protocolVersion,
            storePath: storePath,
            startedAt: startedAt,
            storeState: storeState,
            backlogDepth: backlogDepth,
            curatorState: curatorState)
    }

    /// One line for the status item: what the backend is doing, or what is wrong with it.
    public func statusText() -> String {
        if askedToRestart { return "needsRestart" }
        if storeState == .failed { return "storeFailed" }
        if backlogDepth > 0 { return "backlog(\(backlogDepth))" }
        return "running"
    }
}