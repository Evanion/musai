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
- **Integration is always a pull request — never merge locally.** Work lands by pushing its
  branch and opening a PR against `main`; the branch and its worktree stay until it lands, and
  feedback is fixed there.
- **Unresolved findings are tracked as GitHub issues**, not left only in a plan's workspace
  ledger, which is git-ignored scratch. File them with `gh issue create`, grouped into fixable
  units — one per file or surface — rather than one per minor, and let genuinely cosmetic items
  stay in the ledger.
- **A finished slice's decisions are persisted, not left in scratch.** When a slice lands, its
  executor's ledger — every ruling with its cost, and every deferred finding — is committed to
  `docs/superpowers/rulings/YYYY-MM-DD-<slice>-rulings.md`. Live findings stay in the issue tracker;
  the rulings file is the decisions and the tracker is the work, and neither replaces the other,
  because the working ledger is deleted with the workspace.
- **A review is budgeted, and the whole-branch review is not a re-read.** Per-task reviews read
  their own diff; the final whole-branch review gets the task verdicts, a short change summary
  and the cross-cutting questions — not the entire branch diff, the full spec, the plan and the
  ledger in one dispatch, and never an open "as many passes as you need". It opens a source file
  whole only where judgement needs it.
- **Reviewers run at the mid tier unless the person says otherwise.** The provider's flagship is
  for a task the person has named as worth it; "the most capable available" is bounded by what the
  allowance can afford. The mid tier is not a compromise here — it did every task review on the
  backend slice and found real defects at roughly a twentieth of the flagship's price. One
  whole-branch review on the flagship cost about half a five-hour allowance.
- The engine is **NorvoDB** (`/Volumes/projects/Personal/NorvoDB`). Musai consumes the
  NorvoLite Swift package; when it needs something of Norvo, it **files an issue** on the
  Norvo GitHub repo rather than editing Norvo.
- Platform: macOS, Apple Silicon only.
