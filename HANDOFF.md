# Musai — session handoff

Date: 2026-10-12
Purpose: carry the context from the session that designed Musai into this repo, so a new
session can continue without it.

## Where things stand

- **Musai is named.** The name is from Greek *Mousai*, the **Muses** — the sparks of
  imagination. Repo: `github.com/Evanion/musai` (personal account, deliberately separate
  from `NorvoDB`).
- **The design is approved** (2026-10-12):
  `docs/superpowers/specs/2026-10-12-musai-design.md`.
- A fresh builder reviewed it; its questions were answered and folded in. **One round,
  no open review questions.**
- **Next step:** plan and build the claude-mem import (`§16.1`'s second half — it inherits the ruling that an
  upsert by slug alone could reset a Project's status), then the ingestion queue, host abstraction, MCP server
  and hooks (`§16.2`). The data model is built and merged.

## What Musai is

A local-first workspace where one person and their AI agents take projects from idea →
specs and plans → finished, with long-term memory as connective tissue, and eventually a
closed development loop (the agent is handed a task, implements it, and reports
completion back).

It replaces **claude-mem** and embeds **Norvo Lite** as its engine.

## Decisions made while designing

The user's decisions:

- **v1 = two jobs:** collaborate with the AI on ideas/projects, and **sunset claude-mem**
  — including **migrating the existing history**.
- **Memory is a project graph, not a stream** — authored objects (decisions, specs,
  ideas) plus ambient capture.
- **Capture is a queue:** hooks append a normalized event stream to a **queue inside
  Norvo** (Lite's log/change feed); the **local curator drains it as resources allow**.
  Sessions are long-lived (weeks), so capture is continuous.
- **Host-agnostic matrix:** Claude Code, OpenCode, Cursor, Codex, Pi, and others.
- **Specs are authored in Musai**, then exported to the repo when ready to implement (not
  ingested from the repo).
- **Backup is first-class and user-initiated** (drive/NAS/cloud), plus open-format export.
- **Apple Silicon only; no bundled models;** a model manager for choosing and installing
  (MLX, Ollama, any OpenAI-compatible endpoint; cloud providers opt-in only).
- **Closed-loop automation** is a pillar, sequenced **after v1**.
- **Secrets manager: parked.**
- **Musai influences Norvo via GitHub issues**, not direct changes.

The writer's calls (listed in §17 of the spec; the user can veto): the entity set and its
SDD alignment; one Lite file for the whole library; Lite's log as the queue; a background
helper owning the file with the app attaching; capturing Musai's own event stream (not
host transcripts); binding sessions to projects by working directory + git remote;
contextual token-budgeted injection; the build order; anti-goals as testable budgets.

## Environment facts a new session should know

- **Engine:** `NorvoDB` at `/Volumes/projects/Personal/NorvoDB` — Rust crates plus the
  `NorvoLite` Swift package. Relevant docs there:
  - `docs/superpowers/specs/2026-10-04-norvo-lite-prototype-design.md` — what the app
    requires *from* Lite; the app it defers is Musai.
  - `docs/superpowers/specs/2026-10-08-swift-package-design.md` — how an app embeds Lite.
- **Swift package:** `github.com/NorvoDB/norvo-swift`; current release `binaries-v0.0.1`.
- **Machine:** Apple Silicon, macOS.
- **claude-mem is the thing being replaced.** See the appendix for its surface.
- The user works in **Claude Code** and **OpenCode**, and **rarely closes sessions** (one
  can run for weeks).

## Conventions in play

- Superpowers workflow: brainstorm → design in
  `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md` → plan in
  `docs/superpowers/plans/` → execute.
- Specs and plans are committed.

## Open items

- Pin the curator and embedder **model names** at plan time (they move fast).
- Decide the **export format** into SDD tools (Spec Kit, Kiro-style).
- Confirm the sequencing of closed-loop automation (after v1).

## First thing a new session should do

The data model is built and merged (`MusaiCore`, 27 tests). Read
`docs/superpowers/specs/2026-10-12-musai-design.md` (approved) and
`docs/superpowers/plans/2026-10-12-musai-data-model.md` (executed), then plan the claude-mem import —
`§16.1`'s second half, and the next slice in build order — with `superpowers:writing-plans`.

## Appendix — what claude-mem does today (the replacement surface)

From `~/.claude-mem/settings.json` and its plugin, observed 2026-10-12:

- **Store:** SQLite `claude-mem.db` (~1.0 GB) + a Chroma/vector store + a full-text index.
- **Observer:** an LLM, `claude-haiku-4-5`, on the Claude **subscription** (metered — the
  allowance drain), reading transcripts to decide what to remember. Currently out of
  allowance.
- **Capture:** a transcript watcher plus hooks.
- **Injection (session start):** ~50 observations, 5 full narratives, 10 recent sessions,
  with observation *types* (bugfix, feature, decision, …) and *concepts* (how-it-works,
  trade-off, …).
- **Interface:** an MCP server (`mem_search`, work-state tools), a local HTTP worker on
  `127.0.0.1:37777`, and a web viewer.
- **Ports:** Claude Code (plugin + `.mcp.json` + `hooks.json`) and OpenCode
  (`plugins/claude-mem.js` + `opencode.json`).
- **Extras:** corpora/priming, guided memory search, `/learn-codebase`, `smart_outline`,
  modes.

Musai must meet or beat the four core behaviors — **session capture, observations,
work-state, search** — and treat the rest as the long tail to decide on.
