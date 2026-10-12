import Foundation
import NorvoLite

/// Holds the curator's drain off the request path. A capture only notes that the queue grew; the model runs
/// in a debounced task of its own — never more than one drain per `debounce` interval — so a slow model
/// never delays a capture, and nothing runs at all when there is nothing to do.
public actor CuratorController {
    public let db: Database
    public let detector: any DecisionDetector
    /// How the passage of a debounce interval happens. Injected, so a test drives time rather than
    /// waiting a real interval out.
    public let sleep: @Sendable (TimeInterval) async -> Void
    /// The window a burst of captures collapses into one drain inside.
    public let debounce: TimeInterval

    /// What the curator is doing right now: `idle`, `pending` (a drain is scheduled), or `draining`.
    public private(set) var curatorState: CuratorState = .idle

    private var debounceTask: Task<Void, Never>?
    private var runningDrain: Task<Int, Error>?

    public init(
        db: Database,
        detector: any DecisionDetector,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        },
        debounce: TimeInterval = 3
    ) {
        self.db = db
        self.detector = detector
        self.sleep = sleep
        self.debounce = debounce
    }

    /// A capture happened: the queue grew. Sets the state to `pending` and schedules the drain, unless one
    /// is already scheduled — the pending drain will pick this capture up too, because the queue is global.
    public func noteCapture() async {
        curatorState = .pending
        guard debounceTask == nil else { return }
        let nap = sleep
        let window = debounce
        debounceTask = Task {
            await nap(window)
            await self.settle()
        }
    }

    /// The debounce window passed: the next capture may schedule a fresh one while this drain runs, and it
    /// will find whatever this drain leaves behind.
    private func settle() async {
        debounceTask = nil
        // A failed drain leaves the queue intact (the curator marks nothing drained unless it wrote the
        // proposals), so the next capture's drain retries it.
        _ = try? await drainNow()
    }

    /// Drains the queue now, whatever the debounce says. Concurrent callers — a hand-started drain and a
    /// debounced one — await the same run rather than racing each other into the queue.
    ///
    /// A capture can land *while* a drain runs, after that drain has read its batch. A caller that only
    /// coalesced with the running drain would report the queue drained and go idle, stranding the later event
    /// until the next capture — and losing it if the retention window passed. So after every join or run the
    /// queue is looked at again, and drained again if anything is left. The loop stops when the queue is empty,
    /// or unchanged: an event the curator cannot file must not spin here.
    @discardableResult
    public func drainNow() async throws -> Int {
        var written = 0
        while true {
            let before = try await undrainedIDs()
            if before.isEmpty { break }
            if let running = runningDrain {
                written += try await running.value
            } else {
                let task = Task<Int, Error> { try await self.performDrain() }
                runningDrain = task
                written += try await task.value
            }
            let after = try await undrainedIDs()
            if after.isEmpty || after == before { break }
        }
        return written
    }

    private func performDrain() async throws -> Int {
        curatorState = .draining
        // Cleared here rather than by the caller, so a coalesced caller that resumes when this completes
        // always sees no drain running and can look at the queue for itself.
        defer {
            curatorState = .idle
            runningDrain = nil
        }
        // Task 4 replaces this resolution: the queue is global and each event files under its own session's
        // project. Until then the batch drains under the first event's session's project — right for every
        // single-project queue, which is all this slice exercises.
        let events = try await db.query(UndrainedEventsQuery()).events
        guard let sessionId = events.first?.session?.memorySessionId,
            let row = try await db.query(SessionByMemoryIdQuery(.init(memorySessionId: sessionId))).session,
            let cwd = row.cwd
        else { return 0 }
        let project = try await ProjectBinder(db: db).resolveProject(
            cwd: URL(fileURLWithPath: cwd), as: MusaiActors.curator)
        return try await ProposalCurator(db: db, detector: detector)
            .drain(project: project, as: MusaiActors.curator)
    }

    /// The events still waiting to be drained, as ids — `first` is a bound the backlog should never reach.
    private func undrainedIDs() async throws -> Set<UUID> {
        Set(try await db.query(UndrainedEventsQuery(.init(first: 1_000_000))).events.map(\.id))
    }
}