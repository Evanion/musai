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
- **Status:** built and merged on `main`: the data model (`MusaiCore`, the project graph) and the **decision
  loop's first slice** — capture, detection, one-keystroke confirmation and the bounded handover
  (`docs/superpowers/plans/2026-10-12-musai-decision-loop.md`, PR #1, 66 tests).
  **Do not install it into a live session yet:** `musai install --claude-code` runs hooks that each open the
  store, and Norvo Lite allows one open per file, so a concurrent hook silently loses a turn until the
  **backend** (below) owns the file. See the PR for the full known-issues list.
- **Next slice:** the **backend** — a menu-bar helper that owns the Norvo Lite file, runs the curator and serves
  a loopback endpoint and MCP, with the hooks reduced to thin adapters and the app as its first client. That is
  what closes the above, and it is what the main design's §10 already specifies. Then the claude-mem
  **migration** (evidence that seeds the graph, not a row import).

## Working conventions

- Superpowers workflow: brainstorm → design in
  `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md` → plan in
  `docs/superpowers/plans/` → execute.
- Specs and plans are committed.
- The engine is **NorvoDB** (`/Volumes/projects/Personal/NorvoDB`). Musai consumes the
  NorvoLite Swift package; when it needs something of Norvo, it **files an issue** on the
  Norvo GitHub repo rather than editing Norvo.
- Platform: macOS, Apple Silicon only.
