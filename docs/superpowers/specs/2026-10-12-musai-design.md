# Musai: design

Date: 2026-10-12
Status: approved 2026-10-12
Builds on: `NorvoDB` — `docs/superpowers/specs/2026-10-04-norvo-lite-prototype-design.md`
(the app the Lite spec requires but defers) and `2026-10-08-swift-package-design.md`
(how an app embeds Lite). Those cover what the app requires *from* Lite; this covers
the app itself.
Source: the conversation of 2026-10-12 that named it Musai.

## 1. Intent

Musai is a local-first workspace where one person and their AI agents take projects
from an idea, through specs and plans, to finished — with long-term memory as the
connective tissue, and eventually a closed loop that carries the work itself.

Two pains drive it:

1. **Collaborating with an AI on ideas and projects** needs memory that outlives the
   context window and reaches across projects and across months.
2. **claude-mem, the current tool, is unsatisfying.** It runs a metered cloud observer
   (whose allowance is the thing that keeps running out) and keeps data in a vendor's
   world rather than the user's.

Musai is the app NorvoDB's Lite prototype spec calls for but defers ("The app gets its
own spec after this one"). It is its own brand and its own repository — *not* a Norvo
product — and it embeds Norvo Lite as its engine.

## 2. Goals

**v1 — both are required to count:**

1. **Collaborate** with the AI on ideas and projects.
2. **Sunset claude-mem**: replace it end to end, including migrating the existing
   history, so the user can uninstall it and work the same or better — data on their
   machine, no metered observer.

**After v1 (each its own slice):**

3. **Closed-loop automation.** Musai lets a project's implementation be automated: the
   agent is handed its task, implements it, and reports completion back into Musai,
   updating progress live — a full software-development loop. Automation lives here and
   in the curator, not across the whole app.
4. **Secrets manager.** Considered, parked; a different trust domain.

## 3. Non-goals

- Not a Norvo-branded product; separate brand, separate repo.
- No server, no multi-user, no sync service. Networking is limited to user-initiated
  actions: model downloads and backups/exports.
- Not a general note-taking or PKM tool — it is scoped to projects and the AI
  collaboration around them.

## 4. Anti-goals

A version that technically works but is:

- **clunky to work with** — friction in capture, injection, authoring, or the app; or
- **heavy on system resources** — CPU, RAM, disk, or battery.

These prune the design. Several otherwise attractive choices are dropped because of
them, and both are made testable (section 15).

## 5. Constraints

- **Local-first.** Data lives on the machine. Agent inference stays local; there is no
  metered cloud observer by default. User-initiated model downloads and backups are the
  only networking.
- **Host-agnostic.** Many agent hosts are first-class, not just one: Claude Code,
  OpenCode, Cursor, Codex, Pi, and others to come. Nothing may depend on a single host.
- **Engine: Norvo Lite.** Single-file, embedded through the NorvoLite Swift package and
  its C ABI. No second datastore.
- **Platform: macOS, Apple Silicon only**, SwiftUI. (MLX rules out Intel.)
- **Cheap by construction.** One store; bounded injection; a curator that idles.
- **Own your data.** The store is a single portable file, and backing it up off the
  machine is a first-class, user-initiated feature.

## 6. The model: a project graph, aligned with spec-driven development

Memory is *situated*, not a stream. Everything is an entity with typed links. A memory
attaches to the thing it is about, and links cross projects, so "something we discussed
months ago in another project" is a **graph edge**, not a search.

The entities follow the shape that spec-driven-development (SDD) workflows already use,
so Musai can export into them and not fight them — the common arc is *brief →
requirements → design → tasks*. The builder owns the exact schema.

| Entity | What it is |
| --- | --- |
| Project | A unit of work. Name, status, repo link. |
| Idea | A thought that may become a project or a feature; can link to the project it spun off from. |
| Requirement / Spec | What must be true; the design document (as NorvoDB's own `docs/superpowers/specs` are). |
| Plan | An implementation plan. |
| Task | A work item and its state — the progress tracking — that an agent can be handed. |
| Decision | A choice and its rationale. |
| Memory | A note or observation; ambient or authored; attaches to any entity. |
| Session | A work session with an agent; long-lived (see section 8). |
| Actor | user, agent, or system — who wrote a thing (Norvo has actors). |

Links include Project → Spec → Plan → Task, Idea → spawned Project, Memory → subject,
and cross-project references. Specs and plans are authored in Musai (section 9) and
exported to the repo when they are ready for implementation.

A session is **bound to a Project** by its working directory and git remote; the first
session in an unknown directory prompts to create or link a Project.

## 7. Storage

One Norvo Lite file per Musai library, holding every project. Musai uses Lite's
components, refs and backlinks, per-field history (time travel), live queries, native
full-text and vector search — and, for capture, **Lite's log and change feed as the
queue** (section 8).

This is the anti-clunk, anti-weight move. claude-mem keeps sessions and observations in
a ~1 GB SQLite file, plus a separate Chroma vector store, plus a full-text index. Musai
keeps all of it in **one** file, with the same capabilities and none of the pile.

## 8. Capture — a queue fed by hooks, drained by the curator (load-bearing)

The passive watcher is what makes claude-mem uninstallable: automatic memory with no
effort. It replaces claude-mem's metered cloud observer with a **local curator**, and it
is decoupled from the session:

- **Hooks append** a normalized event stream — recorded by Musai's own hooks from every
  host — to a **queue inside Norvo** (Lite's log/change feed is the queue). Host
  transcript files are not parsed; their formats are version-coupled and brittle.
- **Sessions are long-lived.** The user may keep one session open for weeks, so capture
  is continuous, not tied to a session ending.
- **The curator drains the queue as resources allow** — throttled, idle-friendly, never
  an always-hot process. Because the queue decouples it, a busy machine does not lose
  events; the backlog simply waits.
- The curator **files each ambient memory against the bound project** (and session and
  actor), not into a flat pile. It is the automation dial: how aggressively it captures,
  and what it keeps, is tunable, and the app exposes its output so the user can see and
  prune it (per-field history keeps what it changed).

**Migration.** v1 imports the existing claude-mem history: reverse its schema, map
observations, sessions and work-state onto the graph, and carry embeddings where
possible.

## 9. Authoring — the differentiator

The user and the agent **promote** the important things — a decision, a spec, an idea —
into first-class graph objects. Authoring is one MCP tool call, and one keystroke in the
app. Authored objects are the high-signal layer; ambient capture is the backfill.

Specs and plans are **authored in Musai**, then exported into the repo when the project
is ready to implement. The file-based flow that NorvoDB uses today remains the
destination, not the source.

## 10. Integration with the hosts

Musai presents, through a **host abstraction** with one adapter per host (Claude Code,
OpenCode, Cursor, Codex, Pi, …):

- an **MCP server** — search, read, author, work-state;
- **hooks** — capture hooks that append to the queue, and a session-start hook that
  injects context;
- a **local endpoint** (loopback) for the app and the hosts, replacing claude-mem's
  worker port.

**On connect**, Musai hands the agent context *and instructions*: what Musai is, what it
holds about this project, and how to automate it — so agents can drive memory and other
features themselves rather than waiting to be told.

**Injection** is a *contextual slice* — the current project, the current repo, and
semantic matches, under a token budget — not a fixed dump of N observations.

Musai runs as a **background helper** — a launch agent with a menu-bar presence — that
owns the Norvo Lite file; the SwiftUI app attaches to it. Hooks talk to the helper, so
capture and injection work whether or not the app is open. The app is a view, not the
host.

When Musai needs something of Norvo itself, it files an **issue on the Norvo GitHub
repo**; it does not change Norvo code directly.

## 11. Closed-loop automation (after v1)

The loop that makes Musai more than a notebook: Musai **dispatches a task** from a Plan
to an agent, the agent **implements** it in the project's repo, and **reports completion
back** into Musai, which updates the Task and the project's progress live. Memory
records what happened, so the next task inherits it. This is the "idea → spec → plan →
finished" arc run by the agents themselves, with the user approving gates.

## 12. Models and providers

Local-first, one abstraction, several ways in:

- **MLX** (in-process, Apple Silicon) — the default runtime for the curator and the
  embedder; zero external process.
- **Ollama** — the easy choose-and-install path; users pull and manage models with a
  familiar tool, and Musai gets model management for free.
- **Any OpenAI-compatible endpoint** — LM Studio, llama.cpp, vLLM, and whatever else the
  user already runs.
- **Cloud providers** (Anthropic, OpenAI, OpenRouter) — **explicit opt-in only**, off by
  default and labelled as leaving the machine.

**No models are bundled.** Musai ships a model manager: a short list of recommended
curator models with a one-line rationale each, plus the embedder, easy to choose and
install. The embedder follows the Lite spec's `qwen3-embedding-0.6b`. Exact model names
move fast and are pinned at plan time.

## 13. Backup and portability

The store is a single file, so a backup is a copy — but it must be a feature, not a
chore: first-class, user-initiated backup to a chosen destination (external drive, NAS,
cloud), with scheduled and manual runs, and an open-format export (JSON) so the data
outlives the app. This is residency finished: your data, where you want it.

## 14. The app

A SwiftUI app that is the workspace, the viewer, and the control panel:

- **Workspace**: projects, ideas, specs, plans, tasks, and progress — driven by Norvo
  Lite live queries, so it updates as the agent writes.
- **Memory viewer**: browse and search memories; see the curator's output; prune.
- **History**: time travel over any entity (Lite gives this).
- **Model manager** and **backup** controls.

## 15. Testing

- Integration tests across the **host matrix** with pinned host versions: CI covers the
  hosts that install cleanly, with a manual protocol for the rest.
- A **footprint budget as a test**: idle CPU near zero, bounded memory, one file, no
  inference except when the curator drains the queue. The anti-goals are testable.
- A **curator quality eval**: on a fixed set of transcripts, are the right things kept
  and filed?
- **Migration tests**: claude-mem history imports without loss of the things that matter.
- Inherits Norvo Lite's deterministic simulation and history guarantees; Musai does not
  re-test the engine.

## 16. Build order

1. Musai's data model on Norvo Lite (the graph, components, links), plus the claude-mem
   migration.
2. The ingestion queue and the host abstraction; MCP + hooks + the connect handshake;
   capture and injection for one host, then the matrix.
3. The local curator.
4. The SwiftUI workspace, viewer, model manager, and backup.
5. Prune: uninstall claude-mem and run on Musai alone.
6. Closed-loop automation.

## 17. Calls made while writing this (for review)

Marked as the writer's calls, not the user's agreed decisions:

- The entity set of section 6 and its SDD alignment.
- One Norvo Lite file for the whole library (rather than one per project).
- Using Lite's log/change feed as the ingestion queue.
- A background helper owning the file, with the app attaching.
- Capturing Musai's own normalized event stream rather than parsing host transcripts.
- Binding sessions to Projects by working directory and git remote.
- Injection as a contextual, token-budgeted slice rather than a fixed dump.
- The build order in section 16, and sequencing closed-loop automation after v1.
- Treating the anti-goals as testable budgets.

## 18. What is left to the builder

- The exact hook and MCP manifest per host, and the connect handshake's payload.
- The entity/component schema and link types, and the export format into SDD tools.
- The queue's shape on Lite, and the curator's model choice, prompt, throttle, and
  filing rules.
- The injection token budget and selection algorithm.
- The claude-mem migration mapping.
- The app's information architecture and screens; the model manager's and backup's UX.
- Concrete footprint numbers.
