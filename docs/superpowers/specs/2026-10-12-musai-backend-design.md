# The backend: design

Date: 2026-10-12
Status: **draft, for review** — a reviewer reads this before you do; expect one round of questions back.
Builds on: `2026-10-12-musai-decision-loop-design.md` (whose next slice this is, and whose Critical this
retires) and `2026-10-12-musai-design.md` §10 (the helper) and §12 (models).
Source: the conversation of 2026-10-12 that followed PR #1.

## 1. Intent

The loop's first slice has every hook open the Norvo Lite file. Norvo Lite takes an exclusive lock per open, so
only one process may hold it: two hooks firing at once, or a hook firing while `review` waits for a keystroke,
and the later one fails to open, leaves a line on stderr and **loses the turn**. That is the one thing the design
forbids — only the queue may lose work — and it is a defect of that slice, not of the design, which already says
what the answer is (main design §10):

> Musai runs as a **background helper** — a launch agent with a menu-bar presence — that owns the Norvo Lite
> file; the SwiftUI app attaches to it. Hooks talk to the helper, so capture and injection work whether or not
> the app is open. The app is a view, not the host.

This slice is that process, and the layering is the one agreed on 2026-10-12: **hooks are thin proxies, the
helper is the backend, the window app and the agents are its clients.** The helper owns the file, runs the
curator's model, and serves everything else over one loopback endpoint.

## 2. Goals

1. **One process owns the file**, for its whole life. Nothing else opens it — not a hook, not the CLI, not the
   app. The lock stops being a hazard because it is never contended.
2. **A hook is a client.** It posts its payload and returns. It never writes, never opens the store, never
   starts anything, and its own failure can never fail the agent's session.
3. **One endpoint serves every client**: the hooks (capture and the session-start slice), the app (later), and
   the agents through MCP.
4. **Always up while the person works**, and visible: started at login, restarted when it dies, with a
   menu-bar presence that says what it is doing.
5. **The curator lives here**, off the request path, doing nothing at all when there is nothing to do.
6. **A failure is never silent.** The last slice's worst property was that a lost turn left no trace anywhere
   a person would look.

## 3. Non-goals

- **Not the window app.** The workspace, viewer, model manager and backup screens are a later slice. This one
  gives the backend a face, not a UI.
- **Not the whole MCP surface.** Search, authoring and work-state arrive with the slices that hold that data
  (the migration and the docs slice). This slice exposes two read tools, so that agents are clients from the
  first day and the shape is settled.
- **Not a network service.** Loopback only; no listening socket reachable from another machine.
- **Not the closed-loop dispatcher.** Handing a task to an agent and taking it back is its own slice.

## 4. Anti-goals

- **Heavy on the machine.** The helper idles at essentially no CPU: it is event-driven, it does not poll, and
  it holds no timer at all until there is a backlog to drain.
- **A silent single point of failure.** If it is not running, or the store will not open, or the queue is
  backing up, that is visible in the menu bar, in a log, and in a client's diagnostic — never in silence.
- **A second owner of memory.** There is no fallback in which a hook writes to the store itself. One owner is
  the whole point; a fallback would reintroduce the defect.
- **In the way.** No client waits on the model. A capture returns as soon as the event is durable.

## 5. Constraints

Inherited from the main design (§5) and unchanged: Norvo Lite as the only store, one file, macOS on Apple
Silicon, SwiftUI, local-first, host-agnostic.

Sharpened or added here:

- **One writer, and the engine enforces it.** Norvo Lite's exclusive file lock is the boundary we design for,
  not against. The helper takes it at start and keeps it.
- **The endpoint is loopback HTTP with a token.** Any local process can reach a loopback port, so "loopback
  only" is not "only me": every request carries `Authorization: Bearer <token>`, and the token lives in a 0600
  file in the Musai directory.
- **A hook's timeout is short and its failure is silent-but-logged.** A client that cannot reach the backend
  exits 0 with one diagnostic line; it never blocks the host past its own hook timeout (which is why the
  helper's own model timeout is shorter still).
- **One bundle, two processes.** `Musai.app` holds both the window app and the menu-bar agent, as a nested
  `Contents/Library/LoginItems/MusaiAgent.app` with its own `Info.plist` and `LSUIElement`. They ship together,
  so they cannot drift apart in version, but they run separately, so a UI bug or a window rebuild cannot take
  capture down. Their only coupling is the endpoint.
- **If the agent is not running, the app starts it.** Opening the app is the one moment a person is certainly
  present and certainly wants memory to work, so the app ensures the backend before it shows anything:
  `/health`, and on no answer, launchd, then a clear "backend not running" state with a repair action rather
  than a silent empty screen.
- **Not running is not the same as lost.** The helper is always on, so a client finding it down is a fault to
  repair rather than a normal state: the client asks launchd to start it and retries briefly. A capture is lost
  only when the helper cannot start at all — the store unopenable, or the agent quit — which is a state the
  person can see and fix. That is the honest form of "only the queue may lose work".
- **The store can enter a failed state** — Norvo makes an fsync failure fatal and needs a reopen. The helper
  detects that, reopens, and says so, because a client cannot.
- **The protocol is versioned.** A client and a helper of different versions must be able to say so rather
  than guess; a stale helper is a fact to display, not a puzzle to debug.

## 6. Components

| Piece | Where | Job |
| --- | --- | --- |
| The store, capture and curator | `MusaiCore` (built) | Unchanged in behaviour. Now called only by the helper. |
| The endpoint | `MusaiCore` (new: `MusaiEndpoint`) | A small router over the existing types: payload in, outcome out. In the library so the protocol is testable without a GUI or a launch agent. |
| The agent | `MusaiAgent`, nested in `Musai.app` | Opens the store once, listens, shows a menu-bar item, runs the curator. Thin: no protocol logic of its own. |
| The window app | `Musai`, `Musai.app`'s main executable (a later slice) | The workspace, viewer and control panel, as a client of the endpoint. |
| The CLI | `musai` (exists) | Becomes a client. `hook` posts; `review` reads and writes over the endpoint; `install --helper` registers the launch agent. |

The split follows the last slice's rule, learned the hard way: **anything a test must prove lives in
`MusaiCore`**, and the executables are wiring.

## 7. The protocol

Loopback HTTP, JSON. Clients learn where to connect from a published file (§8), not from a fixed port.

| Request | Carries | Returns |
| --- | --- | --- |
| `GET /health` | — | protocol version, store path, helper uptime, curator state, backlog depth, store state |
| `POST /capture` | **one already-normalized event** (§ "host adaptation", below) | `{ stored: "created" \| "duplicate" \| "ignored" }` |
| `GET /context?cwd=<path>` | the working directory | the slice text — empty body when there is nothing to say |
| `GET /events` | — | server-sent events: a proposal appears, a decision settles, the backlog changes |
| `GET /proposals` | — | what `musai review` lists, including the gap |
| `POST /proposals/{id}/{settle\|persist\|drop}` | the action, and a reference for `persist` | the decision's new state |
| `POST /admin/restart` | — | the helper exits; launchd brings it back (§8) |

A captured event is normalized, not a host's payload: `{kind, session, cwd, at, text?, tool?, target?, digest?}`.

**Host adaptation lives in the proxy, not the endpoint.** `musai hook` decodes the host's payload, reads the
transcript at `Stop`, and posts a normalized event. The core goes on knowing nothing about Claude Code — the
data-model plan's own invariant — and a new host is a new adapter in the CLI rather than a change to the
backend.

**MCP is stdio this slice.** `musai mcp` implements MCP for the hosts (universally supported) and reaches the
endpoint's ordinary operations for its two read tools: the slice, and the project's decisions. `POST /mcp` as
Streamable HTTP is deferred until a host needs it — initialize negotiation, sessions and SSE are a chunk of
protocol work with no user-visible gain while a stdio shim already reaches every host.

## 8. Lifecycle

- **Registration, as one app bundle.** `musai install [--library <path>]` assembles `~/Applications/Musai.app`
  from the built executables and the `Info.plist`s kept in the repository, because SwiftPM cannot produce an
  `.app` itself:

  ```
  Musai.app/Contents/
    Info.plist                                  the window app
    MacOS/Musai                                 the window app
    Library/LoginItems/MusaiAgent.app/          the menu-bar agent
      Contents/Info.plist                       LSUIElement = true
      Contents/MacOS/MusaiAgent
  ```

  It then writes `~/Library/LaunchAgents/dev.musai.agent.plist` with `RunAtLoad` and `KeepAlive`, pointing
  `Program` at the nested agent, and loads it. `--uninstall` takes the agent, the hooks and the bundle away.

  `~/Applications` rather than `/Applications` so no elevation is needed, and a stable path because the plist
  names the agent inside the bundle: **moving or deleting the bundle breaks the registration**, which the
  install and `musai doctor` both say out loud. During development the bundle is assembled into `.build/` and
  `musai` can run the agent from there; only `install` writes to `~/Applications`.
- **One store.** The helper serves exactly the store it was started with. `--library`/`MUSAI_LIBRARY` still
  choose it at install time; a client that points somewhere else reads the store path in `/health` and says so,
  rather than writing where it was not expected.
- **Discovery.** The helper picks an ephemeral port and writes `helper.json` in the Musai directory (0600: port,
  token, pid, protocol version, store path). A client that cannot connect reports that the backend is not
  running — a fact, not something a retry loop should hide.
- **Start.** Open the store, retrying with bounded backoff if something else holds it and saying so in its
  status; then the listener; then `helper.json`; then run.
- **Not running is not a lost event.** A client that cannot connect asks launchd to start the helper and
  retries briefly. If it still cannot reach it, it prints one diagnostic line and gives up — so a capture is
  lost only when the helper cannot start at all, which the person can see and fix.
- **Idle.** No timer unless there are undrained events. The drain is debounced (never more than once every few
  seconds) and always off the request path, so a slow model never delays a capture.
- **The app ensures the agent.** On launch the app reads `helper.json` and asks `/health`; if nothing answers
  it starts the agent through launchd and waits briefly, because the person opening the app is the one moment
  memory must work. If that fails it shows the backend's state and offers a repair, rather than an empty
  workspace that looks like lost data.
- **The drain resolves each event's project from its session.** The queue is global and a hook's `cwd` no
  longer supplies context, so `UndrainedEvents` stops taking a project and each event's session supplies it,
  with proposals filed per project. This is the previous review's I3, which this slice makes mandatory rather
  than deferred.
- **Failure.** A crash is a launchd restart. An engine failure state is detected, the store reopened, and the
  status updated. A client that finds no helper says so once.
- **Version skew.** The protocol version is `major.minor`. A client refuses to post to a helper with a different
  **major** and reports it; a different minor is fine, because the protocol only grows. The menu bar shows
  "restart needed" when the health handshake says so.
- **Quit.** The menu bar's Quit asks launchd to stop *and keep it stopped* (`launchctl bootout`), because
  `KeepAlive` would otherwise bring it straight back. The item says so, and `install --helper` brings it back.
- **The log.** `~/Library/Logs/Musai/helper.log`, written through `os_log` and mirrored to a file bounded to the
  last few thousand lines, and read by `musai doctor` together with `helper.json` and the health payload so
  that "is the backend up, and if not why" has an answer a person can read.

## 9. What changes in what is already built

- **`musai hook` becomes a client and the host adapter.** It decodes the payload, reads the transcript at
  `Stop`, normalizes, posts, and prints what comes back for `SessionStart`. `HookRunner`'s host-agnostic half —
  the dispatch and the outcomes — moves behind the endpoint; the payload decoding and the transcript read stay
  in the CLI, where hosts live.
- **`MusaiCapture` and `ProposalCurator` are unchanged in behaviour**, and are called only by the helper — with
  one exception, `UndrainedEvents`, which stops taking a project and gains a per-event resolution (§8). That is
  the I3 fix, and it changes three curator tests.
- **`ReviewSession` gains a path over the endpoint** and keeps its shape; `musai review` uses the endpoint
  instead of opening the store.
- **The installed hooks are unchanged**, except that their commands no longer need `--library`.
- **PR #1's Critical is retired by construction**: no hook opens the file, and the model call happens inside
  the process that owns it.

## 10. What is left to the builder

- The listener's shape in Swift: `URLSession` reads but cannot serve, so `NWListener` or a small socket wrapper.
- The menu-bar item's contents: status, what the curator is doing, backlog, restart-needed, quit.
- Whether the curator ever runs on a timer, or only on a capture or a backlog signal.
- The SSE event names and payloads.
- The launch agent's label and its plist's exact keys.
- The two MCP tools' schemas, and the stdio server's framing.
- Whether `/health` should also report the store's schema version, so a client can say "the backend is up but
  too old for this binary".

## 11. Calls made while writing this (for review)

- **An always-on launch agent, not on-demand socket activation.** The person's call, 2026-10-12: *"a
  process/service that is always on is easier for the user."* On-demand was the elegant option and was rejected
  for predictability — one fewer failure mode to reason about, at the cost of a resident process that does
  nothing when idle.
- **A minimal menu-bar item in this slice**, with the window app later: the backend needs a face before it has a
  UI.
- **Loopback HTTP with a token file, one endpoint for every client**, rather than a Unix socket (which would
  force the app to write its own socket client) or per-client transports.
- **Server-sent events** for live updates rather than WebSockets or polling.
- **An ephemeral port published in `helper.json`**, not a fixed one: no clashes, and the file is also how every
  client finds the token. The cost is that `curl` needs the file; `musai doctor` covers that.
- **The proxy normalizes; the core stays host-agnostic.** A new host is a new adapter in the CLI, not a change
  to the backend.
- **MCP is stdio this slice**, with `/mcp` over HTTP deferred until a host needs it; the shim reaches every host
  without implementing Streamable HTTP.
- **The hook starts the helper when it is not up**, so "always on" heals itself, and loss needs a helper that
  cannot start — which is visible.
- **Quit boots the agent out**, because `KeepAlive` would otherwise undo it immediately.
- **The protocol version is `major.minor`**: a major mismatch is refused and reported; a minor one is assumed
  additive.
- **One `.app` bundle holding both processes**, assembled at install time, rather than a bare executable or
  two separate bundles — the person's call, 2026-10-13: *"I would prefer them to be one bundle, but separate
  processes, and if you start the app without the taskbar tool, the app launches the taskbar tool."* One bundle
  means the agent and the app can never drift in version and the build path is shared; separate processes mean
  the backend does not depend on the UI process's health; and the app starting the agent puts the recovery in
  the one place a person is certain to be. The agent is a nested `.app` rather than a second bare executable in
  `Contents/MacOS`, so it gets its own `Info.plist` and `LSUIElement` instead of relying on a runtime activation
  policy.
- **The helper's log is a named file** plus `musai doctor`, because the last slice's worst property was
  silence.
- **The curator drains off the request path, debounced, with no timer when idle.**
- **The endpoint's router and handlers live in `MusaiCore`**, so the protocol is tested without a GUI or a
  launch agent.
