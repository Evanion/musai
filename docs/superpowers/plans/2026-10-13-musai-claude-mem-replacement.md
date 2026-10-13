# The memory slice, first milestone: replace claude-mem — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** an agent working in Musai has memory that outlives its context window — captured locally, held in the graph, handed back at the start of the next task — and a person already using claude-mem installs Musai, imports the history they have, and switches.

**Architecture:** one reader per source, all feeding the same filing step. This milestone builds the claude-mem reader and the local producer. The reader reads claude-mem's SQLite **read-only** and, through the existing filing operations, writes Musai's own objects — sessions, evidence, projects and ideas discovered from the corpus, and one-sided decisions filed as proposals in their own state. The producer is the curator's second output: ambient memory from the event stream the hooks already capture. The repository reader and the notes reader come after, on the same rails.

**Tech Stack:** Swift 6.1 tools, macOS 14+ arm64, Swift Testing, NorvoLite on Norvo Lite, `sqlite3` (the system library) for reading claude-mem, `Network.framework` and `URLSession` for the endpoint and its clients.

**Spec:** `docs/superpowers/specs/2026-10-13-musai-claude-mem-replacement-design.md` — read it with this. It argues from `2026-10-12-musai-design.md` (§6 the model, §9 authored-vs-ambient) and `2026-10-12-musai-decision-loop-design.md` (§7 the loop, §8 which this implements).

## Global Constraints

- macOS, Apple Silicon only (`.macOS(.v14)`); Swift 6.1 tools; NorvoLite as the only store.
- **Exactly one process opens the Musai store: the agent.** No fallback lets a client open it. The import is the agent's work, requested over the endpoint.
- **claude-mem's database is opened read-only and never written**, so the import cannot damage what it reads and is always safe to re-run.
- `MusaiCore` knows nothing about Claude Code. The claude-mem SQL lives in one file; the reader's output is source-neutral.
- The protocol version is `major.minor`; additions this milestone are **minor** (still `1.0`).
- The agent idles at essentially no CPU: no timer unless there is an undrained event.
- The person's words are stored verbatim; agent words and tool output are references, never output.
- `Sources/MusaiCore/schema.nql` must equal the **last** file in `Sources/MusaiCore/migrations/`; `norvo check` fails the build otherwise. A schema change is a new numbered migration snapshot plus the same edit to `schema.nql`.
- Every `swift` command needs `MUSAI_NORVO_PATH=/Volumes/projects/Personal/norvo-swift NORVO_LOCAL=1`. **`norvo` is not on `PATH`**: invoke the engine's local build directly, `/Volumes/projects/Personal/norvo-swift/Artifacts/norvo.artifactbundle/norvo-macos/bin/norvo check Sources/MusaiCore`, and note it needs no `NORVO_LOCAL`.
- A task's **Files** list is the minimum, not a cap. If a task genuinely needs something it does not name — an operation a project-less write requires, a migration, or a second test file the suite needs updated — add it, commit it, and say so in the report. Two of the first four tasks had to (Task 1 a second migration-list assertion, Task 4 a project-less idea write), and in both cases following the brief's `git add` literally would have committed a red suite or a non-compiling branch.
- **A revert does not revert the generated code.** `NorvoCodegen` writes `Norvo.generated.swift` under `.build/plugins/outputs/…`, and it survives a `git checkout` or a removed file — so after an aborted attempt or a revert, `rm -rf .build` (or delete that file) before trusting a red-first run, or the run can come up green from symbols that no longer exist in the sources.

## Review Focus

The five conditions the spec implies but no task's tests otherwise exercise. Each is pinned by the test named beside it, in the task that owns the code.

1. **The first run happens against an empty store.** Installing Musai leads straight into importing, so on a fresh machine *nothing* exists to bind to and the import is what creates the graph's entry points — projects from working trees that still resolve, ideas from threads that never were a repository, and nothing at all from a filing bucket. → Task 4.
2. **CM and Musai both saw the same conversation.** CM's `memory_session_id` never equals the host's session id (measured: 0 of 951), while live capture keys on the host's — so the import must upsert onto the row live capture made, or the transition writes every conversation twice. → Task 5.
3. **Most of the corpus has no project.** 838 of 956 importable sessions carry no `cwd` and hold most of the observations and prompts, so project-less memory must be written *and* reachable, or the import loses exactly what it exists to preserve. → Tasks 5 and 7.
4. **A third of the prompts are not the person.** 6 068 of 17 817 are `<task-notification>` hook payloads; some are 101 KB, some are two characters. Imported verbatim they poison the durable layer and the index `find` answers from. → Task 5.
5. **~6 900 migrated proposals must not bury live review.** The live list is `state eq PROPOSED, createdAt ASC, first 50`; migrated entries in that state would sit in front of every future live proposal. → Task 6.

---

## File Structure

**Schema and operations**
- `Sources/MusaiCore/migrations/0005_migrated_state.nql` — new snapshot: `DecisionState` gains `MIGRATED`. No data step (an enum append).
- `Sources/MusaiCore/migrations/0006_import_cursor.nql` — new snapshot: adds the `ImportCursor` type. No data step (a new type).
- `Sources/MusaiCore/schema.nql` — edited to equal `0006`.
- `Sources/MusaiCore/operations/memories.nql` — gains `RecordMemoryUnbound`, `MemoriesWithoutProject`.
- `Sources/MusaiCore/operations/sessions.nql` — gains `UpsertSessionUnbound`.
- `Sources/MusaiCore/operations/review.nql` — gains `RecordMigratedProposal`, `MigratedDecisionsQuery`.
- `Sources/MusaiCore/operations/import.nql` — new: `ImportCursorQuery`, `SetImportCursorMutation`.

**Reading claude-mem**
- `Sources/MusaiCore/ClaudeMemReader.swift` — opens the corpus read-only, runs the CM-specific SQL, returns source-neutral rows. One file, because CM is a source and `MusaiCore` is allowed to know a source's SQL as long as it knows nothing about a *host*.
- `Sources/MusaiCore/SourceRows.swift` — the neutral row types the reader returns (`SourceSession`, `SourceEvidence`, `SourcePrompt`, `SourceWorkState`).

**The import**
- `Sources/MusaiCore/ImportDiscovery.swift` — the three-way rule: a `cwd` that resolves to a git working tree is a project; a substantial label that never was one is an idea; a bucket is neither.
- `Sources/MusaiCore/MusaiImport.swift` — the driver: batches, cursors, sessions, evidence, prompts, work state, and the counts it reports.
- `Sources/MusaiCore/ImportReport.swift` — the report type the driver returns and the endpoint serves.

**The producer**
- `Sources/MusaiCore/MemoryFiler.swift` — `public protocol MemoryFiler` and `DetectedMemory`, mirroring `DecisionDetector`/`DetectedDecision`.
- `Sources/MusaiCore/ModelMemoryFiler.swift` — the local-model implementation, mirroring `ModelDecisionDetector`.

**Surfaces**
- `Sources/MusaiCore/EndpointWire.swift` — gains `MemoriesReply`, `MemorySummary`, `ImportReportReply`, `MigratedReply`.
- `Sources/MusaiCore/MusaiEndpoint.swift` — gains `GET /memories`, `GET /migrated`, `POST /admin/import`.
- `Sources/MusaiCore/MusaiClient.swift` — gains `memories(project:q:)`, `migrated()`, `importHistory(from:)`.
- `Sources/MusaiCore/MusaiSlice.swift` — the slice gains memories.
- `Sources/MusaiCore/CuratorController.swift` — calls the filer after a drain.
- `Sources/musai/MusaiHook.swift` — gains `import` and `recall` subcommands.
- `README.md` — the first-run flow.

---

### Task 1: The schema — `MIGRATED`, and the import cursor

**Files:**
- Create: `Sources/MusaiCore/migrations/0005_migrated_state.nql`, `Sources/MusaiCore/migrations/0006_import_cursor.nql`
- Create: `Sources/MusaiCore/operations/import.nql`
- Modify: `Sources/MusaiCore/schema.nql`
- Test: `Tests/MusaiCoreTests/SchemaTests.swift`

**Interfaces:**
- Produces: `DecisionState.MIGRATED` (appended last, prefix preserved); `ImportCursor { source: String! @unique, highWaterId: Int! }` — note that **`updatedAt` is built into every Norvo type and must not be declared**; the field the test reads is that built-in. Plus the cursor's own operations, `ImportCursorQuery($source!)` and `SetImportCursorMutation($source!, $highWaterId!)`, because the cursor is the one new thing here whose behaviour can be tested without the operations Task 2 adds.

- [ ] **Step 1: Write the failing test**

In `SchemaTests`, in the suite's existing style (a library from `MusaiLibrary.inMemory()`):

```swift
@Test func migratedIsAnAppendedEnumCase() async throws {
    // assert DecisionState.MIGRATED.rawValue == "MIGRATED" (the append preserves the prefix the engine requires)
}
@Test func theImportCursorRoundTrips() async throws {
    // ImportCursorQuery returns nil for an unknown source
    // SetImportCursorMutation(source: "observations", highWaterId: 42, updatedAt: now)
    // ImportCursorQuery returns highWaterId 42, and setting it again moves it rather than adding a row
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `MUSAI_NORVO_PATH=/Volumes/projects/Personal/norvo-swift NORVO_LOCAL=1 swift test --filter SchemaTests`
Expected: FAIL — `ImportCursorQuery` / `SetImportCursorMutation` not in scope.

- [ ] **Step 3: Write the migrations and `schema.nql`**

`0005_migrated_state.nql` is a copy of `0004_event_expiry.nql` with `enum DecisionState { PROPOSED SETTLED PERSISTED MIGRATED }`, and `0006_import_cursor.nql` is a copy of `0005` plus the `ImportCursor` type. Then `schema.nql` becomes identical to `0006`. `operations/import.nql` is new and carries only the cursor's two operations, in `MemoryByProvenance`'s style.

Three things about the migrations that are easy to get wrong:

- **Each migration's `#` header describes its own change**, and is never a copy of the previous migration's header — `0004`'s header talks about the queue's retention and `Decision.origin`, and it is now history, so it does not belong in `0005` or `0006`. `0005`'s header says why `MIGRATED` exists (the import files one-sided entries as proposals that must not enter the live pending list, and no filter can do it because NorvoQL string filters have no prefix match); `0006`'s says why a cursor exists (a watermark, because `drop` deletes a proposal's row *and* its origin, so a resumed import would otherwise resurrect everything already dropped).
- **`ImportCursor` declares only `source` and `highWaterId`.** `updatedAt` is built into every Norvo type; declaring it is an error.
- **The existing test `theGraphMigratesAndIntrospects` asserts the migration list exactly** (`NorvoSchema.migrations.map(\.name) == ["0001_init", …, "0004_event_expiry"]`), so it must gain `"0005_migrated_state", "0006_import_cursor"` or the suite fails. Update it in this task.
- **Appending the enum makes `norvo check` reject the carried `@convert`** — it validates the annotation's `from` against the *previous* snapshot, so `Decision.state` reports ``was `DecisionState!`, not `DecisionState` ``. The remedy is to **re-spell the from-type to the identity**, `@convert(from: "DecisionState!")`, in `0005`, `0006` and `schema.nql`. That identity spelling is **load-bearing and must not be "corrected"** while the engine behaves this way: it is what keeps the *next* append from breaking, and a reader who tidies it back will break the following migration with an error naming an unrelated file. Dropping the annotation also clears the check today, and is more fragile. **The engine's owners have confirmed this as a bug** (filed on `NorvoDB/database`, and confirmed being worked on), so this is a workaround with an end: once that fix has landed, the identity spelling can be corrected back — re-run `norvo check` when you do, and update `0005`'s header with it.

- [ ] **Step 4: Run `norvo check` and the tests**

Run: `/Volumes/projects/Personal/norvo-swift/Artifacts/norvo.artifactbundle/norvo-macos/bin/norvo check Sources/MusaiCore` then `swift test --filter SchemaTests`
Expected: check passes; PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MusaiCore/migrations Sources/MusaiCore/schema.nql Sources/MusaiCore/operations/import.nql Tests/MusaiCoreTests/SchemaTests.swift
git commit -m "feat: migrated decisions have their own state, and the import keeps a cursor"
```

---

### Task 2: The operations the import needs

**Files:**
- Modify: `Sources/MusaiCore/operations/memories.nql`, `operations/sessions.nql`, `operations/review.nql`
- Test: `Tests/MusaiCoreTests/ImportOperationsTests.swift`

**Interfaces:**
- Consumes: Task 1's `MIGRATED`.
- Produces: **twins, not one operation** — the engine refuses a mutation whose input branches (`$slug` must be non-null in a oneOf input), so each case is a bound and an unbound form: `RecordMemoryForSession($kind!, $origin!, $text, $narrative, $concepts, $provenance, $slug!, $memorySessionId!)` and `RecordMemoryUnbound($kind!, $origin!, $text, $narrative, $concepts, $provenance, $memorySessionId!)`; `UpsertSessionUnbound($memorySessionId!, $platform!, $cwd, $title, $status = ACTIVE, $startedAt!)`; `RecordMigratedProposal($title!, $rationale, $act!, $origin!, $slug!)` and `RecordMigratedProposalUnbound($title!, $rationale, $act!, $origin!)`; `MigratedDecisionsQuery($first: Int = 50)`; and `MemoriesWithoutProject($first: Int = 200)`, which filters `project: null` — `ProjectWhere` has no `eq`. Both memory twins take a **non-null** `$memorySessionId`, because the session connect is also a oneOf member. Also produced, and load-bearing for Task 6: `DecisionBits.origin` and `SessionBits.project { slug }`. (`ImportCursorQuery`/`SetImportCursorMutation` are Task 1's.)

- [ ] **Step 1: Write the failing test**

```swift
@Test func aMemoryWithNoProjectIsWrittenAndBoundToItsSession() async throws {
    // RecordMemoryForSession with $slug nil and a real $memorySessionId
    // -> MemoryByProvenance finds it, its project is nil, MemoriesWithoutProject contains it, its session is set
}
@Test func aMemoryWithAProjectBinds() async throws {
    // RecordMemoryForSession with a real slug -> the memory's project is that slug
}
@Test func aMigratedProposalIsInItsOwnQueryOnly() async throws {
    // RecordMigratedProposal -> absent from PendingDecisions, present in MigratedDecisionsQuery, bound when given a slug
}
@Test func anUnboundSessionIsWritten() async throws {
    // UpsertSessionUnbound -> SessionByMemoryId finds it, project nil
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter ImportOperationsTests`
Expected: FAIL — the mutations are not in scope.

- [ ] **Step 3: Write the operations**

Follow `operations/memories.nql`'s existing style. `RecordMemoryForSession` is `RecordMemory` with a session connect and a required `$slug`; `RecordMemoryUnbound` is the same with the project connect removed. `RecordMigratedProposal` is `RecordProposal` with `state: MIGRATED` set explicitly, the `$utterance` input dropped and a required `$slug`; `RecordMigratedProposalUnbound` drops the project too. Add `origin` to `DecisionBits` and `project { slug }` to `SessionBits`, since Task 6 asserts the first and only the second can show a session is unbound. (`ImportCursorQuery`/`SetImportCursorMutation` are Task 1's and already exist — do not touch them.)

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --filter ImportOperationsTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MusaiCore/operations Tests/MusaiCoreTests/ImportOperationsTests.swift
git commit -m "feat: the operations an import needs — unbound memory and sessions, and migrated proposals"
```

---

### Task 3: Reading claude-mem

**Files:**
- Create: `Sources/MusaiCore/SourceRows.swift`, `Sources/MusaiCore/ClaudeMemReader.swift`
- Test: `Tests/MusaiCoreTests/ClaudeMemReaderTests.swift`

**Interfaces:**
- Produces: `public struct SourceSession { memorySessionId: String; hostSessionId: String; platform: String; cwd: String?; title: String?; status: SessionStatus; startedAt: Date; endedAt: Date?; projectLabel: String }`; `public struct SourceEvidence { id: Int; kind: MemoryKind; text: String; narrative: String?; concepts: [String]; provenance: String; hostSessionId: String }`; `public struct SourcePrompt { id: Int; hostSessionId: String; text: String; at: Date }`; `public struct SourceWorkState { id: Int; projectLabel: String; listName: String; fields: String }`; and
  `public struct ClaudeMemReader: Sendable { init(url: URL) throws; func sessions(limit: Int, after: Int) throws -> [SourceSession]; func evidence(limit: Int, after: Int) throws -> [SourceEvidence]; func prompts(limit: Int, after: Int) throws -> [SourcePrompt]; func workState() throws -> [SourceWorkState] }`

- [ ] **Step 1: Write the failing test**

The test **builds its own tiny corpus** — never the person's 1 GB database. It creates a temp SQLite with just the columns the reader uses (`observations(id, memory_session_id, project, text, type, title, facts, narrative, concepts, created_at_epoch)`, `sdk_sessions(memory_session_id, content_session_id, platform_source, project, custom_title, started_at_epoch, completed_at_epoch, status, cwd)`, `session_summaries`, `work_state_entries`, `user_prompts`) and inserts rows that pin the mapping:

```swift
@Test func evidenceTextIsComposedBecauseTheColumnIsEmpty() async throws {
    // insert an observation with text = NULL, title = "A title", facts = #"["f1","f2"]"#
    // assert reader.evidence(...)[0].text == "A title\n- f1\n- f2"
}
@Test func theHostSessionIdIsNotTheMemorySessionId() async throws {
    // insert a session with content_session_id = "host-1", memory_session_id = "cm-1"
    // assert SourceSession.hostSessionId == "host-1"
}
@Test func theReaderOpensTheCorpusReadOnly() async throws {
    // assert a reader on a read-only-mounted copy reads; assert a write through the reader's connection throws
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter ClaudeMemReaderTests`
Expected: FAIL — `cannot find 'ClaudeMemReader' in scope`.

- [ ] **Step 3: Write the two files**

Open with `sqlite3_open_v2` on `SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX` (the corpus is WAL, so a reader coexists with CM's live writer). Compose `text` as `title` plus each `facts` entry on its own `- ` line, dropping empties, and fall back to `narrative` when `title` and `facts` are both absent — 27 untitled and 30 factless rows measured, and 26 rows have none of the three, which are skipped and counted by the caller. Map the corpus's 20 `type` values to `MemoryKind` with a lookup table and `FACT` as the default, and keep the raw type as a `type:<raw>` concept. Cap composed text with `MusaiCapture.truncated(_:to: MusaiCapture.maxTextBytes)`.

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --filter ClaudeMemReaderTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MusaiCore/SourceRows.swift Sources/MusaiCore/ClaudeMemReader.swift Tests/MusaiCoreTests/ClaudeMemReaderTests.swift
git commit -m "feat: read claude-mem read-only, and compose its evidence"
```

---

### Task 4: Discovery — projects, ideas, and buckets

**Files:**
- Create: `Sources/MusaiCore/ImportDiscovery.swift`
- Test: `Tests/MusaiCoreTests/ImportDiscoveryTests.swift`

**Interfaces:**
- Consumes: `ProjectBinder.gitRemote(for:)`, `ProjectBinder.slugBase(_:)`, `operations/projects.nql`, `operations/ideas.nql`.
- Produces: `public struct ImportDiscovery: Sendable { init(db: Database, fileManager: FileManager = .default); func discover(from sessions: [SourceSession], evidence: [SourceEvidence]) async throws -> DiscoveryOutcome }` and `public struct DiscoveryOutcome { projects: [String]; ideas: [String]; buckets: [String]; unboundSessions: Int }`

- [ ] **Step 1: Write the failing test**

On an in-memory library, with temp directories created by the test:

```swift
@Test func aCwdThatIsAWorkingTreeBecomesAProject() async throws {
    // make a temp dir with a .git/config carrying [remote "origin"] url
    // discover(from: [a SourceSession whose cwd is that dir]) -> projects contains the repo's slug, bound in the store
}
@Test func aLabelWithNoWorkingTreeBecomesAnIdea() async throws {
    // discover(from: [sessions labelled "some-thread", whose cwds do not exist]) -> ideas contains "some-thread"; no Project exists for it
}
@Test func aBucketBecomesNeither() async throws {
    // discover(...) with the label "open-source" -> buckets contains it; no Project and no Idea
}
@Test func theHomeDirectoryIsNotAWorkingTree() async throws {
    // a SourceSession whose cwd is NSHomeDirectory() -> neither project nor idea; counted unbound
}
@Test func discoveryIsIdempotent() async throws {
    // run twice -> the same project count, no duplicate ideas
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter ImportDiscoveryTests`
Expected: FAIL — `cannot find 'ImportDiscovery' in scope`.

- [ ] **Step 3: Write the file**

A session's `cwd` that resolves to a directory containing `.git` (via `ProjectBinder.gitRemote(for:)`) is a project, discovered with the binder's own slug rule so a live capture of the same repo agrees. `$HOME` exactly, and any path whose file does not exist, is not. A label that is neither a discovered project nor one that already exists in the store becomes an idea — unless it is a **bucket**. A bucket is decided by a named constant, `ImportDiscovery.bucketLabels`, a case-insensitive set seeded with the one measured value, `["open-source"]`, and extended as the corpus teaches more: the corpus's junk labels cannot be inferred, and a heuristic that guessed at them would silently discard real projects. An unknown label becomes an idea, which the person can drop. Discovery writes only through the existing operations and is idempotent by slug and title.

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --filter ImportDiscoveryTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MusaiCore/ImportDiscovery.swift Tests/MusaiCoreTests/ImportDiscoveryTests.swift
git commit -m "feat: the first run discovers projects from working trees and ideas from what never was one"
```

---

### Task 5: The import driver

**Files:**
- Create: `Sources/MusaiCore/ImportReport.swift`, `Sources/MusaiCore/MusaiImport.swift`
- Test: `Tests/MusaiCoreTests/ImportTests.swift`

**Interfaces:**
- Consumes: Tasks 3 and 4, and `MusaiCapture.maxTextBytes`.
- Produces: `public struct MusaiImport: Sendable { init(db: Database, reader: ClaudeMemReader, discovery: ImportDiscovery, batch: Int = 500, as actor: Actor); func run(dryRun: Bool = false) async throws -> ImportReport }`; `public struct ImportReport: Sendable, Equatable, Codable { dryRun: Bool; sessions: Int; evidence: Int; prompts: Int; workStates: Int; proposals: Int; projects: [String]; ideas: [String]; buckets: [String]; unbound: Int; machinePrompts: Int; skipped: Int }`

  `dryRun` is how a person sees what was discovered **before it is kept**, which the spec requires of the first run: it reads and reports, and writes nothing at all — no sessions, no evidence, no projects, no cursor.

- [ ] **Step 1: Write the failing test**

Against a temp corpus made by the test:

```swift
@Test func theImportWritesTheHistoryItReads() async throws {
    // a corpus with 1 session, 2 observations, 3 prompts, 1 work state
    // after run(): the Session exists, both memories exist with .MIGRATED and their provenance, the prompts exist as utterances
}
@Test func anImportNeverWritesTheSameRowTwice() async throws {
    // run() twice -> the counts of the second run are all zero and the store's row counts are unchanged
}
@Test func aConversationBothToolsSawIsOneSession() async throws {
    // pre-bind a session with the host's session id via ProjectBinder; import a corpus row with that content_session_id and a different memory_session_id
    // assert exactly one Session exists, and it is project-bound
}
@Test func machinePromptsAreDroppedAndCounted() async throws {
    // a corpus with one real prompt and one "<task-notification>..." payload, plus one two-character prompt
    // assert one utterance, machinePrompts == 1 (the payload), skipped covers the two-character one
}
@Test func aSessionWithNoProjectIsStillImported() async throws {
    // a corpus whose session has no cwd -> the Session exists unbound, its memories exist with no project, MemoriesWithoutProject finds them
}
@Test func anInterruptedImportResumesAtItsCursor() async throws {
    // run with batch: 1 against a 3-row corpus, then run again -> the second run imports exactly the remainder
}
@Test func aDryRunReportsEverythingAndWritesNothing() async throws {
    // dryRun: true against a corpus -> the report's counts match a real run's, and every store row count is unchanged (no session, no memory, no project, no cursor)
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter "ImportTests"`
Expected: FAIL — `cannot find 'MusaiImport' in scope`.

- [ ] **Step 3: Write the two files**

Order: sessions first (evidence and prompts need one), then evidence, then prompts, then work state, then proposals (Task 6). Each stage is batched and commits a batch at a time, and the cursor (`ImportCursorQuery`/`SetImportCursorMutation`, one per source stage) advances only past rows that were written or deliberately skipped — the two-character prompts are skipped *after* the cursor has passed them, which is what makes the drop-then-rerun case hold. A session binds to the project discovery found for its `cwd`, and **every write branches on whether it did**: a session or an evidence row whose project is known goes through the bound operation (`RecordMemoryForSession`, `RecordMigratedProposal`), and one with no project through its `…Unbound` twin, so unbound evidence lands unbound rather than being skipped. Forgetting the branch is a compile error — the bound operations require a slug — not a silent mis-bind. Sessions upsert on the **host** session id (`SourceSession.hostSessionId`), because that is what live capture writes; the field is `memorySessionId` and its name is a later rename. Prompts become utterances with `Speaker.USER` through `operations/capture.nql`'s existing utterance write, truncated with `MusaiCapture.truncated(_:to:)`. The one corpus quirk to respect: `memory_session_id` is not unique-to-us, and the 262 sessions with none are still importable because `content_session_id` is not null.

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --filter ImportTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MusaiCore/ImportReport.swift Sources/MusaiCore/MusaiImport.swift Tests/MusaiCoreTests/ImportTests.swift
git commit -m "feat: the import — sessions, evidence, prompts, work state, and a cursor that survives a crash"
```

---

### Task 6: Migrated proposals

**Files:**
- Modify: `Sources/MusaiCore/MusaiImport.swift`
- Test: `Tests/MusaiCoreTests/ImportProposalTests.swift`

**Interfaces:**
- Consumes: Task 2's `RecordMigratedProposal` and `RecordMigratedProposalUnbound` and `MigratedDecisionsQuery`.
- Produces: nothing new — the proposals are rows, and `ImportReport.proposals` counts them.

- [ ] **Step 1: Write the failing test**

```swift
@Test func oneSidedDecisionsBecomeMigratedProposals() async throws {
    // a corpus with 2 decision-typed observations and a summary with next_steps
    // assert MigratedDecisionsQuery returns them, each with origin "claude-mem:observation:<id>"
}
@Test func liveReviewIsNeverBuried() async throws {
    // with 200 migrated proposals present, PendingDecisions still returns only the live PROPOSED ones
}
@Test func aMigratedProposalIsSettledByTheSameAct() async throws {
    // ReviewSession.apply(.settle, to:) on a migrated proposal -> it is SETTLED, absent from MigratedDecisions
}
@Test func evidenceIsNotProposedAndAProposalIsNotEvidence() async throws {
    // a discovery-typed observation -> one Memory, no proposal; a decision-typed one -> a proposal, and a Memory too
}
@Test func droppingAMigratedProposalIsNotUndoneByARerun() async throws {
    // (moved here from Task 5, which cannot write a proposal to drop) import, drop one migrated proposal, import again -> it is not re-proposed
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter ImportProposalTests`
Expected: FAIL — no migrated proposals are written.

- [ ] **Step 3: Add the stage**

Fold it into `MusaiImport.run()` after evidence, with **its own cursors — two, not one**, because it reads two tables with unrelated id spaces (`claude-mem:proposals` over the observations and `claude-mem:summary_proposals` over the summaries); a shared watermark would read nothing. It needs a reader accessor for the summaries, since Task 3's reader reads `observations` only.

**A summary is two things, and both are required.** The design's §4 mapping sends `session_summaries` (4 922 rows) to a `Memory { origin: .MIGRATED }` **as well as** to a proposal, so the stage files one `Memory` per summary — composed from its five labelled prose columns, `provenance: "claude-mem:summary:<id>"`, counted in the report's `evidence` — and, when the summary carries `next_steps`, proposes that as the one side of a choice nobody confirmed. Missing the first half drops ~4 900 rows of the corpus's distilled narrative from the graph, which is exactly what this milestone exists to prevent; the plan originally said only "the `next_steps` of summaries", and that omission was a real hole.

Selection is a rule, never a model call, because ~7 000 candidates through the local model is hours of idle-window work for a one-shot import, and the correction signal survives anyway: confirming or dropping a migrated proposal is the same act as a live one. `title` from the observation's `title` (or the first line of `next_steps`), `act` from the corpus's type via a small table defaulting to `.DECISION`, `origin` = `claude-mem:observation:<id>`, and the project from the observation's session when it has one — through `RecordMigratedProposal`, or its `…Unbound` twin when the session is unbound. **Truncate the title at the write boundary** to `ProposalCurator.maxTitleCharacters` (200) — the cap the live surface already enforces by *rejecting* over-long titles — and truncate rather than reject, because history may not be refused. Never write a migrated proposal for an observation whose kind is not decision-ish.

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --filter ImportProposalTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MusaiCore/MusaiImport.swift Tests/MusaiCoreTests/ImportProposalTests.swift
git commit -m "feat: one-sided decisions arrive as migrated proposals, and never in the live review list"
```

---

### Task 7: The surfaces — the import, find, and the migration view

**Files:**
- Modify: `Sources/MusaiCore/EndpointWire.swift`, `MusaiEndpoint.swift`, `MusaiClient.swift`
- Test: `Tests/MusaiCoreTests/MemoryEndpointTests.swift`, `Tests/MusaiCoreTests/ClientTests.swift`

**Interfaces:**
- Consumes: `MemoriesForProject`, `MemoriesWithoutProject`, `SearchMemories`, `MigratedDecisionsQuery`, `ImportReport`.
- Produces: `GET /memories?project=&q=` → `MemoriesReply { memories: [MemorySummary] }` where `MemorySummary { id: UUID; text: String?; kind: MemoryKind; origin: MemoryOrigin; provenance: String?; project: String? }`; `GET /migrated` → `MigratedReply { proposals: [MigratedProposal] }` where `MigratedProposal { id: UUID; title: String; act: ActKind; origin: String }` (a distinct type from `Proposal`, which carries `said` that a migrated entry has not got); `POST /admin/import` with `{ "source": String, "dryRun": Bool? }` → `ImportReportReply { report: ImportReport }`; `MusaiClient.memories(project:q:)`, `.migrated()`, `.importHistory(from: URL, dryRun: Bool = false)`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func memoriesAreFoundByTextWithNoProject() async throws {
    // a store with a project-less migrated memory; GET /memories?q=<a word in it> -> it comes back
}
@Test func memoriesForAProjectComeBack() async throws { /* GET /memories?project=<slug> */ }
@Test func anEmptySearchIsEmptyNotAnError() async throws { /* 200 with an empty list */ }
@Test func theMigrationViewIsSeparateFromTheReviewList() async throws {
    // GET /proposals carries pending only; GET /migrated carries the migrated ones
}
@Test func theImportIsRequestedThroughTheEndpoint() async throws {
    // POST /admin/import with a temp corpus path -> the report's counts; a second request imports nothing
}
@Test func theImportIsRefusedWhenItWouldBeASecondOpener() async throws {
    // the route runs against the agent's own store; assert it never opens a second Database
}
@Test func aDryRunImportWritesNothing() async throws {
    // POST /admin/import with dryRun true -> the reply's report.dryRun is true and the store's row counts are unchanged
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter "MemoryEndpointTests|ClientTests"`
Expected: FAIL — 404 from the new paths.

- [ ] **Step 3: Write the routes and the client methods**

A new route goes through the same two gates as every storeless-aware route: the token check first, then the store guard (503 when there is no store). `/memories` with a `q` uses `SearchMemories(q:k:first:)`; with a `project` and no `q`, `MemoriesForProject`; with neither, `MemoriesWithoutProject`. Add `MusaiClient` methods in the shape of the existing `proposals()`/`gap()`, and keep the additions inside `protocolVersion` `1.0` — they are minor.

**`POST /admin/import` runs exactly one pass** — one batch per stage, as `MusaiImport.run()` defines it — and returns that pass's report. It must **not** loop to exhaustion: the endpoint serves one request at a time, so a request that imported a whole 1 GB corpus would hold that slot and block every capture for as long as it ran. One pass per request is what keeps the import short, resumable and idle-friendly; the CLI repeats until a pass reports nothing left (Task 10).

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --filter "MemoryEndpointTests|ClientTests"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MusaiCore/EndpointWire.swift Sources/MusaiCore/MusaiEndpoint.swift Sources/MusaiCore/MusaiClient.swift Tests/MusaiCoreTests
git commit -m "feat: memory is findable, the migration has its own view, and the import is one request"
```

---

### Task 8: The producer — the curator files ambient memory

**Files:**
- Create: `Sources/MusaiCore/MemoryFiler.swift`, `Sources/MusaiCore/ModelMemoryFiler.swift`
- Modify: `Sources/MusaiCore/CuratorController.swift`
- Test: `Tests/MusaiCoreTests/MemoryFilerTests.swift`, `Tests/MusaiCoreTests/CuratorControllerTests.swift`

**Interfaces:**
- Consumes: `DetectedEvent` (`DecisionDetector.swift:5`), `CuratorController.performDrain`, `RecordMemory`/`RecordMemoryUnbound`.
- Produces: `public struct DetectedMemory: Sendable, Equatable { kind: MemoryKind; text: String; narrative: String?; concepts: [String] }`; `public protocol MemoryFiler: Sendable { func file(from events: [DetectedEvent]) async throws -> [DetectedMemory] }`; `public struct ModelMemoryFiler: MemoryFiler { init(configuration: ModelConfiguration) }`; `CuratorController.init(... filer: (any MemoryFiler)? = nil ...)`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func aDrainFilesAmbientMemory() async throws {
    // a stub filer returning one DetectedMemory; capture a turn, noteCapture, drainNow
    // assert one Memory with origin .AMBIENT, bound to the project and session of the event
}
@Test func theProducerNeverMintsADecision() async throws {
    // a stub filer whose DetectedMemory.kind is .DECISION -> assert it is written as .AMBIENT memory and no Decision row exists
}
@Test func theProducerNeverWritesAuthored() async throws { /* assert no Memory has origin .AUTHORED */ }
@Test func aFilerThatThrowsLeavesTheDrainIntact() async throws {
    // a filer that throws -> the proposals from the same drain are still written, and curatorState returns to .idle
}
@Test func theProducerIsBoundedPerDrain() async throws {
    // a stub filer offering 50 memories -> at most the bound are written (the bound is a named constant)
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter "MemoryFilerTests|CuratorControllerTests"`
Expected: FAIL — `cannot find 'MemoryFiler' in scope`.

- [ ] **Step 3: Write the files and wire the controller**

`ModelMemoryFiler` mirrors `ModelDecisionDetector`: the same provider, a prompt that asks for **few and confident** memories (at most `maxPerDrain = 3`, each at most `maxTextCharacters = 600`), and a hard rule that the returned `kind` may only be `FACT` or `LESSON` — anything else is coerced or dropped, which is what makes the anti-goal testable rather than aspirational. The controller calls the filer once per `performDrain`, outside the proposal transaction, in its own transaction, and a filer failure is caught and noted so the drain's decisions are not lost. `CuratorState` gains no new cases; the filer runs inside `.draining`.

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --filter "MemoryFilerTests|CuratorControllerTests"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MusaiCore/MemoryFiler.swift Sources/MusaiCore/ModelMemoryFiler.swift Sources/MusaiCore/CuratorController.swift Tests/MusaiCoreTests
git commit -m "feat: the curator files ambient memory — the metered observer, replaced locally"
```

---

### Task 9: Hand it back — the slice gains memory

**Files:**
- Modify: `Sources/MusaiCore/MusaiSlice.swift`
- Test: `Tests/MusaiCoreTests/SliceTests.swift`

**Interfaces:**
- Consumes: `MemoriesForProject`, the existing `reserve` and budget loop.
- Produces: `MusaiSlice.render` keeps its signature — `render(project:budget:db:)` — and its output gains memory lines.

- [ ] **Step 1: Write the failing test**

```swift
@Test func theSliceCarriesTheProjectsMemory() async throws {
    // a settled decision and a migrated memory for one project; render -> the memory's first line appears, and it is inside the budget
}
@Test func theSliceStillStaysInsideItsBudget() async throws {
    // 200 long memories -> the rendered slice is <= budget, and ends with "(+N more)"
}
@Test func aProjectWithNoMemoriesRendersAsBefore() async throws { /* byte-identical to the pre-change output for the same store */ }
@Test func aMemoryWithNoProjectIsNotInAProjectsSlice() async throws { /* project-less memory does not leak into a project's slice */ }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter SliceTests`
Expected: FAIL — the memory's line is absent.

- [ ] **Step 3: Add memories to the selection**

After the settled decisions and before the `(+N more)` line, render the project's memories newest-first by the session's `startedAt` (not `Memory.createdAt`, which for a migrated row is the import moment), one line each, under the same budget arithmetic — the `reserve` is what keeps the "there is more" line inside the budget, and it already exists.

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --filter SliceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/MusaiCore/MusaiSlice.swift Tests/MusaiCoreTests/SliceTests.swift
git commit -m "feat: the handover slice carries the project's memory"
```

---

### Task 10: The CLI, and the first-run flow in the README

**Files:**
- Modify: `Sources/musai/MusaiHook.swift`, `README.md`
- Test: `Tests/MusaiCoreTests/CLITests.swift`

**Interfaces:**
- Consumes: Task 7's `MusaiClient.importHistory(from:)`, `.memories(project:q:)`, `.migrated()`, and the existing `connectedClient()`.
- Produces: `musai import [--from <path>] [--dry-run]` (default `~/.claude-mem/claude-mem.db`), `musai recall [--project <slug>] <words…>`, `musai review --migrated`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func importNeedsARunningBackendAndSaysSo() async throws {
    // no record -> one diagnostic line on stderr naming `musai install`, exit 0
}
@Test func importPrintsTheReport() async throws {
    // a live in-process listener + a temp corpus -> stdout carries the counts
}
@Test func recallPrintsWhatItFound() async throws { /* a migrated memory, recall <a word> -> its text on stdout */ }
@Test func recallWithNothingFoundPrintsNothingAndExitsZero() async throws { /* empty stdout, exit 0 */ }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter CLITests`
Expected: FAIL — unknown subcommand.

- [ ] **Step 3: Write the subcommands and the README**

The subcommands are wiring: they reuse `connectedClient()` and print; every hook path still exits 0. **`musai import` repeats `run()` until a pass imports nothing left** — the endpoint runs one pass per request (Task 7), so the CLI is what drives a whole corpus through, printing the accumulated totals and saying plainly that it can be stopped and resumed. `README.md` gains the first-run flow — `musai install`, then `musai import` (and `musai import --dry-run` first, to see what would be discovered), then work, then `musai doctor`/`musai recall` — and says plainly that the import reads claude-mem only, never writes it, and can be run again.

- [ ] **Step 4: Run the whole suite**

Run: `swift test`
Expected: PASS, every suite.

- [ ] **Step 5: Commit**

```bash
git add Sources/musai/MusaiHook.swift README.md Tests/MusaiCoreTests/CLITests.swift
git commit -m "feat: musai import and musai recall — the first run, end to end"
```

---

## What this plan leaves

- **The other readers** — a repository's structure and history (graphify-like), a notes directory (Obsidian-like) — and the enrichment that reads the folders and branches the import's leads name. The leads are on the sessions this plan writes; walking them is the next plan.
- **An `Artifact` entity**, embeddings and vector search, the window app and viewer, `GET /events` and SSE, and the closed-loop dispatcher.
- **Renaming `Session.memorySessionId`.** It holds the host's session id now, and the rename is a schema change worth doing with a reason.
