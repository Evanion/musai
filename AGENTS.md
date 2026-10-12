# Musai

Musai is a local-first workspace where one person and their AI agents take projects from
idea, through specs and plans, to finished — with long-term memory as connective tissue,
and eventually a closed development loop. It is its own brand (not a Norvo product) and
embeds NorvoDB's **Norvo Lite** engine (single-file, C ABI, via the NorvoLite Swift
package).

## Start here

- **Design:** `docs/superpowers/specs/2026-10-12-musai-design.md` — **approved 2026-10-12**.
- **Session handoff:** `HANDOFF.md` — the context from the design conversation, the
  decisions made, and the environment facts.
- **Status:** the design is approved (2026-10-12) and the data-model plan
  (`docs/superpowers/plans/2026-10-12-musai-data-model.md`) is **built and merged**: `MusaiCore` holds the
  project graph on Norvo Lite — schema, operations, `MusaiLibrary`, `ProjectBinder` — with 27 tests green.
  Next in build order (`§16.2`): the claude-mem import, then the ingestion queue and the host abstraction.

## Working conventions

- Superpowers workflow: brainstorm → design in
  `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md` → plan in
  `docs/superpowers/plans/` → execute.
- Specs and plans are committed.
- The engine is **NorvoDB** (`/Volumes/projects/Personal/NorvoDB`). Musai consumes the
  NorvoLite Swift package; when it needs something of Norvo, it **files an issue** on the
  Norvo GitHub repo rather than editing Norvo.
- Platform: macOS, Apple Silicon only.
