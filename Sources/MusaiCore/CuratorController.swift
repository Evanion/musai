import Foundation
import NorvoLite

/// Holds the curator's drain off the request path. A capture only notes that the queue grew; the model runs
/// in a debounced task of its own — never more than one drain per `debounce` interval — so a slow model
/// never delays a capture, and nothing runs at all when there is nothing to do.
public actor CuratorController {
    public let db: Database
    public let detector: any DecisionDetector
    /// What files the drain's ambient memory, besides its proposals. `nil` — a fixture, or a process nobody
    /// configured a model for — means the curator proposes decisions only, and the drain then reads nothing
    /// extra.
    public let filer: (any MemoryFiler)?
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
    /// What to do when the engine declares the store failed during a drain. Nobody awaits the debounced drain,
    /// so its failure is otherwise invisible; it is handed up to the agent, which owns the log and the restart.
    public let onFatal: (@Sendable (String) async -> Void)?

    /// What the curator is doing right now: `idle`, `pending` (a drain is scheduled), or `draining`.
    public private(set) var curatorState: CuratorState = .idle
    /// How many drains have run. A debounce test reads it to prove a burst drove exactly one.
    public private(set) var drainCount = 0
    /// How many filer calls have failed. A misconfigured producer — no model at the configured endpoint — loses
    /// its batch's ambient memory on every drain while the store stays healthy, so this count is the one thing
    /// at runtime that says the producer is down rather than idle.
    public private(set) var filerFailures = 0

    private var debounceTask: Task<Void, Never>?
    private var runningDrain: Task<Int, Error>?
    private var lastSweep: Date?

    public init(
        db: Database,
        detector: any DecisionDetector,
        filer: (any MemoryFiler)? = nil,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        },
        debounce: TimeInterval = 3,
        now: @escaping @Sendable () -> Date = { Date() },
        sweepInterval: TimeInterval = 24 * 60 * 60,
        onFatal: (@Sendable (String) async -> Void)? = nil
    ) {
        self.db = db
        self.detector = detector
        self.filer = filer
        self.sleep = sleep
        self.debounce = debounce
        self.now = now
        self.sweepInterval = sweepInterval
        self.onFatal = onFatal
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
        do {
            _ = try await drainNow()
        } catch let error as NorvoError where error.code == .fatal {
            // A failed drain leaves the queue intact and the next capture retries it, but a *fatal* store is not
            // a queue to retry: it is reported up, like one surfaced by a request, so `/health` can say so.
            await onFatal?(Self.oneLine(error))
        } catch {
            // A failed drain leaves the queue intact (the curator marks nothing drained unless it wrote the
            // proposals), so the next capture's drain retries it.
        }
    }

    /// One line of a failure, cut before the engine's stack dump.
    private static func oneLine(_ error: any Error) -> String {
        let text = String(describing: error)
        return text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "failed"
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
        // Read the queue before the proposals consume it: the producer is asked about the same batch the drain
        // consumed rather than about whatever the next capture left behind. No filer, no read — the producer
        // adds nothing to a drain that files nothing.
        let batches: [SessionBatch] = filer == nil ? [] : try await filableBatch()
        // Each event files under its own session's project; the curator resolves that per group.
        let written = try await ProposalCurator(db: db, detector: detector).drain(as: MusaiActors.curator)
        try await fileAmbientMemory(batches)
        return written
    }

    /// Files the producer's ambient memory, after the proposals and in its own transaction.
    ///
    /// A filer that throws costs this batch its ambient memory and nothing else: the decisions from this same
    /// drain are already written, the queue is drained, and the curator still returns to `idle`. The failure is
    /// not reported up — a model that is unreachable is not a fact about the store, and `onFatal` is for the
    /// store — but it is counted in `filerFailures`, so a producer that is down rather than idle is visible.
    private func fileAmbientMemory(_ batches: [SessionBatch]) async throws {
        guard let filer else { return }
        // The bound belongs to the drain, not to a batch: a queue spanning several sessions may not write
        // `maxPerDrain` per session. What one session's batch lands comes off what the next may.
        var remaining = AmbientMemory.maxPerDrain
        for batch in batches {
            let offered: [DetectedMemory]
            do {
                offered = try await filer.file(from: batch.events)
            } catch {
                // The batch loses its ambient memory and the drain keeps everything else. A model that is down
                // costs the backfill; it does not cost the decisions, and it is not retried — the queue this
                // batch came from is drained by now. It is counted, so `/health` staying green does not mean a
                // misconfigured producer is filing nothing: this is the note.
                filerFailures += 1
                continue
            }
            let memories = offered.prefix(remaining)
            guard !memories.isEmpty else { continue }
            remaining -= try await db.transaction(as: MusaiActors.curator) { tx in
                var wrote = 0
                for memory in memories {
                    // Cut at the one boundary every filer's answer goes through, and truncated rather than
                    // refused: a long line is still what happened. Narrative is cut on the same terms as text:
                    // `MemoryFiler` is public, so a third-party filer's narrative may not be the one field
                    // that lands unbounded.
                    let text = String(memory.text.prefix(AmbientMemory.maxTextCharacters))
                    guard !text.isEmpty else { continue }
                    let kind = AmbientMemory.filedKind(memory.kind)
                    let narrative = memory.narrative.map {
                        String($0.prefix(AmbientMemory.maxTextCharacters))
                    }
                    // An empty list is spelled `nil`: the engine refuses an empty array for a `[String!]`
                    // variable (`variable $concepts: String does not take tag 85`), and a memory with no
                    // concepts is a memory with none.
                    let concepts = memory.concepts.isEmpty ? nil : memory.concepts
                    if let slug = batch.slug {
                        _ = try await tx.mutate(
                            RecordMemoryForSessionMutation(
                                .init(
                                    kind: kind, origin: .ambient, text: text, narrative: narrative,
                                    concepts: concepts, slug: slug,
                                    memorySessionId: batch.session)))
                    } else {
                        _ = try await tx.mutate(
                            RecordMemoryUnboundMutation(
                                .init(
                                    kind: kind, origin: .ambient, text: text, narrative: narrative,
                                    concepts: concepts, memorySessionId: batch.session)))
                    }
                    wrote += 1
                }
                return wrote
            }
        }
    }

    /// One session's slice of a drain's batch: the events the filer is asked about, and where what it offers may
    /// bind. Grouped by session because a memory binds to the session it came from and `DetectedMemory` names
    /// none — one session in the queue, the ordinary case, is therefore one filer call, and two sessions cannot
    /// have each other's memories filed against them.
    private struct SessionBatch {
        let session: String
        let slug: String?
        let events: [DetectedEvent]
    }

    /// The queue as the producer sees it: the rows this drain is about to consume, read with the same bound and
    /// in the same order, and grouped by session.
    ///
    /// A session the store holds no project for files unbound rather than being skipped: the events are still
    /// what happened. An event whose session is not in the store has nothing to bind to at all, and a memory
    /// may not be filed against a session that does not exist.
    private func filableBatch() async throws -> [SessionBatch] {
        let rows = try await db.query(UndrainedEventsQuery(.init(first: ProposalCurator.defaultBatch))).events
        var order: [String] = []
        var groups: [String: [DetectedEvent]] = [:]
        var slugs: [String: String] = [:]
        for row in rows {
            guard let session = row.session?.memorySessionId else { continue }
            if groups[session] == nil { order.append(session) }
            if let slug = row.session?.project?.slug { slugs[session] = slug }
            groups[session, default: []].append(
                DetectedEvent(
                    id: row.id, kind: row.kind, text: row.text, tool: row.tool, target: row.target, at: row.at,
                    utterance: nil))
        }
        return order.map { SessionBatch(session: $0, slug: slugs[$0], events: groups[$0] ?? []) }
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
