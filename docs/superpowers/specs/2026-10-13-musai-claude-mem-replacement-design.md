# Replacing claude-mem: the first run, the local producer, and find

> **Status:** draft, for the person's approval. The first milestone of the memory work, and deliberately a small
> one: if Musai can do what claude-mem does, everything else builds on the same rails.

**Goal:** an agent working in Musai has memory that outlives its context window — captured locally, held in the
graph, and handed back at the start of the next task — and a person already using claude-mem can install Musai,
import the history they have, and switch.

## 1. The frame, in basic terms

An agent's context window is small and the work is not. For an agent to implement a person's tasks it needs memory
past the window, and because the store is a graph, that memory is **connections**: the idea, the document that
describes it, the conversation where it was decided, the code it became.

The architecture that delivers that is **one reader per source**, all feeding **the same filing step** — "evidence,
filed against a subject, linked to other subjects", in the decision-loop design's words. A Claude Code session is a
source; a repository is a source; a folder of specs and plans is a source; a notes directory is a source. That is
the shape that makes claude-mem-like, graphify-like and Obsidian-like tools one problem rather than three.

**This milestone builds the CM reader and the producer, and nothing else on that list.** The other readers come
after, on the same rails.

## 2. What "replace claude-mem" means — four functions

| Function | Today | This milestone |
| --- | --- | --- |
| **Capture** the session passively, with no effort from the person | ✅ built: hooks → the event queue | unchanged |
| **Produce** memory from it | ❌ **missing — nothing in `Sources/` writes a `Memory`** | the curator files `AMBIENT` memory |
| **Hand it back** at the start of the next task | ✅ built, but the slice carries decisions only | the slice gains memory under its budget |
| **Find** something you half remember | ❌ no route reads memory | `GET /memories` and `musai recall` |

The producer is the heart of it: claude-mem's *"passive watcher is what makes it uninstallable"*, and its metered
cloud observer is the thing being replaced.

## 3. The first run is the import

**The first thing a person does after installing Musai is import their history.** That is the whole reason for the
import, and it means the import cannot be a corner case bolted onto a store that already has projects in it — on a
fresh machine there is nothing to bind to, and the import is what creates the graph's entry points.

So the import **discovers and creates**:

- **Projects, from real working trees.** A session's `cwd` that still resolves to a git working tree creates or
  binds a `Project` — name from the repository, remote read from its `.git`. Eleven of the thirteen measured cwds
  are still real working trees today. `$HOME` is excluded, and so is any path that is not a repository: this is
  discovery, not invention.
- **Ideas, from what has no working tree.** CM's substantial project labels and subjects that were never a
  repository — a thread of work that lived only in conversation — become `Idea`s, linked to the project they spun
  off where the history shows one. An idea is exactly "a thought that may become a project or a feature", and CM is
  full of them.
- **Nothing from a bucket.** `open-source` (8 808 observations) is a filing habit, not a unit of work; labels like
  it become neither a project nor an idea, and they are counted.

The person sees what was discovered before it is kept, and can rename, merge or drop in the review surface.

## 4. What the import takes, and where it lands

| CM holds | Becomes | Why |
| --- | --- | --- |
| `sdk_sessions` (1 212) | `Session`, keyed by **the host's session id** (CM's `content_session_id`) | the host's id is what live capture already upserts on, so a conversation CM and Musai both saw is one row, not two |
| `observations` (25 739), `session_summaries` (4 922) | `Memory { origin: .MIGRATED }`, `provenance = "claude-mem:observation:<id>"` | CM's own distilled evidence — re-running our model over the same conversation would pay twice for less |
| the conversation CM stored (`user_prompts`) | the durable conversational record, per session | this is the history a person would otherwise lose: the conversation, not a summary of it |
| `work_state_entries` (18) | one `WorkState` | they are 18 **revisions of one list**, so latest-only beats 18 identical rows |

Four measured facts decide the mapping's wording, all from reading the source rather than assuming it:

- **`observations.text` is empty in every row.** Prose lives in `title` (present in 25 743 of 25 770), `facts` and
  `narrative`. So `Memory.text` — the `@fulltext` field, and what makes any of this findable — is **composed** from
  `title` + `facts`, never copied from a column that is always empty.
- **A third of the prompts are not the person.** 6 068 of 17 817 are `<task-notification>` hook payloads; 432 are
  two characters or less; 1 711 carry `toolu_` ids; the largest is 101 KB. They are dropped and counted, because
  the decision-loop design's rule is that the person's words are stored verbatim, and these are neither words nor
  the person's.
- **Most sessions have no project at all.** 838 of 956 importable sessions carry no `cwd`, and they hold 11 749
  observations and most of the prompts. Their memory is **written project-less** rather than skipped — the schema
  permits it — because skipping would lose exactly what the import exists to preserve. That needs slug-optional
  create operations and a `project` that `GET /memories` may omit.
- **Keying on CM's own session id would duplicate the transition.** CM's `memory_session_id` never equals the
  host's session id (0 of 951), and live capture keys on the host's — so the original choice wrote two sessions for
  one conversation whenever both tools saw it. The field is named `memorySessionId`; its *role* is the host's
  session key, and a rename is a later call.

## 5. The producer — the curator files ambient memory

The curator already drains the event stream and proposes decisions. This milestone gives it its second output:
`Memory { origin: .AMBIENT }`, bound to the event's project and session, for what the session's events say
happened — "filed against the bound project, not into a flat pile".

Anti-goals, which keep it a bounded producer rather than a summariser:

- **Never `DECISION`.** A decision is authored; the main design's §9 makes authored objects the high-signal layer
  and ambient capture the backfill. A producer free to mint decisions would poison that layer.
- **Never `AUTHORED`.** Origin is the person's.
- **Bounded per drain**, so a long session cannot flood the graph or hold the writer.
- **Idle-friendly**: no new always-on work, and an idle agent still runs no timer.

## 6. Migrated proposals get their own state and their own view

CM's `decision`-typed entries (2 016) and the `next_steps` of 4 854 summaries record **one side** of a choice
nobody confirmed. They are not decisions, and filing them as decisions would poison the high-signal layer — so they
arrive as proposals the person confirms, corrects or drops with one keystroke, which is the decision-loop design's
own §8: *"reuses this document's confirmation surface to turn one-sided entries into real decisions."*

The mechanism the filing step needs, because it cannot be done with a filter: `DecisionState` **gains `MIGRATED`,
appended at the end** (the engine permits enum appends with the prefix preserved), so migrated proposals drop out of
the live pending list for free; a new query serves the migration view; `settle`/`persist`/`drop` are unchanged; and
`Proposal` carries the provenance, so the person sees where each one came from before confirming it. Live review is
never buried under ~6 900 imported entries.

## 7. Handing it back, and finding it

- **The slice.** `MusaiSlice.render` gains the project's memories under the budget it already honours
  (`defaultBudget` 2 000, plus the reserve that keeps the "there is more" line inside it). Recent and high-signal
  first, never truncated mid-line. The main design's §18 leaves the budget and the algorithm to the builder.
- **Find.** `GET /memories?project=<slug>&q=<text>` answers from `Memory.text`'s full-text index — newest first,
  bounded, and with `project` optional so project-less history is reachable — and `musai recall` reads it from a
  terminal. Without this an imported history is stored but not usable.

## 8. Where it runs, and how it behaves

- **In the agent.** Only the agent opens Musai's store, with no fallback letting a client do it — so the import is
  the agent's work, requested over the endpoint, never a command that opens the file "while the agent is stopped".
  CM's database is opened **read-only**, so the import cannot damage what it reads and is always safe to re-run.
- **Batched, throttled, idle-friendly**, because it shares the one writer with capture and the curator.
- **Idempotent** on the session key, `Memory.provenance` and `Decision.origin`, all already indexed — and
  **resumable by a watermark** on the highest processed source id, because `drop` deletes a proposal's row *and* its
  origin, so without a watermark a resumed run would resurrect everything already dropped. The watermark is a small
  bookkeeping record of the agent's own (a `0006` migration, outside the graph's content).
- **Auditable**: imported, already present, proposed, unbound, dropped as machine text, failed. And because the
  first run happens on a fresh store, the counts of what was discovered — projects, ideas, what was left as a
  bucket — are part of the report, not a footnote.

## 9. Anti-goals

- **Discovery is not invention.** A project comes from a real working tree; an idea from a thread that existed;
  a filing bucket becomes nothing.
- **Not a payload.** Evidence is filed against a subject and linked; CM's tables are not mirrored.
- **No vectors in this milestone.** Nothing in `Sources/` computes an embedding and `Memory.embedding` has no
  writer; ~26 000 local embeddings is hours of compute for ranking only, when `Memory.text` is already `@fulltext`.
- **No `Artifact` entity yet.** Leads ride on the sessions that already exist; an entity for pointing at external
  things arrives with the first reader that genuinely needs it, so that model change is blessed beside its feature.
- **No fabricated time.** `Memory` has no timestamp; ordering uses the session's `startedAt`, which every row has.
- **No second owner, no writes to CM, and CM stays installed.** Uninstalling it is the person's call and the main
  design's last step.

## 10. Deliberately not in this milestone

The other readers — a repository's structure and history (graphify-like), a notes directory (Obsidian-like) — and
the enrichment that reads the folders and branches the leads name. This milestone keeps the map; the next walks it.
Also out: the window app and viewer, `GET /events` and SSE, and the closed-loop dispatcher.

## 11. Calls made while writing this

Mine, for review:

- **The milestone is "CM can be switched off",** not "the graph is complete from CM" — so the producer comes first
  and the import serves the switch.
- **The import discovers and creates projects and ideas**, because installing Musai leads straight into importing.
- **Projects come from working trees, ideas from what has none, and buckets become nothing** — the three-way rule
  that keeps discovery honest.
- **`DecisionState` gains `MIGRATED`** (an append) with a migration view, and `Proposal` gains provenance.
- **The session key is the host's session id**, so the transition never writes a conversation twice; the field's
  current name is a later rename.
- **Project-less memory is written, not skipped.** — which accepts slug-optional create operations and an optional
  `project` on `/memories`.
- **Machine-made prompts are dropped and counted.**
- **CM's observations are taken as evidence, not re-derived.**
- **No `Artifact` entity and no embedding work in this milestone.**

## 12. What is left to the builder

- The producer's filing rules, bound and prompt: what a drain decides is worth remembering, and how much.
- The composition rule for `Memory.text` from `title`, `facts` and `narrative`, incl. the 27 untitled and 30
  factless observations, and the bound on how much of one observation becomes a memory.
- The machine-row rule's exact shape, and the length floor.
- The discovery rules: what counts as a working tree, when two cwds are one project, and when a label is an idea.
- Which of CM's 20 types are evidence worth filing and which are its own bookkeeping, and the rule that picks the
  one-sided entries worth proposing.
- The migration view's shape and ordering; the `/memories` result shape, bound and ordering; the slice's selection.
- Batch sizes, throttle and idle behaviour; the watermark's shape; and the counts the import prints.
- How a session's `cwd` and git remote bind a project when the working tree no longer exists.
