# The decision loop, first slice — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the decision loop end to end and narrow: Claude Code hooks capture both sides of a session, a local model proposes decisions from them, one keystroke confirms them, and the next session starts with the settled decisions that constrain the work.

**Architecture:** `MusaiCore` gains the loop's model and its write path; a `musai` executable is the host seam (the hooks call it, and it is the only thing that opens the store per event). Detection sits behind a `DecisionDetector` protocol so the loop is testable without a model, with an Ollama implementation over loopback as the first real detector. The slice handed back at session start is a bounded, selected query over the graph.

**Tech Stack:** Swift 6.1 tools, macOS 14+ arm64, Swift Testing, NorvoLite Swift package on Norvo Lite, Ollama over `127.0.0.1:11434`.

**Specs:** `docs/superpowers/specs/2026-10-12-musai-decision-loop-design.md` (this plan's authority) and
`docs/superpowers/specs/2026-10-12-musai-design.md` (the app design it amends).

## Global Constraints

- Platform: macOS, Apple Silicon only (arm64); `.macOS(.v14)`.
- **Norvo Lite is the only store.** No SQLite, no files of our own besides the Norvo file.
- **Tool output is never captured.** A tool event records its tool, its target and a digest — never its result. Every captured event has a hard size cap (`MusaiCapture.maxTextBytes`, pinned at 64 KiB; over-cap text is truncated, never written whole).
- **The user's words are never rewritten.** The verbatim turn is an `Utterance`; anything a model writes about it is a separate object that *links* to it.
- **A hook must never break the host session.** Every hook path exits 0; on any error it writes a diagnostic to stderr and prints nothing on stdout. Only the session-start hook prints, and only the documented JSON.
- **Networking is limited to loopback Ollama** (`127.0.0.1:11434`), which §12 of the app design allows. No other network call.
- Local-first, host-agnostic: the core knows nothing about Claude Code; only the `hook` subcommand does.
- Curator model default: `qwen3.6:27b` (installed), overridable with `MUSAI_CURATOR_MODEL`.

## Review Focus

The five input classes most likely to bite a person using this, each pinned by a test in the task that owns
its code.

1. **A malformed or upgraded hook payload** (a field renamed by a host update, a missing `session_id`) — the
   session must continue, the hook exits 0 and prints nothing. → Task 3.
2. **A gigantic turn** (someone pastes a 10 MB file into the prompt) — it is capped, not written whole, and the
   store does not grow by megabytes. → Task 2, Task 3.
3. **A tool result that is code** — recorded as tool/target/digest only; the code never reaches the store. →
   Task 2, Task 3.
4. **The same hook firing twice** (`startup` then `compact`, a retry, a resumed session) — one row, not two;
   the same turn captured twice must be idempotent. → Task 2, Task 3.
5. **First run, empty store** — session start prints nothing and exits 0; review with nothing pending exits 0
   with an empty list; nothing crashes on a store with no projects. → Task 5, Task 8.

Also pinned where the code lives, though not in the list above: a detector that returns invalid JSON or a
hallucinated decision never becomes a `Decision` (Task 6, Task 7).

---

### Task 1: The loop's model

**Files:**
- Modify: `Sources/MusaiCore/schema.nql`
- Create: `Sources/MusaiCore/migrations/0002_loop.nql`
- Create: `Sources/MusaiCore/operations/capture.nql`
- Modify: `Sources/MusaiCore/operations/fragments.nql`
- Test: `Tests/MusaiCoreTests/LoopSchemaTests.swift`

**Interfaces:**
- Consumes: Task 1–9 of `2026-10-12-musai-data-model.md` — the existing schema, `MusaiLibrary`, `MusaiActors`.
- Produces: the schema types `Utterance`, `Event`, `Speaker`, `ActKind`, `EventKind`, `DecisionState`, and the
  new `Decision` fields; generated `UtteranceBits`, `EventBits`, `RecordUtteranceMutation`,
  `RecordEventMutation`, `UndrainedEventsQuery`, `MarkEventDrainedMutation`, `DecisionsForProjectQuery`,
  `PendingDecisionsQuery`, `SettleDecisionMutation`, `PersistDecisionInDocumentMutation`, `PersistDecisionOutsideMutation`.

`0002_loop.nql` is a **new** migration holding the complete SDL (Norvo migrations are append-only), so
`schema.nql` and `0002_loop.nql` are identical and `0001_init.nql` is untouched. The change is purely
additive: `MemoryKind.DECISION` stays in the enum and is simply not written any more, because removing an enum
value is not expressible as a Norvo diff. **Call:** a decision's state is one indexed enum rather than a
nullable timestamp, so no query depends on null filtering.

- [ ] **Step 1: Write the failing test `Tests/MusaiCoreTests/LoopSchemaTests.swift`**

```swift
import Foundation
import Testing
@testable import MusaiCore

@Suite struct LoopSchemaTests {
    @Test func theLoopsTypesMigrateAndRoundTrip() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let sdl = try await lib.db.schema()
        for type in ["Utterance", "Event", "Decision"] {
            #expect(sdl.contains("type \(type)"))
        }
        #expect(NorvoSchema.migrations.map(\.name) == ["0001_init", "0002_loop"])

        _ = try await lib.db.mutate(
            CreateProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user)
        _ = try await lib.db.mutate(
            UpsertSessionMutation(.init(
                memorySessionId: "s1", platform: "claude", startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                slug: "musai")),
            as: MusaiActors.curator)
        _ = try await lib.db.mutate(
            RecordUtteranceMutation(.init(
                text: "I said that I want to Read the post", at: Date(timeIntervalSince1970: 1_700_000_001),
                speaker: .user, session: "s1")),
            as: MusaiActors.curator)
        _ = try await lib.db.mutate(
            RecordEventMutation(.init(
                kind: .toolUse, at: Date(timeIntervalSince1970: 1_700_000_002), session: "s1",
                tool: "Edit", target: "Sources/MusaiCore/ProjectBinder.swift", digest: "sha256:abc")),
            as: MusaiActors.curator)

        let utterances = try await lib.db.query(UtterancesForSessionQuery(.init(session: "s1"))).utterances
        #expect(utterances.map(\.text) == ["I said that I want to Read the post"])
        #expect(utterances.first?.speaker == .user)
        let events = try await lib.db.query(UndrainedEventsQuery()).events
        #expect(events.count == 1)
        #expect(events.first?.tool == "Edit")
        #expect(events.first?.text == nil)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter LoopSchemaTests`
Expected: FAIL — `cannot find 'RecordUtteranceMutation' in scope`, and `NorvoSchema.migrations` has one entry.

- [ ] **Step 3: Append the loop's types to `schema.nql`, copy it to `migrations/0002_loop.nql`**

Append to the existing SDL:

```graphql
enum Speaker { USER AGENT SYSTEM }
enum ActKind { PROPOSAL OBJECTION EXAMPLE CONSTRAINT DECISION QUESTION }
enum EventKind { USER_TURN AGENT_TURN TOOL_USE SESSION_START OTHER }
enum DecisionState { PROPOSED SETTLED PERSISTED }

type Utterance {
  text: String! @fulltext
  at: DateTime! @index
  speaker: Speaker! @index
  origin: String @index
  session: Session @index
  decisions: [Decision!]! @inverse(of: "utterance")
}

type Event {
  kind: EventKind! @index
  text: String
  tool: String
  target: String
  digest: String
  at: DateTime! @index
  drained: Boolean! @index
  drainedAt: DateTime
  session: Session @index
}
```

and extend the existing `Decision` with exactly these fields (leaving its present fields in place):

```graphql
  act: ActKind! @index
  state: DecisionState! @index
  settledAt: DateTime
  persistedAt: DateTime
  document: Node
  documentRef: String
  utterance: Utterance @index
```

Also add to `Session`: `utterances: [Utterance!]! @inverse(of: "session")` and
`events: [Event!]! @inverse(of: "session")`.

Design notes the implementer cannot infer:

- **`Decision.title` and `rationale` are the detector's words; the `Utterance` is the user's.** The verbatim
  source is the link, never the paraphrase, which is why `Decision.utterance` exists.
- **`Event.text` is null for a tool use by design.** A tool event carries `tool`, `target` and `digest`; the
  result is never stored. This is the constraint, expressed in the schema.
- `document` is a Musai document (`Spec`/`Plan`/`Task`); `documentRef` is anything outside Musai (a commit, a
  path, a URL). `state == PERSISTED` means one of them is set.
- No `@index` on a relation field: relations are indexed automatically (learned in the data-model plan).

- [ ] **Step 4: Write `operations/capture.nql` and append to `operations/fragments.nql`**

`fragments.nql` gains:

```graphql
fragment UtteranceBits on Utterance {
  id
  text
  at
  speaker
  origin
  session { id memorySessionId }
}

fragment EventBits on Event {
  id
  kind
  text
  tool
  target
  digest
  at
  drained
}
```

`capture.nql`:

```graphql
query UtterancesForSession($session: String!) {
  utterances(where: {session: {memorySessionId: {eq: $session}}}, orderBy: [{at: ASC}]) { ...UtteranceBits }
}

query UndrainedEvents($first: Int = 200) {
  events(where: {drained: {eq: false}}, orderBy: [{createdAt: ASC}], first: $first) { ...EventBits }
}

mutation RecordUtterance($text: String!, $at: DateTime!, $speaker: Speaker!, $origin: String, $session: String!) {
  createUtterance(input: {
    text: $text
    at: $at
    speaker: $speaker
    origin: $origin
    session: {connect: {memorySessionId: $session}}
  }) { id }
}

mutation RecordEvent($kind: EventKind!, $at: DateTime!, $text: String, $tool: String, $target: String, $digest: String, $session: String!) {
  createEvent(input: {
    kind: $kind
    at: $at
    text: $text
    tool: $tool
    target: $target
    digest: $digest
    drained: false
    session: {connect: {memorySessionId: $session}}
  }) { id }
}

mutation MarkEventDrained($id: ID!, $drainedAt: DateTime!) {
  updateEvent(by: {id: $id}, set: {drained: {set: true}, drainedAt: {set: $drainedAt}}) { id drained }
}
```

- [ ] **Step 5: Add the review and slice queries to `operations/`**

Create `operations/review.nql`:

```graphql
fragment DecisionBits on Decision {
  id
  title
  rationale
  act
  state
  settledAt
  persistedAt
  document { id }
  documentRef
  utterance { id text at speaker }
  project { slug }
}

query PendingDecisions($first: Int = 50) {
  decisions(where: {state: {eq: PROPOSED}}, orderBy: [{createdAt: ASC}], first: $first) { ...DecisionBits }
}

query UnpersistedDecisions($first: Int = 50) {
  decisions(where: {state: {eq: SETTLED}}, orderBy: [{createdAt: ASC}], first: $first) { ...DecisionBits }
}

query DecisionByID($id: ID!) {
  decision(by: {id: $id}) { ...DecisionBits }
}

query DecisionsForProject($slug: String!, $first: Int = 50) {
  decisions(
    where: {project: {slug: {eq: $slug}}, state: {in: [SETTLED, PERSISTED]}}
    orderBy: [{createdAt: ASC}], first: $first) { ...DecisionBits }
}

mutation RecordProposal($title: String!, $rationale: String, $act: ActKind!, $utterance: ID, $project: String!) {
  createDecision(input: {
    title: $title
    rationale: $rationale
    act: $act
    state: PROPOSED
    utterance: {connect: {id: $utterance}}
    project: {connect: {slug: $project}}
  }) { id }
}

mutation SettleDecision($id: ID!, $settledAt: DateTime!) {
  updateDecision(by: {id: $id}, set: {
    state: {set: SETTLED}
    settledAt: {set: $settledAt}
  }) { id state }
}

mutation PersistDecisionInDocument($id: ID!, $document: ID!, $persistedAt: DateTime!) {
  updateDecision(by: {id: $id}, set: {
    state: {set: PERSISTED}
    document: {connect: {id: $document}}
    persistedAt: {set: $persistedAt}
  }) { id state }
}

mutation PersistDecisionOutside($id: ID!, $documentRef: String!, $persistedAt: DateTime!) {
  updateDecision(by: {id: $id}, set: {
    state: {set: PERSISTED}
    documentRef: {set: $documentRef}
    persistedAt: {set: $persistedAt}
  }) { id state }
}

mutation DropProposal($id: ID!) {
  deleteDecision(by: {id: $id})
}
```

Four notes. Every scalar in a `set:` takes the `{set: ...}` wrapper (learned in the data-model plan). The three
state mutations are separate operations rather than one with nullable arguments, because `connect` with a null
id fails the call — and each names one transition, so `PROPOSED` → `SETTLED` → `PERSISTED` is the only path the
schema allows. **`SETTLED` means confirmed but recorded nowhere: that is the gap.** A decision is `PERSISTED`
once it has landed somewhere, whether that is a Musai document or a reference outside it.
`RecordProposal` always connects an `utterance`, so a proposal the detector could not attach to something the
user actually said cannot exist — `DecisionDetector` returns `utterance: nil` and the curator skips it.
`SettleDecision` (confirm with no landing) is the operation `ReviewSession` calls for a bare confirmation, and
`PersistDecisionInDocument` is what the docs slice will call when a Spec or Plan exists to link to.

- [ ] **Step 6: Run it to verify it passes**

Run: `swift test --filter LoopSchemaTests`
Expected: PASS. If the plugin rejects the SDL, the failure names `path:line:col`.

- [ ] **Step 7: Run the whole suite**

Run: `swift test`
Expected: PASS, every suite from the data-model plan and this one.

- [ ] **Step 8: Commit**

```bash
git add Sources/MusaiCore/schema.nql Sources/MusaiCore/migrations Sources/MusaiCore/operations Tests/MusaiCoreTests/LoopSchemaTests.swift
git commit -m "feat: the decision loop's model — utterances, the event queue, decision state"
```

---

### Task 2: The capture path

**Files:**
- Create: `Sources/MusaiCore/MusaiCapture.swift`
- Test: `Tests/MusaiCoreTests/CaptureTests.swift`

**Interfaces:**
- Consumes: Task 1's generated operations; `MusaiLibrary`; `ProjectBinder`.
- Produces: `MusaiCapture.captureUserTurn(text:at:origin:session:cwd:as:) async throws -> UUID` (the
  `Utterance`'s id, which is what a proposal later links to), `.captureAgentTurn(text:at:session:cwd:as:) async throws`,
  `.captureToolUse(tool:target:digest:at:session:cwd:as:) async throws`,
  `MusaiCapture.maxTextBytes: Int`, `.truncated(_:to:) -> String`; `MusaiCapture` is
  `init(db: Database)`.

- [ ] **Step 1: Write the failing test `Tests/MusaiCoreTests/CaptureTests.swift`**

```swift
import Foundation
import Testing
@testable import MusaiCore

@Suite struct CaptureTests {
    private func library() async throws -> MusaiLibrary {
        try await MusaiLibrary.inMemory()
    }

    @Test func aUserTurnIsStoredVerbatimAndCapped() async throws {
        let lib = try await library()
        let capture = MusaiCapture(db: lib.db)
        _ = try await capture.captureUserTurn(
            text: "I said that I want to Read the post", at: Date(timeIntervalSince1970: 1_700_000_000),
            origin: "claude", session: "s1", cwd: "/tmp/musai-capture", as: MusaiActors.curator)
        let long = String(repeating: "x", count: MusaiCapture.maxTextBytes + 5_000)
        _ = try await capture.captureUserTurn(
            text: long, at: Date(timeIntervalSince1970: 1_700_000_001),
            origin: "claude", session: "s1", cwd: "/tmp/musai-capture", as: MusaiActors.curator)

        let rows = try await lib.db.query(UtterancesForSessionQuery(.init(session: "s1"))).utterances
        #expect(rows.count == 2)
        #expect(rows.first?.text == "I said that I want to Read the post")
        #expect(rows.last?.text?.utf8.count == MusaiCapture.maxTextBytes)
    }

    @Test func aToolUseStoresItsReferenceAndNeverItsResult() async throws {
        let lib = try await library()
        let capture = MusaiCapture(db: lib.db)
        _ = try await capture.captureToolUse(
            tool: "Edit", target: "Sources/MusaiCore/ProjectBinder.swift", digest: "sha256:abc",
            at: Date(timeIntervalSince1970: 1_700_000_000), session: "s1", cwd: "/tmp/musai-capture",
            as: MusaiActors.curator)

        let events = try await lib.db.query(UndrainedEventsQuery()).events
        #expect(events.count == 1)
        #expect(events.first?.kind == .toolUse)
        #expect(events.first?.tool == "Edit")
        #expect(events.first?.target == "Sources/MusaiCore/ProjectBinder.swift")
        #expect(events.first?.text == nil)
    }

    @Test func theSameTurnCapturedTwiceIsOneRow() async throws {
        let lib = try await library()
        let capture = MusaiCapture(db: lib.db)
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        for _ in 0..<2 {
            _ = try await capture.captureUserTurn(
                text: "same words", at: at, origin: "claude", session: "s1",
                cwd: "/tmp/musai-capture", as: MusaiActors.curator)
        }
        let rows = try await lib.db.query(UtterancesForSessionQuery(.init(session: "s1"))).utterances
        #expect(rows.count == 1)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter CaptureTests`
Expected: FAIL — `cannot find 'MusaiCapture' in scope`.

- [ ] **Step 3: Write `Sources/MusaiCore/MusaiCapture.swift`**

Interfaces the tests pin:

```swift
public struct MusaiCapture: Sendable {
    public static let maxTextBytes = 65_536
    public let db: Database
    public init(db: Database)

    public static func truncated(_ text: String, to bytes: Int) -> String
    public func captureUserTurn(text: String, at: Date, origin: String?, session: String, cwd: String, as actor: Actor) async throws
    public func captureAgentTurn(text: String, at: Date, session: String, cwd: String, as actor: Actor) async throws
    public func captureToolUse(tool: String, target: String?, digest: String?, at: Date, session: String, cwd: String, as actor: Actor) async throws
}
```

Bodies the signature does not determine:

- Each capture method first calls `ProjectBinder(db: db).bind(cwd: URL(fileURLWithPath: cwd), memorySessionId: session, platform: origin ?? "unknown", startedAt: at, as: actor)`, so the session exists before anything links to it. Binding is already idempotent.
- `truncated(_:to:)` truncates on a UTF-8 byte boundary, never mid-scalar.
- **Idempotence:** before inserting, query the session's rows and skip when a row with the same `speaker`/`kind` and the same `text` already exists at the same `at`. Do not add a uniqueness constraint (Norvo's `@unique` is global, not per session); `captureUserTurn` and `captureAgentTurn` record an `Utterance` only for `speaker == .user`; the agent's turn is an `Event` of kind `.agentTurn` with its text, so that agent text is captured but *not* mixed into the user's record.

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --filter CaptureTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/MusaiCore/MusaiCapture.swift Tests/MusaiCoreTests/CaptureTests.swift
git commit -m "feat: capture the exchange, cap it, and never store a tool's result"
```

---

### Task 3: The hook seam

**Files:**
- Modify: `Package.swift` (add an executable target)
- Create: `Sources/musai/HookPayload.swift`, `Sources/musai/main.swift`
- Test: `Tests/MusaiCoreTests/HookPayloadTests.swift`

**Interfaces:**
- Consumes: Task 2's `MusaiCapture`.
- Produces: `HookPayload` (a `Decodable` of the host's stdin JSON) with `.event: String?`, `.sessionId: String?`,
  `.cwd: String?`, `.prompt: String?`, `.toolName: String?`, `.toolInput: JSONValue?`;
  `struct HookRunner { init(capture: MusaiCapture, library: MusaiLibrary); func run(event: String?, stdin: Data, cwd: String, at: Date = Date()) async -> HookOutcome }`
  and `struct HookOutcome: Sendable { let stdout: String?; let diagnostic: String? }`; the `musai hook <event>`
  subcommand. `Package.swift` gains `.executableTarget(name: "musai", dependencies: ["MusaiCore", "NorvoLite"])`
  and the product `.executable(name: "musai", targets: ["musai"])`.

`HookRunner` is the dispatch, and it lives in `MusaiCore` rather than in the executable **so that "a hook can
never break the host" is a test rather than a hope**: `run` never throws, it returns a diagnostic instead.
`Sources/musai/main.swift` is then a thin shim that decodes nothing, prints `outcome.stdout` if any, prints the
diagnostic to stderr if any, and exits 0 in every case.

The payload fields are the host's, checked against Claude Code 2.1.295: a common set of `session_id`,
`transcript_path`, `cwd`, `permission_mode`, `hook_event_name`, plus `user_prompt` on `UserPromptSubmit`,
`tool_name`/`tool_input`/`tool_result` on `PostToolUse`, and `reason` on `Stop`. `tool_result` is deliberately
**not** decoded — it must never reach the store.

- [ ] **Step 1: Write the failing test `Tests/MusaiCoreTests/HookPayloadTests.swift`**

```swift
import Foundation
import Testing
@testable import MusaiCore
@testable import musai

@Suite struct HookPayloadTests {
    @Test func aUserPromptSubmitPayloadDecodesItsTurn() throws {
        let json = """
        {"session_id":"s1","transcript_path":"/tmp/t.jsonl","cwd":"/tmp/musai-hook",
         "permission_mode":"ask","hook_event_name":"UserPromptSubmit","user_prompt":"do the thing"}
        """
        let payload = try HookPayload.decode(Data(json.utf8))
        #expect(payload.event == "UserPromptSubmit")
        #expect(payload.sessionId == "s1")
        #expect(payload.cwd == "/tmp/musai-hook")
        #expect(payload.prompt == "do the thing")
    }

    @Test func aToolResultIsNotCarried() throws {
        let json = """
        {"session_id":"s1","cwd":"/tmp/musai-hook","hook_event_name":"PostToolUse",
         "tool_name":"Edit","tool_input":{"file_path":"a.swift"},"tool_result":"WHOLE FILE CONTENTS"}
        """
        let payload = try HookPayload.decode(Data(json.utf8))
        #expect(payload.toolName == "Edit")
        #expect(payload.toolTarget == "a.swift")
        // The payload carries a result and `HookPayload` has no way to hand it on. The end-to-end test in
        // Task 10 is what proves the store itself never sees it.
        #expect(payload.capturesToolResult == false)
    }

    @Test func aMalformedOrUnexpectedPayloadNeverBreaksTheSession() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let runner = HookRunner(capture: MusaiCapture(db: lib.db), library: lib)
        for bad in ["{not json", #"{"hook_event_name":"Stop","cwd":"/tmp"}"#, "{}"] {
            let outcome = await runner.run(event: nil, stdin: Data(bad.utf8), cwd: "/tmp/musai-hook")
            #expect(outcome.stdout == nil)
            #expect(outcome.diagnostic != nil)
        }
        // And an event the host adds later, which we do not implement:
        let unknown = await runner.run(
            event: "SomethingNew", stdin: Data(#"{"session_id":"s1","cwd":"/tmp"}"#.utf8), cwd: "/tmp")
        #expect(unknown.stdout == nil)
        #expect(unknown.diagnostic == nil)
    }

    @Test func aPayloadMissingItsSessionIsRejected() {
        #expect(throws: (any Error).self) {
            try HookPayload.decode(Data(#"{"hook_event_name":"Stop","cwd":"/tmp"}"#.utf8))
        }
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter HookPayloadTests`
Expected: FAIL — `cannot find 'HookPayload' in scope`.

- [ ] **Step 3: Write `Sources/musai/HookPayload.swift` and `Sources/MusaiCore/HookRunner.swift`**

```swift
public struct HookPayload: Decodable, Sendable {
    public enum Failure: Error { case missingSession, malformed }
    public let event: String?
    public let sessionId: String?
    public let cwd: String?
    public let transcriptPath: String?
    public let prompt: String?
    public let toolName: String?
    public let toolTarget: String?
    public let reason: String?
    /// Always false. Decoded only so the fixture proves the result is present and still not kept.
    public let capturesToolResult = false

    public static func decode(_ data: Data) throws -> HookPayload
    public func text(forToolResult result: String) -> String?
}

public struct HookOutcome: Sendable, Equatable {
    public let stdout: String?
    public let diagnostic: String?
    public static let silent = HookOutcome(stdout: nil, diagnostic: nil)
}

public struct HookRunner: Sendable {
    public init(capture: MusaiCapture, library: MusaiLibrary)
    /// Never throws. A failure becomes a diagnostic, so a hook can never break the host's session.
    public func run(event: String?, stdin: Data, cwd: String, at: Date = Date()) async -> HookOutcome
}
```

- `decode` uses `JSONDecoder` with `convertFromSnakeCase`; it throws `.malformed` when the data is not JSON and
  `.missingSession` when `session_id` is absent. It decodes `tool_input.file_path` (and `path`, for hosts that
  use that key) into `toolTarget`; it never decodes `tool_result` into anything but a discarded value, and
  `text(forToolResult:)` returns `nil` — it exists so a caller cannot accidentally pass a result through.
  `HookPayload` lives in the `musai` target; the test target gains `"musai"` as a dependency so it can
  `@testable import` it.
- `HookRunner.run` bounds stdin to 1 MiB (draining and ignoring the rest), decodes, and dispatches on `event`,
  falling back to `event` from the payload when the argument is `nil`:
  - `UserPromptSubmit` → `capture.captureUserTurn(prompt, at, origin: "claude", session, cwd)`; `stdout: nil`.
  - `PostToolUse` → `capture.captureToolUse(toolName, target, digest: SHA256 of "tool\u{1F}target", at, session, cwd)`.
  - `Stop` → `capture.captureAgentTurn(TranscriptTail.lastAssistantText(at:), …)`, then `ProposalCurator.drain`
    with the detector resolved from the environment; wired in Tasks 4 and 6.
  - `SessionStart` → `MusaiSlice.render`, and `stdout` is the `additionalContext` JSON; wired in Task 5.
  - any other event → `HookOutcome.silent`.
  - any thrown error, a malformed payload, or a missing session → `HookOutcome(stdout: nil, diagnostic: "musai: <one line>")`.

- [ ] **Step 4: Write `Sources/musai/main.swift`**

The `hook` subcommand reads stdin (bounded to 1 MiB; beyond that it drains and ignores), decodes, and
dispatches. The whole body is wrapped so that **any** failure prints a one-line diagnostic to stderr and exits
0:

`main.swift` is a shim: it parses `musai hook <event-name> [--library <path>]`, reads stdin, calls
`HookRunner.run`, prints `outcome.stdout` if present, writes `outcome.diagnostic` to stderr if present, and
exits 0 in every case — including a thrown error, which it catches rather than letting the runtime print a
crash. The library path is `--library`, else `MUSAI_LIBRARY`, else `MusaiLibrary.defaultFileURL`.

- [ ] **Step 5: Run the tests, then the executable by hand**

Run: `swift test --filter HookPayloadTests` — Expected: PASS, 4 tests.
Run: `echo '{"session_id":"s1","cwd":"/Volumes/projects/Personal/musai","hook_event_name":"UserPromptSubmit","user_prompt":"hello"}' | MUSAI_LIBRARY=/tmp/musai-hook-test.norvo swift run musai hook UserPromptSubmit` — Expected: exit 0 and no output; then `MUSAI_LIBRARY=/tmp/musai-hook-test.norvo swift run musai hook UserPromptSubmit <<< 'not json'` — Expected: exit 0, one stderr line.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/musai Tests/MusaiCoreTests/HookPayloadTests.swift
git commit -m "feat: the musai hook seam — capture without ever breaking the host"
```

---

### Task 4: The agent's own last message

**Files:**
- Create: `Sources/musai/TranscriptTail.swift`
- Test: `Tests/MusaiCoreTests/TranscriptTailTests.swift`

**Interfaces:**
- Consumes: Task 3's `HookPayload.transcriptPath`; Task 2's `captureAgentTurn`.
- Produces: `TranscriptTail.lastAssistantText(at: URL, limit: Int) throws -> String?` — the concatenated `text`
  blocks of the last assistant message, or `nil`.

This is the one transcript read in the system (§5 of the spec). It reads the file's **tail** (1 MiB at most),
line by line, taking the last line whose `type` is `assistant`, and from it only the `message.content`
entries whose `type` is `text`. Tool-use blocks, tool results and file contents are ignored. A line that does
not parse is skipped, so a format change degrades to `nil` rather than an error.

- [ ] **Step 1: Write the failing test with a fixture transcript**

```swift
import Foundation
import Testing
@testable import MusaiCore

@Suite struct TranscriptTailTests {
    private func fixture(_ lines: [String]) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "musai-tail-\(UUID().uuidString).jsonl")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { }
        return url
    }

    @Test func theLastAssistantTextIsReturnedAndToolBlocksIgnored() throws {
        let url = try fixture([
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"do the thing"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"a.swift"}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"WHOLE FILE"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I changed a.swift"},{"type":"text","text":" and reran the tests."}]}}"#,
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        let text = try TranscriptTail.lastAssistantText(at: url, limit: 4_096)
        #expect(text == "I changed a.swift and reran the tests.")
    }

    @Test func anUnknownFormatOrMissingFileIsNilNotAnError() throws {
        #expect(try TranscriptTail.lastAssistantText(at: URL(fileURLWithPath: "/tmp/nope-\(UUID().uuidString)")) == nil)
        let url = try fixture(["not json at all"])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try TranscriptTail.lastAssistantText(at: url) == nil)
    }

    @Test func aHugeMessageIsTruncatedToTheLimit() throws {
        let big = String(repeating: "y", count: 20_000)
        let url = try fixture([
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(big)"}]}}"#
        ])
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try TranscriptTail.lastAssistantText(at: url, limit: 1_000)?.utf8.count == 1_000)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter TranscriptTailTests`
Expected: FAIL — `cannot find 'TranscriptTail' in scope`.

- [ ] **Step 3: Write `Sources/musai/TranscriptTail.swift`**

Signature: `public enum TranscriptTail { public static func lastAssistantText(at url: URL, limit: Int = MusaiCapture.maxTextBytes) throws -> String? }`.

Body: read at most the last 1 MiB of the file (`FileHandle` seek to `max(0, size - 1_048_576)`), drop the first
partial line, split on `\n`, and walk **backwards** for the last line that decodes as an object with
`type == "assistant"`. From its `message.content` array, join the `text` values of entries whose `type` is
`"text"` with a single space, then truncate with `MusaiCapture.truncated(_:to: limit)`. Any failure returns
`nil`.

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --filter TranscriptTailTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Wire it into the `Stop` path and run it by hand**

In `main.swift`, `Stop` calls `TranscriptTail.lastAssistantText(at:)` when `transcriptPath` is present and
non-empty, then `captureAgentTurn`. Manual check: after Task 5's hook is installed, a real session's `Stop`
should leave an `Event` of kind `agentTurn` with text.

- [ ] **Step 6: Commit**

```bash
git add Sources/musai/TranscriptTail.swift Sources/musai/main.swift Tests/MusaiCoreTests/TranscriptTailTests.swift
git commit -m "feat: the agent's own last message, text only, from one host's transcript"
```

---

### Task 5: The slice at session start

**Files:**
- Create: `Sources/MusaiCore/MusaiSlice.swift`
- Modify: `Sources/musai/main.swift` (the `SessionStart` path)
- Test: `Tests/MusaiCoreTests/SliceTests.swift`

**Interfaces:**
- Consumes: Task 1's `DecisionsForProjectQuery`; the existing `TasksForProjectByStatusQuery`, `ProjectBinder`,
  `AllProjectsQuery`.
- Produces: `MusaiSlice.render(project: String, budget: Int, db: Database) async throws -> String?` — the text
  to hand the agent, or `nil` when there is nothing to say; `MusaiSlice.additionalContext(_ text: String) -> String`
  — the host's stdout JSON.

- [ ] **Step 1: Write the failing test `Tests/MusaiCoreTests/SliceTests.swift`**

```swift
import Foundation
import Testing
@testable import MusaiCore

@Suite struct SliceTests {
    private func seeded() async throws -> MusaiLibrary {
        let lib = try await MusaiLibrary.inMemory()
        _ = try await lib.db.mutate(
            CreateProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user)
        return lib
    }

    @Test func anEmptyStoreRendersNothing() async throws {
        let lib = try await MusaiLibrary.inMemory()
        let text = try await MusaiSlice.render(project: "musai", budget: 2_000, db: lib.db)
        #expect(text == nil)
    }

    @Test func onlySettledOrPersistedDecisionsAreHandedOver() async throws {
        let lib = try await seeded()
        let capture = MusaiCapture(db: lib.db)
        _ = try await capture.captureUserTurn(
            text: "we will use one Norvo file", at: Date(timeIntervalSince1970: 1_700_000_000),
            origin: "claude", session: "s1", cwd: "/tmp/musai-slice", as: MusaiActors.curator)
        let utterances = try await lib.db.query(UtterancesForSessionQuery(.init(session: "s1"))).utterances
        let utterance = utterances.first!.id
        let settled = try await lib.db.mutate(
            RecordProposalMutation(.init(
                title: "One Norvo file", rationale: "Anti-clunk", act: .decision,
                utterance: utterance, project: "musai")), as: MusaiActors.curator).createDecision.id
        _ = try await lib.db.mutate(
            PersistDecisionOutsideMutation(.init(id: settled, documentRef: "commit:abc", persistedAt: Date())),
            as: MusaiActors.user)
        _ = try await lib.db.mutate(
            RecordProposalMutation(.init(
                title: "A stray proposal", rationale: nil, act: .proposal,
                utterance: utterance, project: "musai")), as: MusaiActors.curator)

        let text = try await MusaiSlice.render(project: "musai", budget: 2_000, db: lib.db)
        #expect(text?.contains("One Norvo file") == true)
        #expect(text?.contains("A stray proposal") == false)
    }

    @Test func theSliceRespectsItsBudget() async throws {
        let lib = try await seeded()
        let capture = MusaiCapture(db: lib.db)
        _ = try await capture.captureUserTurn(
            text: "x", at: Date(timeIntervalSince1970: 1_700_000_000), origin: "claude",
            session: "s1", cwd: "/tmp/musai-slice", as: MusaiActors.curator)
        let utterance = try await lib.db.query(UtterancesForSessionQuery(.init(session: "s1"))).utterances.first!.id
        for index in 0..<40 {
            let id = try await lib.db.mutate(
                RecordProposalMutation(.init(
                    title: String(repeating: "long title \(index) ", count: 8), rationale: nil,
                    act: .decision, utterance: utterance, project: "musai")), as: MusaiActors.curator).createDecision.id
            _ = try await lib.db.mutate(
                PersistDecisionOutsideMutation(.init(id: id, documentRef: "commit:\(index)", persistedAt: Date())),
                as: MusaiActors.user)
        }
        let text = try await MusaiSlice.render(project: "musai", budget: 1_200, db: lib.db)
        #expect((text?.utf8.count ?? 0) <= 1_200)
        #expect(text?.contains("more") == true)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter SliceTests`
Expected: FAIL — `cannot find 'MusaiSlice' in scope`.

- [ ] **Step 3: Write `Sources/MusaiCore/MusaiSlice.swift`**

`render` returns `nil` when there are no settled decisions and no open tasks for the project. Otherwise it
builds, in this order: a one-line header naming the project; the settled decisions (newest first, each as
`- <title> — <act> — <how it is persisted>`, quoting the linked `Utterance.text` for a `CONSTRAINT` or
`EXAMPLE`, because those are the ones whose exact wording matters); then the open tasks by status. It appends
the decisions it had to leave out as a single line: `(+N more settled decisions)`. It stops adding lines when
the next one would exceed `budget` and then appends that count line.

`additionalContext` returns exactly:

```json
{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":["<text>"]}}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `swift test --filter SliceTests`
Expected: PASS, 3 tests.

- [ ] **Step 5: Wire `SessionStart` in `main.swift` and run it by hand**

`SessionStart`: resolve the project with `ProjectBinder` from `cwd`, then `MusaiSlice.render`; if non-nil, print
`additionalContext`, else print nothing. Manual check against the `/tmp/musai-hook-test.norvo` library.

- [ ] **Step 6: Commit**

```bash
git add Sources/MusaiCore/MusaiSlice.swift Sources/musai/main.swift Tests/MusaiCoreTests/SliceTests.swift
git commit -m "feat: hand the agent the settled decisions that constrain its task"
```

---

### Task 6: The curator's drain

**Files:**
- Create: `Sources/MusaiCore/ProposalCurator.swift`, `Sources/MusaiCore/DecisionDetector.swift`
- Test: `Tests/MusaiCoreTests/CuratorTests.swift`

**Interfaces:**
- Consumes: Task 1's `UndrainedEventsQuery`, `MarkEventDrainedMutation`, `RecordProposalMutation`.
- Produces: `protocol DecisionDetector: Sendable { func propose(from events: [DetectedEvent]) async throws -> [DetectedDecision] }`;
  `struct DetectedEvent: Sendable { id: UUID; kind: EventKind; text: String?; tool: String?; target: String?; at: Date }`;
  `struct DetectedDecision: Sendable { title: String; rationale: String?; act: ActKind; utterance: UUID? }`;
  `struct ProposalCurator: Sendable { init(db: Database, detector: any DecisionDetector, batch: Int = 50); func drain(project: String, as actor: Actor) async throws -> Int }`.

- [ ] **Step 1: Write the failing test `Tests/MusaiCoreTests/CuratorTests.swift`**

```swift
import Foundation
import Testing
@testable import MusaiCore

/// Proposes one decision per user turn, so the tests can check both the written and the skipped paths.
private struct StubDetector: DecisionDetector {
    let onEvents: @Sendable ([DetectedEvent]) -> [DetectedDecision]
    func propose(from events: [DetectedEvent]) async throws -> [DetectedDecision] { onEvents(events) }
}

private struct FailingDetector: DecisionDetector {
    struct Boom: Error {}
    func propose(from events: [DetectedEvent]) async throws -> [DetectedDecision] { throw Boom() }
}

@Suite struct CuratorTests {
    private func seeded() async throws -> MusaiLibrary {
        let lib = try await MusaiLibrary.inMemory()
        _ = try await lib.db.mutate(
            CreateProjectMutation(.init(name: "Musai", slug: "musai")), as: MusaiActors.user)
        return lib
    }

    private func twoTurns(_ lib: MusaiLibrary) async throws {
        let capture = MusaiCapture(db: lib.db)
        for (index, text) in ["we will use one Norvo file", "yes, and no Obsidian vault"].enumerated() {
            _ = try await capture.captureUserTurn(
                text: text, at: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                origin: "claude", session: "s1", cwd: "/tmp/musai-curator", as: MusaiActors.curator)
        }
    }

    @Test func drainProposesAndMarksTheEventsDrained() async throws {
        let lib = try await seeded()
        try await twoTurns(lib)
        // The detector sees the events in order and links each proposal to the turn it came from.
        let detector = StubDetector { events in
            events.enumerated().map { index, event in
                DetectedDecision(
                    title: "Decision \(index)", rationale: nil, act: .decision, utterance: event.utterance)
            }
        }
        let curator = ProposalCurator(db: lib.db, detector: detector)
        let written = try await curator.drain(project: "musai", as: MusaiActors.curator)

        #expect(written == 2)
        let undrained = try await lib.db.query(UndrainedEventsQuery()).events
        #expect(undrained.isEmpty)
        let pending = try await lib.db.query(PendingDecisionsQuery()).decisions
        #expect(pending.count == 2)
        #expect(pending.compactMap(\.utterance?.text).sorted() == ["yes, and no Obsidian vault", "we will use one Norvo file"])
    }

    @Test func drainIsIdempotent() async throws {
        let lib = try await seeded()
        try await twoTurns(lib)
        let detector = StubDetector { events in
            events.enumerated().map { index, event in
                DetectedDecision(title: "D\(index)", rationale: nil, act: .decision, utterance: event.utterance)
            }
        }
        let curator = ProposalCurator(db: lib.db, detector: detector)
        #expect(try await curator.drain(project: "musai", as: MusaiActors.curator) == 2)
        #expect(try await curator.drain(project: "musai", as: MusaiActors.curator) == 0)
        #expect(try await lib.db.query(PendingDecisionsQuery()).decisions.count == 2)
    }

    @Test func aThrowingDetectorLeavesEveryEventForRetry() async throws {
        let lib = try await seeded()
        try await twoTurns(lib)
        let curator = ProposalCurator(db: lib.db, detector: FailingDetector())

        await #expect(throws: (any Error).self) {
            _ = try await curator.drain(project: "musai", as: MusaiActors.curator)
        }
        let undrained = try await lib.db.query(UndrainedEventsQuery()).events
        #expect(undrained.count == 2)
    }

    @Test func aProposalWithoutAUsersWordsIsSkipped() async throws {
        let lib = try await seeded()
        try await twoTurns(lib)
        // One proposal links to a turn, one does not: only the linked one may be written.
        let detector = StubDetector { events in
            [
                DetectedDecision(title: "Kept", rationale: nil, act: .decision, utterance: events.first?.utterance),
                DetectedDecision(title: "The assistant's own idea, never agreed", rationale: nil, act: .proposal, utterance: nil),
            ]
        }
        let curator = ProposalCurator(db: lib.db, detector: detector)
        #expect(try await curator.drain(project: "musai", as: MusaiActors.curator) == 1)
        let pending = try await lib.db.query(PendingDecisionsQuery()).decisions
        #expect(pending.map(\.title) == ["Kept"])
    }
}
```

`DetectedEvent` therefore carries `utterance: UUID?` — the durable row a user turn also produced, which is what
a proposal links to. `MusaiCapture` writes that `Utterance` for a user turn and returns its id; the builder
adds that id to `DetectedEvent` when mapping the undrained events back to their session's utterances by
`origin` (the host's session id) and time.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter CuratorTests`
Expected: FAIL — `cannot find 'ProposalCurator' in scope`.

- [ ] **Step 3: Write `DecisionDetector.swift` and `ProposalCurator.swift`**

`ProposalCurator.drain` is the algorithm the interfaces do not determine:

1. `UndrainedEventsQuery(first: batch)`.
2. For each event, resolve the user turn it belongs to: `UtterancesForSessionQuery` for the event's session
   (`origin` is the host's session id, so both tiers share it), and take the utterance whose `at` is at or
   before the event's `at` and closest to it. That id becomes `DetectedEvent.utterance`, and it is what lets a
   proposal point at the words the user actually used.
3. `try await detector.propose(from:)` — **before** marking anything drained, so a throw leaves the queue intact.
4. For each `DetectedDecision`, write it only when it is traceable and readable: skip it when `utterance` is
   `nil` (the assistant's own idea, never agreed to), when `title` is empty or whitespace-only, or when `title`
   exceeds 200 characters. A proposal the user cannot trace to their own words, or cannot read, is clerk work.
   Otherwise `RecordProposalMutation`.
5. Only after every proposal is written, `MarkEventDrainedMutation` for the drained ids with the same `now`.
6. Return the number of proposals written.

`DecisionDetector` also carries the queue's shape as a documented rule: a detector sees events, not the store,
so it cannot write.

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test --filter CuratorTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/MusaiCore/DecisionDetector.swift Sources/MusaiCore/ProposalCurator.swift Tests/MusaiCoreTests/CuratorTests.swift
git commit -m "feat: the curator drains the queue into proposals"
```

---

### Task 7: The Ollama detector

**Files:**
- Create: `Sources/MusaiCore/OllamaDecisionDetector.swift`
- Test: `Tests/MusaiCoreTests/OllamaDetectorTests.swift`

**Interfaces:**
- Consumes: Task 6's `DecisionDetector`, `DetectedEvent`, `DetectedDecision`.
- Produces: `struct OllamaDecisionDetector: DecisionDetector { init(model: String, endpoint: URL = URL(string: "http://127.0.0.1:11434")!, transport: any ModelTransport = URLSessionTransport()) }`;
  `protocol ModelTransport: Sendable { func send(_ request: URLRequest, body: Data) async throws -> Data }`.

The transport is the seam that keeps the test off the network, so the detector's prompt and its parsing are
testable without a model.

- [ ] **Step 1: Write the failing test `Tests/MusaiCoreTests/OllamaDetectorTests.swift`**

A stub `ModelTransport` returns a fixed Ollama-shaped response body
(`{"message":{"content":"<json>"}}`) whose content is a JSON object
`{"decisions":[{"title":"One Norvo file","rationale":"Anti-clunk","act":"DECISION","utterance_index":0}]}`, and
records the request it was handed. Five tests:

1. `itParsesDecisionsFromTheModelsJSON` — one `DetectedEvent` in, one `DetectedDecision` out with those values.
2. `itSendsTheModelAndAConstrainedRequest` — the recorded request's path is `/api/chat`, its body names
   `model == "qwen3.6:27b"`, and it carries a `format` (the JSON schema) and `stream == false`.
3. `invalidJSONFromTheModelProposesNothing` — content `"I think maybe one decision?"` → `[]`, no throw.
4. `aHallucinatedUtteranceIndexIsDroppedNotCrashing` — `utterance_index: 99` with one event → the decision is
   still returned but with `utterance == nil`.
5. `anEmptyEventListDoesNotCallTheModel` — the stub records no request and the result is `[]`.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter OllamaDetectorTests`
Expected: FAIL — `cannot find 'OllamaDecisionDetector' in scope`.

- [ ] **Step 3: Write `Sources/MusaiCore/OllamaDecisionDetector.swift`**

The body the interfaces leave open: a system prompt that states the job and the anti-goal, a user message that
renders the events as a numbered list (`[0] user: …`, `[1] tool Edit Sources/…`), `format` set to a JSON schema
with `decisions: [{title, rationale, act, utterance_index}]`, `stream: false`, and `options.temperature: 0`.
Response parsing uses `JSONDecoder` over the `message.content` string; on any failure it returns `[]`. The
prompt is pinned in the file as a constant so a reviewer can read it.

The prompt must instruct, verbatim in spirit: propose **only** decisions the user actually settled, in the
user's own words where possible; when unsure, propose nothing; never propose an idea the assistant raised
unless the user agreed to it; never propose more than five per batch.

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test --filter OllamaDetectorTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Run one live check, opt-in**

Run: `MUSAI_LIVE_MODEL=1 swift test --filter OllamaDetectorTests.live` — a single test, skipped unless
`MUSAI_LIVE_MODEL` is set, that sends one real captured exchange to the installed model and asserts only that
it returns valid JSON. It is not part of the suite's default run.

- [ ] **Step 6: Commit**

```bash
git add Sources/MusaiCore/OllamaDecisionDetector.swift Tests/MusaiCoreTests/OllamaDetectorTests.swift
git commit -m "feat: a local detector over loopback Ollama, testable without a model"
```

---

### Task 8: One keystroke

**Files:**
- Create: `Sources/MusaiCore/ReviewSession.swift`
- Modify: `Sources/musai/main.swift` (the `review` subcommand)
- Test: `Tests/MusaiCoreTests/ReviewTests.swift`

**Interfaces:**
- Consumes: Task 1's `PendingDecisionsQuery`, `UnpersistedDecisionsQuery`, `DecisionByIDQuery`,
  `SettleDecisionMutation`, `PersistDecisionOutsideMutation`, `DropProposalMutation`; `MusaiSlice`.
- Produces: `enum ReviewAction: Sendable { case settle; case persist(documentRef: String); case drop; case skip }`;
  `struct Proposal: Sendable { id: UUID; title: String; rationale: String?; act: ActKind; said: String? }`;
  `struct Gap: Sendable { id: UUID; title: String; act: ActKind; said: String?; settledAt: Date? }`;
  `struct ReviewSession: Sendable { init(db: Database); func pending() async throws -> [Proposal]; func unpersisted() async throws -> [Gap]; func apply(_ action: ReviewAction, to id: UUID, as actor: Actor) async throws; func run(as actor: Actor) async throws -> Int }`.

- [ ] **Step 1: Write the failing tests `Tests/MusaiCoreTests/ReviewTests.swift`**

Six tests, and they pin the state machine as much as the CLI:

1. `pendingIsEmptyOnAFreshStore` — `ReviewSession(db:).pending()` is `[]` on an in-memory library with no
   projects at all, and `run` returns 0 without asking anything.
2. `settlePutsTheDecisionInTheGap` — record a proposal, `apply(.settle, to:, as: MusaiActors.user)`; assert it
   has left `PendingDecisionsQuery()`, that `UnpersistedDecisionsQuery()` holds it, and that
   `DecisionByIDQuery(id:).decision?.state == .settled`.
3. `persistTakesItOutOfTheGapAndRemembersWhereItLanded` — `apply(.persist(documentRef: "commit:abc"), …)`;
   assert `UnpersistedDecisionsQuery()` is empty, `PendingDecisionsQuery()` is empty, and the decision's
   `state == .persisted`, `documentRef == "commit:abc"`, `persistedAt != nil`.
4. `dropRemovesTheProposalAndLeavesTheGapEmpty` — after `.drop`, the decision is gone from both queries.
5. `skipLeavesItPending` — after `.skip`, it is still in `PendingDecisionsQuery()` and not in the gap.
6. `theGapIsReadableWithoutRunningTheWholeReview` — `unpersisted()` returns the settled-but-unrecorded
   decisions as `Gap`s carrying the user's words, so `run` can show them before it asks anything.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter ReviewTests`
Expected: FAIL — `cannot find 'ReviewSession' in scope`.

- [ ] **Step 3: Write `ReviewSession.swift` and the `review` subcommand**

`apply` maps one action to one operation and does nothing else: `.settle` → `SettleDecisionMutation`,
`.persist(documentRef:)` → `PersistDecisionOutsideMutation`, `.drop` → `DropProposalMutation`,
`.skip` → nothing. `actor` is passed through to the mutation, so the history records who confirmed it — the
person, not the curator.

`run` opens with the gap, because that is the risk the person came to see, then walks the proposals:

```
2 decisions were settled and never recorded anywhere
  · One Norvo file                          (DECISION, settled 3 days ago)

[3/12] One Norvo file                      (DECISION, said: "we will use one Norvo file")
  Anti-clunk
  [y] settled, landed nowhere   [r] settled, landed at…   [d] drop   [s] skip
```

reads a single line from stdin, and applies it. `y` is `.settle` (the gap), `r` prompts once for the reference
and is `.persist(documentRef:)`, `d` is `.drop`, `s` is `.skip`. An unrecognised key is treated as `.skip`,
because a wrong confirmation is worse than a missed one. When there is nothing pending and nothing in the gap,
it prints a single line and returns 0.

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test --filter ReviewTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Drive it by hand once**

Run: `MUSAI_LIBRARY=/tmp/musai-hook-test.norvo swift run musai review` — Expected with no proposals: a single
"nothing pending" line and exit 0.

- [ ] **Step 6: Commit**

```bash
git add Sources/MusaiCore/ReviewSession.swift Sources/musai/main.swift Tests/MusaiCoreTests/ReviewTests.swift
git commit -m "feat: confirm a proposal in one keystroke, and see what was never written down"
```

---

### Task 9: Install it into Claude Code

**Files:**
- Create: `Sources/musai/Install.swift`, `docs/claude-code-hooks.md`
- Modify: `Sources/musai/main.swift` (the `install` subcommand), `README.md`
- Test: `Tests/MusaiCoreTests/InstallTests.swift`

**Interfaces:**
- Consumes: Task 3's subcommand names; Task 7's model default.
- Produces: `MusaiInstall.claudeCodeHooksSettings(executable: String) -> Data` — the `hooks` object to merge
  into `~/.claude/settings.json`, and `MusaiInstall.merge(claudeCodeHooksSettings:into existing: Data) throws -> Data`.

The matchers are the host's, checked against claude-mem's own configuration: `SessionStart` matches
`startup|resume|clear`, `UserPromptSubmit` and `PostToolUse` and `Stop` match everything they are given. The
hooks are the host's `command` type, with the executable path absolute, and each command ends in
`2>/dev/null || true` so a failure can never surface as a hook error in the session.

- [ ] **Step 1: Write the failing tests**

1. `theSettingsNameEveryHookWeRelyOn` — the produced JSON's `hooks` object has `SessionStart`,
   `UserPromptSubmit`, `PostToolUse` and `Stop`, each calling `musai hook <Event>`.
2. `everyCommandCannotFailTheSession` — every command string ends with `|| true`.
3. `mergingIntoAnExistingFileKeepsOtherHooks` — an existing settings file with an unrelated `SessionStart`
   hook (the shape found on this machine) survives the merge, and the result is valid JSON.
4. `mergingTwiceDoesNotDuplicateOurHooks` — merging into an already-merged document leaves the hook arrays
   unchanged.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter InstallTests`
Expected: FAIL — `cannot find 'MusaiInstall' in scope`.

- [ ] **Step 3: Write `Sources/musai/Install.swift` and the `install` subcommand**

`musai install --claude-code` prints the merged settings and writes a backup of the existing file to
`~/.claude/settings.json.musai-backup` before replacing it; it prints what it changed. It never runs without
the flag.

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test --filter InstallTests`
Expected: PASS, 4 tests.

- [ ] **Step 5: Write `docs/claude-code-hooks.md` and add a README section**

The doc states each hook, what it captures, the timeout to configure (a 15-second sync `UserPromptSubmit`, a
60-second sync `SessionStart`, a 120-second async `Stop` and `PostToolUse`), and how to uninstall (remove the
four entries; the store is a file, so nothing else is left behind).

- [ ] **Step 6: Commit**

```bash
git add Sources/musai/Install.swift Sources/musai/main.swift docs/claude-code-hooks.md README.md Tests/MusaiCoreTests/InstallTests.swift
git commit -m "feat: install the loop into Claude Code, reversibly"
```

---

### Task 10: The loop, end to end

**Files:**
- Create: `Tests/MusaiCoreTests/LoopEndToEndTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: every earlier task.
- Produces: nothing new — this is the acceptance test that proves the loop, and the manual checklist for the
  one part a test cannot prove (whether the detector is precise enough to feel good).

- [ ] **Step 1: Write the end-to-end test**

One `@Test` that, against one in-memory library and a stub detector, drives the real sequence with real
payload shapes:

1. A `SessionStart` payload for a git-less temp directory → the slice is empty and nothing is printed.
2. A `UserPromptSubmit` payload with `user_prompt: "we will use one Norvo file"` → one `Utterance`, and the
   same payload again → still one.
3. A `PostToolUse` payload with a `tool_result` of file contents → one `Event` with `text == nil`, `tool`, and
   no sign of the contents anywhere in the store (assert by fetching the event and comparing its fields).
4. A `Stop` payload with a fixture transcript path → one `agentTurn` `Event`.
5. `ProposalCurator.drain` with a stub detector that proposes the one decision → one `PROPOSED` decision.
6. `ReviewSession.apply(.persist(documentRef: "commit:abc"))` → it leaves `PendingDecisionsQuery`.
7. A second `SessionStart` payload → the slice contains the decision's title and `commit:abc`.
8. `UnpersistedDecisionsQuery` is empty.

- [ ] **Step 2: Run it to verify it fails, then passes**

Run: `swift test --filter LoopEndToEndTests`
Expected: FAIL first (the test is written against the whole loop), then PASS once the pieces are wired.

- [ ] **Step 3: Run the whole suite**

Run: `swift test`
Expected: PASS, every suite.

- [ ] **Step 4: The manual checklist, in `README.md`**

A short section, "Try the loop by hand", with the exact commands: `musai install --claude-code`, work a
session in Claude Code, `musai review`, then start a new session and read what the agent was handed. It ends
with the question this slice exists to answer — *did confirming those proposals feel like one keystroke, or
like clerk work?* — and says to record the answer in the next design, because that answer decides whether the
model changes and the rest of the host matrix are worth building.

- [ ] **Step 5: Commit**

```bash
git add Tests/MusaiCoreTests/LoopEndToEndTests.swift README.md
git commit -m "test: the loop end to end, and the one question a test cannot answer"
```

---

## What this plan leaves

- **Writing a decision into its document** (§6.4's second half). Slice 1 *links* a decision to where it landed,
  which is why `PersistDecisionInDocument` exists but is not called yet; the export that carries a decision into
  a `Spec`/`Plan` body is the docs slice, because §9's authoring flow does not exist yet.
- **Artifacts as entities** (§6.3). Slice 1's only pointer is a decision's landing place (`documentRef`), so
  there is nothing yet for an `Artifact` to hold. An artifact as an *input* — the mock the person showed, the
  screenshot — needs the ingestion slice to have somewhere to put its bytes, and that is where the type earns
  its place.
- **The rest of the host matrix** (OpenCode, Cursor, Codex, Pi), the menu-bar surface and the launch agent, the
  detector's quality evaluation on a fixed set of real sessions, and the migration that seeds the graph from
  claude-mem — which reuses this plan's confirmation surface.
