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
    /// The wall clock the retention sweep reads and is throttled by. Injected, so a test drives a day
    /// rather than waiting one out.
    public let now: @Sendable () -> Date
    /// The longest the retention sweep may go unrun.
    public let sweepInterval: TimeInterval

    /// What the curator is doing right now: `idle`, `pending` (a drain is scheduled), or `draining`.
    public private(set) var curatorState: CuratorState = .idle
    /// How many drains have run. A debounce test reads it to prove a burst drove exactly one.
    public private(set) var drainCount = 0

    private var debounceTask: Task<Void, Never>?
    private var runningDrain: Task<Int, Error>?
    private var lastSweep: Date?

    public init(
        db: Database,
        detector: any DecisionDetector,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        },
        debounce: TimeInterval = 3,
        now: @escaping @Sendable () -> Date = { Date() },
        sweepInterval: TimeInterval = 24 * 60 * 60
    ) {
        self.db = db
        self.detector = detector
        self.sleep = sleep
        self.debounce = debounce
        self.now = now
        self.sweepInterval = sweepInterval
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
    ///
    /// After the queue is settled the retention sweep runs, at most once a `sweepInterval`.
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
        await sweepExpiredEventsIfDue()
        return written
    }

    private func performDrain() async throws -> Int {
        curatorState = .draining
        drainCount += 1
        // Cleared here rather than by the caller, so a coalesced caller that resumes when this completes
        // always sees no drain running and can look at the queue for itself.
        defer {
            curatorState = .idle
            runningDrain = nil
        }
        // Each event files under its own session's project; the curator resolves that per group.
        return try await ProposalCurator(db: db, detector: detector).drain(as: MusaiActors.curator)
    }

    /// The queue's own retention, throttled to one a day: drop the drained events that are older than the
    /// window. A failure is silent — the next sweep retries.
    private func sweepExpiredEventsIfDue() async {
        let moment = now()
        if let last = lastSweep, moment.timeIntervalSince(last) < sweepInterval { return }
        lastSweep = moment
        _ = try? await ProposalCurator(db: db, detector: detector)
            .expireDrainedEvents(now: moment, as: MusaiActors.curator)
    }

    /// The events still waiting to be drained, as ids — `first` is a bound the backlog should never reach.
    private func undrainedIDs() async throws -> Set<UUID> {
        Set(try await db.query(UndrainedEventsQuery(.init(first: 1_000_000))).events.map(\.id))
    }
}
