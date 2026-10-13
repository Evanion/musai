import Foundation

/// One row of claude-mem's own history, as Musai reads it. These types are the reader's whole vocabulary:
/// nothing downstream has to know a claude-mem column name, and nothing here is a Musai graph type — a
/// source row is raw material, not a row.
///
/// The session-bearing rows carry two ids. `hostSessionId` is the host's session id — the one Musai's live
/// capture already writes, and the one a session is keyed on when it is imported; `memorySessionId` is
/// claude-mem's own. The two are distinct whenever claude-mem has both, but it leaves `memory_session_id`
/// null on many sessions, and the reader falls back to the host's id for those — so `memorySessionId` can
/// equal `hostSessionId`, and it is `hostSessionId` that always means the host. The field name
/// `memorySessionId` on Musai's own `Session` is a later rename, which is why the host's id is the one that
/// matters.

/// A session claude-mem recorded.
public struct SourceSession: Sendable, Equatable {
    /// The row's own `sdk_sessions.id` — what a stage's cursor is a watermark of. It defaults to zero for a
    /// row a test composes by hand; every row the reader returns carries the corpus's own id.
    public let id: Int
    /// The session's Musai-side key: claude-mem's id when it has one, the host's id when it does not.
    public let memorySessionId: String
    /// The host's session id — what live capture writes, and what an import keys on.
    public let hostSessionId: String
    public let platform: String
    public let cwd: String?
    public let title: String?
    public let status: SessionStatus
    public let startedAt: Date
    public let endedAt: Date?
    /// claude-mem's project label. It is a label, not a Musai project — discovery decides what it becomes.
    public let projectLabel: String

    public init(
        id: Int = 0, memorySessionId: String, hostSessionId: String, platform: String, cwd: String? = nil,
        title: String? = nil, status: SessionStatus, startedAt: Date, endedAt: Date? = nil,
        projectLabel: String
    ) {
        self.id = id
        self.memorySessionId = memorySessionId
        self.hostSessionId = hostSessionId
        self.platform = platform
        self.cwd = cwd
        self.title = title
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.projectLabel = projectLabel
    }
}

/// One observation, with its prose composed: claude-mem's `text` column is empty in every real row, so the
/// readable text is the title plus the facts, or the narrative when there is no title and no facts.
public struct SourceEvidence: Sendable, Equatable {
    public let id: Int
    public let kind: MemoryKind
    public let text: String
    public let narrative: String?
    /// claude-mem's concepts, with `type:<raw>` kept in front so the original classification survives even
    /// where the type→kind table is lossy.
    public let concepts: [String]
    /// Stable across runs: `claude-mem:observation:<id>`. This is what makes a re-run land on the same row.
    public let provenance: String
    public let hostSessionId: String

    public init(
        id: Int, kind: MemoryKind, text: String, narrative: String? = nil, concepts: [String],
        provenance: String, hostSessionId: String
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.narrative = narrative
        self.concepts = concepts
        self.provenance = provenance
        self.hostSessionId = hostSessionId
    }
}

/// One of claude-mem's session summaries, as far as the import needs it: the `next_steps` it left, which is
/// one side of a choice nobody confirmed. The other prose columns are evidence the evidence stage reads as
/// observations; this is the one field a proposal can be made of.
public struct SourceSummary: Sendable, Equatable {
    public let id: Int
    /// The host's session id — what a proposal made from this row connects through, exactly as an
    /// observation's does. claude-mem keys a summary on its own session id, and the reader falls back to it
    /// when no session row carries it.
    public let hostSessionId: String
    /// claude-mem's `next_steps`, verbatim. It is null or empty on many rows, and the caller skips and counts
    /// those rather than inventing a proposal from nothing.
    public let nextSteps: String?

    public init(id: Int, hostSessionId: String, nextSteps: String?) {
        self.id = id
        self.hostSessionId = hostSessionId
        self.nextSteps = nextSteps
    }
}

/// Something the person typed, as claude-mem recorded it. Whether it is a real prompt or a machine payload
/// is the import's judgement, not the reader's.
public struct SourcePrompt: Sendable, Equatable {
    public let id: Int
    public let hostSessionId: String
    public let text: String
    public let at: Date

    public init(id: Int, hostSessionId: String, text: String, at: Date) {
        self.id = id
        self.hostSessionId = hostSessionId
        self.text = text
        self.at = at
    }
}

/// A claude-mem work-state list. `fields` stays the raw JSON claude-mem wrote — the reader does not pretend
/// to know its shape.
public struct SourceWorkState: Sendable, Equatable {
    public let id: Int
    public let projectLabel: String
    public let listName: String
    public let fields: String

    public init(id: Int, projectLabel: String, listName: String, fields: String) {
        self.id = id
        self.projectLabel = projectLabel
        self.listName = listName
        self.fields = fields
    }
}
