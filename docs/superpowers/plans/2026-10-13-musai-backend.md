# The backend: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A menu-bar agent that owns the Musai store, serves one loopback endpoint to every client, and runs the curator — with the hooks reduced to clients, so no other process ever opens the file.

**Architecture:** `MusaiCore` gains an endpoint (a pure request/response router over the types it already has) and a listener that serves it; the agent executable owns the store and shows a status item; the CLI keeps the host adapters and becomes a client; `musai install` assembles the one `.app` bundle and registers the launch agent.

**Tech Stack:** Swift 6.1 tools, macOS 14+ arm64, Swift Testing, NorvoLite on Norvo Lite, `Network.framework` for the listener, `URLSession` for the clients, AppKit for the status item.

**Spec:** `docs/superpowers/specs/2026-10-12-musai-backend-design.md` — read it with this; its protocol table, lifecycle and calls are the interfaces below. It builds on `2026-10-12-musai-decision-loop-design.md` (whose Critical this retires) and `2026-10-12-musai-design.md`.

## Global Constraints

- macOS, Apple Silicon only (`.macOS(.v14)`); Swift 6.1 tools; NorvoLite as the only store.
- **Exactly one process opens the store:** the agent. No fallback lets a client open it.
- The endpoint is **loopback HTTP** and every request carries `Authorization: Bearer <token>`; the token is a 0600 file and so is `helper.json`.
- The protocol version is **`major.minor`**: a client refuses a different major and reports it; a different minor is assumed additive.
- **`MusaiCore` knows nothing about Claude Code.** Host payloads and the transcript read live in the CLI. Anything a test must prove lives in `MusaiCore`; executables are wiring.
- **A client's failure never fails the agent's session**, and it never blocks past the host's hook timeout. Our own model timeout stays 60 s (`ModelConfiguration.default`), under the host's 120 s.
- The bundle is `~/Applications/Musai.app`, with the agent nested at `Contents/Library/LoginItems/MusaiAgent.app` (`LSUIElement = true`), and the launch agent at `~/Library/LaunchAgents/dev.musai.agent.plist` with `RunAtLoad` and `KeepAlive`.
- The agent idles at essentially no CPU: **no timer runs unless there is an undrained event**.
- Logs go to `~/Library/Logs/Musai/agent.log`, bounded to the last 2 000 lines.

## Review Focus

The five inputs and conditions the design implies but that no task's tests otherwise exercise. Each is pinned
by the test named beside it, in the task that owns the code.

1. **A capture arriving while the curator is mid-model-call** — the post must return immediately, the backlog only grows, and no lock is contended. → Task 4.
2. **A stale `helper.json`** (a crashed agent left it; the port now belongs to something else) — a client must not post the person's words to a stranger; it reports and asks launchd to start the agent. → Task 3.
3. **A second agent started by hand** — it must not open the store twice; it says so and exits non-zero. → Task 5.
4. **The store unopenable** (fatal engine state, permissions) — `/health` says so, the status item shows it, and a hook gets a diagnostic rather than silence. → Task 7.
5. **The agent dying mid-request** — a client's post is either stored or reported, never half-written, and its retry is safe. → Task 2, Task 9.

---

### Task 1: The endpoint's protocol

**Files:**
- Create: `Sources/MusaiCore/MusaiEndpoint.swift`, `Sources/MusaiCore/EndpointState.swift`,
  `Sources/MusaiCore/EndpointWire.swift`
- Create: `Sources/MusaiCore/CuratorController.swift`
- Test: `Tests/MusaiCoreTests/EndpointTests.swift`

**Interfaces:**
- Consumes: `MusaiCapture`, `ProposalCurator`, `MusaiSlice`, `ReviewSession`, `MusaiActors`.
- Produces: the wire types every client shares — `EndpointRequest { method, path, query, body, token }`,
  `EndpointResponse { status, body, contentType }`, `NormalizedEvent { kind, session, cwd, at, text?, tool?, target?, digest? }`
  (the `POST /capture` body), `CaptureOutcome { created, duplicate, ignored }`, and
  `EndpointHealth { protocolVersion, storePath, startedAt, storeState, backlogDepth, curatorState }`. They live here,
  in `EndpointWire.swift`, because the endpoint serves them and Task 3's client consumes them.
  Plus `MusaiEndpoint { init(db:library:state:curator:token:); func respond(to:) async -> EndpointResponse }`,
  `EndpointState` (an actor: `startedAt`, `storePath`, `storeState`, `backlogDepth`, `curatorState`, `statusText`),
  `CuratorController { init(db:detector:sleep:debounce:); func noteCapture() async; func drainNow() async throws -> Int }`.

`GET /events` is **not** in this slice: nothing here consumes a stream (`review` is one-shot), so the router stays
pure request/response and SSE arrives with the window app.

- [ ] **Step 1: Write the failing tests `Tests/MusaiCoreTests/EndpointTests.swift`**

Seven tests, each one request: `healthReportsTheStoreAndTheBacklog` (200, `storePath` equals the library's, `protocolVersion == "1.0"`, `backlogDepth` equals the undrained event count); `captureStoresAnEvent` (`POST /capture` with a normalized user turn → `{"stored":"created"}`, and the `Utterance` exists); `captureIsIdempotent` (the same body twice → `created` then `duplicate`, one row); `captureRefusesABadToken` (401, and nothing stored); `contextReturnsTheSlice` (a settled decision → the body contains its title; an empty store → 200 with an empty body); `proposalsListsAndSettles` (`GET /proposals` lists the gap, `POST /proposals/{id}/settle` moves it); `theRouterAnswersAnUnknownPathWith404` (and a wrong method with 405).

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter EndpointTests`
Expected: FAIL — `cannot find 'MusaiEndpoint' in scope`.

- [ ] **Step 3: Write the three files**

`MusaiEndpoint.respond` is a switch on `(method, path)`: `GET /health`, `POST /capture`, `GET /context`, `GET /proposals`, `POST /proposals/{id}/{settle|persist|drop}`, `POST /admin/restart`, else 404/405. It checks the token first and returns 401 when it does not match. `POST /capture` decodes a `NormalizedEvent` (Task 3 defines it), calls `MusaiCapture`, and returns `created`/`duplicate`/`ignored`. `POST /admin/restart` returns 200 and then ends the process, which is the agent's business (Task 5), so this endpoint reports through `EndpointState` that a restart was asked for.

`CuratorController` holds the drain off the request path: `noteCapture()` starts a debounce task (never more than one per `debounce` interval) and sets `curatorState` to `pending`; `drainNow()` runs `ProposalCurator.drain` and clears it. `sleep` is injectable so a test drives time rather than waiting.

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test --filter EndpointTests`
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/MusaiCore Tests/MusaiCoreTests/EndpointTests.swift
git commit -m "feat: the endpoint's protocol, one request at a time"
```

---

### Task 2: The listener, the record and the token

**Files:**
- Create: `Sources/MusaiCore/HelperRecord.swift`, `Sources/MusaiCore/EndpointListener.swift`
- Test: `Tests/MusaiCoreTests/ListenerTests.swift`

**Interfaces:**
- Consumes: Task 1's `MusaiEndpoint`, `EndpointState`.
- Produces: `HelperRecord { port: UInt16, token: String, pid: Int32, protocolVersion: String, storePath: String }` with `write(to:)`, `static read(from:)`, `static var defaultURL: URL`, and `isAlive: Bool` (the pid exists); `MusaiToken.new() -> String` and `MusaiToken.loadOrCreate(at:)`; `EndpointListener { init(endpoint:host:port:); func start() throws -> UInt16; func stop() }`.

- [ ] **Step 1: Write the failing tests `Tests/MusaiCoreTests/ListenerTests.swift`**

Five tests: `theListenerServesTheEndpoint` (start on port 0, a real `URLSession` request to `/health` with the token → 200 and the store path); `aBadTokenIsRefused` (→ 401); `theRecordRoundTripsAndIsPrivate` (write then read → equal, and the file's permissions are 0600); `aDeadPidsRecordIsNotAlive` (write a record with a pid that cannot exist → `isAlive == false`); `aSecondListenerOnTheSamePortFails` (start one, then a second on its port → throws).

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter ListenerTests`
Expected: FAIL — `cannot find 'EndpointListener' in scope`.

- [ ] **Step 3: Write the two files**

`EndpointListener` wraps `NWListener` on `127.0.0.1`; each connection reads one HTTP/1.1 request (headers plus a `Content-Length` body, bounded to 32 MiB like a hook payload), parses it into an `EndpointRequest`, awaits `endpoint.respond`, and writes the response. `start()` returns the port the system chose when `port` is 0. `stop()` cancels the listener and any open connections.

`HelperRecord.write` writes JSON with permissions 0600; `MusaiToken.loadOrCreate` generates 32 random bytes as hex and writes them 0600, returning the existing value when the file is already there.

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test --filter ListenerTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/MusaiCore Tests/MusaiCoreTests/ListenerTests.swift
git commit -m "feat: the listener, the record and the token"
```

---

### Task 3: The CLI becomes a client, and keeps the host adapters

**Files:**
- Create: `Sources/MusaiCore/NormalizedEvent.swift`, `Sources/MusaiCore/MusaiClient.swift`
- Create: `Sources/musai/HostAdapter.swift`
- Modify: `Sources/musai/MusaiHook.swift`, `Sources/MusaiCore/HookRunner.swift` (delete the store-touching half)
- Test: `Tests/MusaiCoreTests/ClientTests.swift`, `Tests/MusaiCoreTests/HostAdapterTests.swift`

**Interfaces:**
- Consumes: Task 2's `HelperRecord`, `MusaiToken`.
- Produces: `NormalizedEvent { kind: EventKind, session: String, cwd: String, at: Date, text: String?, tool: String?, target: String?, digest: String? }` (`Codable`); `MusaiClient { init(record:token:); func health() -> EndpointHealth?; func capture(_:) async throws -> CaptureOutcome; func context(cwd:) async throws -> String?; func proposals() async throws -> [Proposal]; func apply(_:to:) async throws }`; `HostAdapter.events(for payload: HookPayload, at: Date) throws -> [NormalizedEvent]`.

- [ ] **Step 1: Write the failing tests**

`HostAdapterTests` (4): a `UserPromptSubmit` payload becomes one `userTurn` event carrying the person's words; a `PostToolUse` payload becomes one `toolUse` event with the tool, the target and a digest, and **no text**; a `Stop` payload with a transcript fixture becomes one `agentTurn` event with the transcript's text; a payload for an unknown event becomes no events.

`ClientTests` (5): a capture against a live in-process listener (Task 2) is stored; the same capture twice reports `duplicate`; `context` returns the slice the endpoint would; **`aStaleRecordIsReportedRatherThanUsed`** — a record whose port is closed, with a live-looking pid, makes `health()` return `nil` and leaves the store untouched, and the caller is told to start the agent; and **`aMajorVersionMismatchIsRefusedNotGuessed`** — a health payload whose `protocolVersion` is `2.0` makes the client refuse to post and report it, while `1.7` posts (a minor mismatch is assumed additive).

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter "HostAdapterTests|ClientTests"`
Expected: FAIL — `cannot find 'HostAdapter' in scope`.

- [ ] **Step 3: Write the files, and cut the store out of the CLI**

`HostAdapter` owns everything host-specific: the payload decode (already there), the `Stop` transcript read (already there), and the mapping into `NormalizedEvent`. `MusaiHook` reads `helper.json`, builds a `MusaiClient`, and — for `SessionStart` — prints what `context` returns, wrapped in `MusaiSlice.additionalContext`. When the record is missing or stale it runs `launchctl kickstart gui/<uid>/dev.musai.agent`, waits up to two seconds for `/health`, and tries once more; if that fails it prints one diagnostic line and exits **0**.

`HookRunner` loses its store half: `MusaiCapture` is no longer reachable from the CLI, and the type's remaining job is the dispatch table the adapter mirrors. Delete what is left rather than keep it.

- [ ] **Step 4: Run the whole suite**

Run: `swift test`
Expected: PASS. The end-to-end test from the decision-loop plan will need its `HookRunner` usage rewritten to a client against an in-process listener; that rewrite is part of this task.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: the CLI is a client, and the host adapters stay in the CLI"
```

---

### Task 4: The drain, per project, off the request path, and a queue that expires itself

**Files:**
- Modify: `Sources/MusaiCore/operations/fragments.nql` (`EventBits` gains `session { project { slug } }`)
- Modify: `Sources/MusaiCore/ProposalCurator.swift` (`drain(as:)`, no project argument)
- Test: `Tests/MusaiCoreTests/CuratorTests.swift`, `Tests/MusaiCoreTests/EndpointTests.swift`

**Interfaces:**
- Consumes: Task 1's `CuratorController`.
- Produces: `ProposalCurator.drain(as actor: Actor) async throws -> Int` — files each proposal under the project of the session its event belongs to. `CuratorController` gains `curatorState` transitions a test can observe, and a `drainCount` for the debounce tests.

- [ ] **Step 1: Write the failing tests**

In `CuratorTests`: **`theDrainFilesEachEventUnderItsOwnProject`** — two projects, one turn captured in each, a stub detector that proposes per event, assert each decision's `project.slug` is its own; the three existing curator tests change to the new signature.

In `EndpointTests`: **`aCaptureDuringAModelCallReturnsAtOnce`** — a detector that sleeps until a test releases it, a `drainNow()` started, then a `POST /capture`; assert the capture returns `created` while the drain is still running, and that the backlog grew rather than the request waiting. And **`theDebounceCollapsesABurst`** — five `noteCapture()` calls within the injected window drive one drain.

And for the queue's own retention: **`anEventOlderThanTheRetentionWindowIsGone`** — record an event whose `at` is 40 days ago and one from now, drain, and assert only the recent one is ever returned (the queued row is gone, not merely undrained).

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter "CuratorTests|EndpointTests"`
Expected: FAIL — `extra argument 'project'` / missing `drainCount`.

- [ ] **Step 3: Write the change**

The curator groups `UndrainedEvents` by the event's session's project, calls the detector per group (its prompt says "one working session"), then writes the proposals **and marks their events drained in one `db.transaction`** — a crash can neither double-file a decision nor half-file it, and the model call stays outside the transaction so it never holds the writer. A detector that throws still leaves everything undone.

The queue also expires itself, which is the design's §6.2 requirement and the last review's deferred I5: add
`@partition(by: at, every: 1d, keep: 30d)` to `Event` in a `0004_event_expiry.nql` migration. Partitioning is
the engine's own mechanism — expiring a period drops its keyspaces in one pass rather than deleting rows — and
`Event` is the only type it should apply to: the durable `Utterance` and every curated object must never expire.

*If the engine refuses `@partition` on a type that already has rows, the fallback is the one the design names:
a `deleteDrainedEvents(before:)` mutation and a pass that runs it no more often than once a day. The step is to
try the partitioned form first and find out, not to guess.*

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test --filter "CuratorTests|EndpointTests"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "fix: the drain files each event under its own project, off the request path"
```

---

### Task 5: The agent, the status item and the bundle

**Files:**
- Create: `Sources/MusaiCore/MusaiAgent.swift`, `Sources/MusaiCore/MusaiBundle.swift`
- Create: `Sources/musai-agent/main.swift`
- Create: `Resources/App-Info.plist`, `Resources/Agent-Info.plist`
- Test: `Tests/MusaiCoreTests/AgentTests.swift`, `Tests/MusaiCoreTests/BundleTests.swift`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces: `MusaiAgent { init(libraryURL:options:) throws; func start() throws -> UInt16; func statusText() -> String; func stop() }` — opens the store once, retries a held lock with bounded backoff, starts the listener, writes the record and the token, starts the curator, and reports state; `MusaiBundle.assemble(app:agent:into:resources:) throws -> URL` — writes the bundle tree and returns its root.

- [ ] **Step 1: Write the failing tests**

`AgentTests` (4): `itOpensTheStoreOnceAndServes` (start an agent on a temp store, request `/health`, assert the store path and that the record exists); **`aSecondAgentRefusesToOpenTheStoreOnTheSameFile`** — start one, then a second on the same path → `start()` throws with a message naming the store, and the first still answers; `statusText` for `running`, `backlog(n)`, `storeFailed`, `needsRestart`; and `itReopensAfterAFailedStoreState` — with a stub that reports a fatal state once, assert the agent reopened the store and set `needsRestart` rather than dying.

`BundleTests` (3): `assemble` produces `Contents/Info.plist`, `Contents/MacOS/Musai`, `Contents/Library/LoginItems/MusaiAgent.app/Contents/{Info.plist,MacOS/MusaiAgent}`; the nested agent's `Info.plist` parses with `LSUIElement == true` and `CFBundleExecutable == "MusaiAgent"`; the outer `Info.plist` names `Musai` and carries a version equal to the package's.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter "AgentTests|BundleTests"`
Expected: FAIL — `cannot find 'MusaiAgent' in scope`.

- [ ] **Step 3: Write the files**

`musai-agent/main.swift` is wiring: create the agent, build the `NSStatusItem` in an `NSApplication` (the `LSUIElement` plist hides the Dock icon), set its title from `statusText()` on a timer that only runs while a state changes, put Quit behind `launchctl bootout`, and run. The status item's own behaviour is not unit-tested; its text is, through `statusText()`.

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test --filter "AgentTests|BundleTests"`
Expected: PASS, 7 tests.

- [ ] **Step 5: Build the agent by hand and look at it**

Run: `swift build --product musai-agent` then the executable directly with `--library /tmp/musai-agent-test.norvo`; a status item appears, `/health` answers through the record, and Quit makes it stay quit. This is the one step a test cannot do.

- [ ] **Step 6: Commit**

```bash
git add Sources Resources Tests
git commit -m "feat: the agent, its status item, and the bundle it lives in"
```

---

### Task 6: Install and uninstall

**Files:**
- Modify: `Sources/MusaiCore/MusaiInstall.swift`
- Modify: `Sources/musai/MusaiHook.swift` (the `install` subcommand)
- Test: `Tests/MusaiCoreTests/InstallTests.swift`

**Interfaces:**
- Consumes: Task 5's `MusaiBundle.assemble`.
- Produces: `MusaiInstall.agentPlist(executable:label:) -> Data`; `MusaiInstall.installBundle(app:agent:into:launchAgentsDirectory:library:) throws -> URL`; `MusaiInstall.uninstall(bundle:launchAgentsDirectory:) throws`.

- [ ] **Step 1: Write the failing tests**

Five tests: `theAgentPlistSaysRunAtLoadAndKeepAlive` (parse it: `RunAtLoad`, `KeepAlive`, `Program` pointing at `…/MusaiAgent.app/Contents/MacOS/MusaiAgent`, `Label == "dev.musai.agent"`); `installingTwiceChangesNothing` (the plist and the bundle are byte-identical after a second install); `installWritesTheBundleWhereItWasAsked`; `uninstallRemovesThePlistAndTheBundle`; and `installingKeepsTheClaudeCodeHooks` — the hooks from the decision-loop plan are still merged, and `--uninstall` removes both.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter InstallTests`
Expected: FAIL — `cannot find 'agentPlist'`.

- [ ] **Step 3: Write the change**

`musai install [--library <path>] [--app <dir>]` assembles into `~/Applications/Musai.app` by default and writes the launch agent into `~/Library/LaunchAgents/`, then merges the hooks as it already does. `--uninstall` boots the agent out, removes the plist and the bundle, and unmerges the hooks. It prints what it did, including the warning that moving the bundle breaks the registration.

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test --filter InstallTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: install the bundle and the agent, reversibly"
```

---

### Task 7: `musai doctor`, and the log

**Files:**
- Create: `Sources/MusaiCore/MusaiDiagnostics.swift`, `Sources/MusaiCore/MusaiLog.swift`
- Modify: `Sources/musai/MusaiHook.swift` (the `doctor` subcommand)
- Test: `Tests/MusaiCoreTests/DiagnosticsTests.swift`

**Interfaces:**
- Produces: `MusaiDiagnostics.screen(record:health:logTail:bundlePath:) -> String` (pure); `MusaiLog { init(url:limit:); func write(_ line: String); func tail(_ lines: Int) -> [String] }`.

- [ ] **Step 1: Write the failing tests**

Four tests: no record → a screen saying the agent has never run, and how to install it; a record whose pid is gone → "not running (pid 1234 is gone)" plus the last log lines; a healthy `/health` → the store path, uptime, backlog, curator state, protocol version; **`anUnopenableStoreIsVisible`** — a health payload with `storeState == "failed"` → the screen says the store could not be opened and names the log. Plus `MusaiLog` keeps only the last `limit` lines and creates its directory.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter DiagnosticsTests`
Expected: FAIL — `cannot find 'MusaiDiagnostics' in scope`.

- [ ] **Step 3: Write the files**

The agent writes its log through `MusaiLog` (and `os_log` alongside). `doctor` prints `MusaiDiagnostics.screen` from the record, a `/health` request when one answers, and the log's tail.

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test --filter DiagnosticsTests`
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests
git commit -m "feat: musai doctor, and a log a person can read"
```

---

### Task 8: The MCP stdio server

**Files:**
- Create: `Sources/MusaiCore/MusaiMCP.swift`
- Modify: `Sources/musai/MusaiHook.swift` (the `mcp` subcommand)
- Create: `docs/mcp.md`
- Test: `Tests/MusaiCoreTests/MCPTests.swift`

**Interfaces:**
- Consumes: Task 3's `MusaiClient`.
- Produces: `MusaiMCP { init(client:); func handle(_ message: Data) async -> Data? }` — one JSON-RPC message in, one out (or `nil` for a notification), implementing `initialize`, `tools/list`, `tools/call`, and `notifications/initialized`.

- [ ] **Step 1: Write the failing tests**

Six tests: `initializeNamesTheServerAndItsTools` (serverInfo + `tools` capability); `toolsListHasContextAndDecisions` (two tools with JSON schemas); `callingContextReturnsTheSlice` (proxies `GET /context` with the argument's cwd); `callingDecisionsReturnsTheProjectsDecisions` (proxies `GET /proposals`-style read, filtered to settled); `anUnknownMethodIsAJSONRPCError` (`-32601`, and a `nil`-safe shape); `aNotificationProducesNoResponse`.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter MCPTests`
Expected: FAIL — `cannot find 'MusaiMCP' in scope`.

- [ ] **Step 3: Write the server**

`musai mcp` reads line-delimited JSON-RPC from stdin, writes responses to stdout, and never writes anything else there. Each tool call becomes an endpoint request; a failure becomes a tool error rather than a crash, and the server stays up.

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test --filter MCPTests`
Expected: PASS, 6 tests.

- [ ] **Step 5: Write `docs/mcp.md`**

The two tools, their arguments, and the host configuration snippet that runs `musai mcp` (stdio), with a line on why stdio rather than the HTTP transport this slice.

- [ ] **Step 6: Commit**

```bash
git add Sources Tests docs
git commit -m "feat: the MCP stdio server, so agents are clients too"
```

---

### Task 9: The loop, end to end, through the agent

**Files:**
- Modify: `Tests/MusaiCoreTests/LoopEndToEndTests.swift`
- Modify: `README.md`
- Test: `Tests/MusaiCoreTests/AgentEndToEndTests.swift`

**Interfaces:**
- Consumes: every earlier task.
- Produces: nothing new — the acceptance test, and the manual checklist.

- [ ] **Step 1: Write the failing test**

One test that starts a real agent (Task 5) on a temporary store with a stubbed model transport, then drives the whole loop through `MusaiClient` and the endpoint: a first `/context` is empty; a `UserPromptSubmit` capture (the person's words); a `PostToolUse` capture whose result must not be stored; a `Stop` capture from a transcript fixture; the debounced drain produces a proposal; `POST /proposals/{id}/persist` settles it with a reference; `/context` now contains the decision and its reference; the backlog is empty and no event was lost. Plus one assertion for Review Focus 5: a second `POST /capture` during a slow drain is stored, not dropped.

- [ ] **Step 2: Run it to verify it fails, then passes**

Run: `swift test --filter AgentEndToEndTests`
Expected: FAIL first, then PASS once the pieces are wired.

- [ ] **Step 3: Run the whole suite**

Run: `swift test`
Expected: PASS, every suite.

- [ ] **Step 4: Rewrite the manual checklist in `README.md`**

`musai install`, work a session in Claude Code, `musai doctor` if anything looks wrong, `musai review`, then a new session to see what the agent is handed. End with the question this slice exists to answer — **did the backend stay invisible until you went looking for it?** — and say to record the answer in the next design.

- [ ] **Step 5: Commit**

```bash
git add Tests README.md
git commit -m "test: the loop end to end, through the agent"
```

---

## What this plan leaves

- **`GET /events` and the window app.** SSE arrives with the app that consumes it; the window app is the next slice, and it is the one that turns the endpoint into a UI.
- **The app's half of "if the agent is not running, the app starts it".** The agent is startable on demand from
  this slice (that is what `launchctl kickstart` in Task 3 exercises), but the app that would do it on launch is
  the next slice. Until then, a hook is what starts the agent, and `musai doctor` is what explains it.
- **`SMAppService` registration.** This slice writes the launch agent plist itself, which is visible and reversible; the sanctioned API can replace it later without changing the protocol.
- **The closed-loop dispatcher** (main design §11), and everything the other designs defer: the claude-mem migration, the source readers, artifacts.
- **The store's schema version in `/health`**, which the design leaves to the builder.
