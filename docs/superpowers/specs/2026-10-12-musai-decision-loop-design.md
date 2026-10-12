# The decision loop: design

Date: 2026-10-12
Status: **draft, for review** — a reviewer reads this before you do; expect one round of questions back.
Amends: `2026-10-12-musai-design.md` — it supersedes that document's §3 non-goal ("not a general
note-taking or PKM tool") and replaces §9's authoring mechanism as the way a decision is captured. Everything
else there stands, and this document assumes its constraints (§5) and its entity model (§6).
Source: the conversation of 2026-10-12 that started as "write the claude-mem migration plan" and turned into
this.

## 1. Intent

Make the agent effective and token-efficient on a long-running project, by giving it the project's
accumulated understanding instead of making it rebuild that understanding from the repository every task.

The pain, in the words of the person it happens to:

> I tend to burn large amount of tokens and time just for the agent to build the knowledge space that it
> needs for a task. or else it will have forgotten/missed an aspect that was planned/discussed, and create
> another solution that doesn't match my intent or understanding of the system.

Two failures, and the second is the expensive one. Rebuilding costs tokens and time. Missing an aspect
produces a solution that is internally sound and wrong — the user then reconciles two competing designs.

Software development carries two contexts with very different lifetimes: the project's conceptual state
(months, years) and the agent's context window (one task). The gap between them is the whole problem.

### What claude-mem got wrong

It captured **one side of the conversation**. Its 25,613 observations are the agent's narration of its own
work, and the session-start handover gives an agent ~50 observations, 5 full narratives and 10 recent
sessions. The user's side — 17,674 prompts in the same database — is not in the handover at all (a setting,
`CLAUDE_MEM_CONTEXT_SHOW_LAST_MESSAGE`, off by default, would supply exactly one).

So the agent inherited a recording of itself, and the user's words arrived only as the agent's paraphrase.
The corrections in the history show what that costs:

| Where | The user's words |
| --- | --- |
| NexusDI, 2026-10-11 | "IDK where that came from in 11.7, it's nothing I said." |
| NorvoDB, 2026-10-09 | "I didn't mean that database is public .. I meant we could make the swift repo public.." |
| NexusDI, 2026-09-30 | "I just took errors as an example, but I meant it as a general design principle/rule" |
| NexusDI, 2026-09-23 | "I said that I want to Read the post" |
| mitt-coop, 2026-09-30 | "the UI still doesn't match the prototyp mock we created" |

In every one the **statement survived and its status did not**. Who uttered it. Whether it was settled or
merely proposed. Whether it was an example or a rule. Which thing it referred to. What artifact it hung on.

### The two events

A decision becomes real when the user says it, and durable when it is recorded in the proper document.

> well it's decided when I say it. But it needs to be recorded in the proper documents in order to be
> persisted.

Between those two moments a decision is true but not yet durable: the agent in that session knows it, and
the next session's agent does not. The set of decisions in that gap is the risk — decided, unrecorded, later
contradicted. Capturing decisions where they are made, and closing that gap, is this document's subject.

### Reliability is the requirement, and the agent cannot be the mechanism

> It doesn't really matter to me if it's the agent or musai does it, the important part is that it's reliably
> done. and the agent WILL miss it. an agent is focused on the task at hand. not clerk work.

The agent is structurally the wrong place to put the clerical step: it will skip it precisely when the
session is most interesting. So capture and filing are **Musai's own machinery**, and the person's
participation is limited to a confirmation they can give in one keystroke.

## 2. Goals

1. **Capture both sides** of a session's exchange — the user's turns verbatim, the agent's summarised but
   kept — automatically, with no co-operation from the agent and none from the user, and never the agent's
   tool output.
2. **Propose decisions** from that exchange: in the user's words, with the user as the actor, and with a
   pointer back to the event they came from.
3. **Confirm cheaply** — one keystroke to confirm, correct or drop a proposal.
4. **Persist** a confirmed decision into the document it belongs to, and know which document that is.
5. **Surface the gap** — the decisions that were decided and have not landed anywhere.
6. **Hand over a slice** — before a task, the settled decisions that constrain it, the shape of the parts
   it will touch, and what is planned next, under a token budget, with links out for more.

## 3. Non-goals

- **Not a chat interface.** The conversation stays in the host; Musai reads its shape, it does not host it.
- **Not somewhere you write prose.** This supersedes the main design's §3 ("not a general note-taking or PKM
  tool") only in that Musai *absorbs* notes as evidence (§7). Authoring prose in Musai is not a primary act;
  the primary acts are confirming a proposal and authoring a spec or plan.
- **Not a replacement for the agent's reasoning.** It supplies settled facts and their provenance. It does
  not decide, plan or design.

## 4. Anti-goals

A version that technically works but is:

- **clerk work.** If the user must remember to record a decision, or the agent must be told to, it fails.
  This is the anti-goal the current design violates, and the reason for this document.
- **a second context to maintain.** Beyond confirm/correct, it must not want curation. A noisy detector is
  clerk work by another name, so precision matters far more than recall.
- **as expensive as the problem.** The handover must cost far fewer tokens than the agent would spend
  re-deriving the understanding it replaces. A dump of N observations costs the same as the problem.
- **bloated by the agent's own output.** The code it writes and the commands it runs belong in the
  repository. Capturing them is both wasteful and how a store like this explodes.
- **in the way.** No blocking the agent, no waiting on a model before it can act.

## 5. Constraints

Inherited from the main design (§5) and unchanged: Norvo Lite as the only store; one file; macOS on Apple
Silicon; SwiftUI; local-first with no metered cloud observer; host-agnostic, nothing depending on one host.

Added or sharpened here:

- **Hooks are the only reliable capture point.** The user's turn arrives *in the hook's own payload* — Claude
  Code's `UserPromptSubmit` hands over `user_prompt` directly — so the user's side needs no transcript at all.
  That is how claude-mem collected 17,674 of them. *Checked against the installed host:* Claude Code 2.1.295,
  whose hook payloads are `session_id`, `transcript_path`, `cwd`, `permission_mode`, `hook_event_name`, plus
  `user_prompt` on `UserPromptSubmit`, `tool_name`/`tool_input`/`tool_result` on `PostToolUse`, and `reason`
  on `Stop`.
- **One narrow exception, for the agent's own last message.** The `Stop` hook carries no assistant text, so
  the agent's final message is read from the `transcript_path` the hook hands over — text blocks only,
  truncated, and isolated in that host's adapter. This is the only transcript read in the system, and it
  exists because the alternative is to lose the agent's own account of what it did and why. It is not a
  licence to parse transcripts for anything else.
- **The queue is appended rows in the graph, not the engine's log.** *Verified:* Norvo Lite exposes no
  app-facing log or change feed — the C ABI has no log read, and NorvoQL generates no `commits`/`changes`
  root — so the main design's assumption (§7, and the writer's call in §17) that "Lite's log and change feed
  is the queue" does not hold today. The queue is the expiring `Event` tier in §6.2. It must be committed
  before the hook returns, and the curator keeps a cursor. A read-cursor over the engine's own log would be
  better than a table; that is worth an issue on the Norvo repository and is not on the critical path.
- **Only the queue is allowed to lose work.** Capture appends to the queue; everything after it (detect,
  confirm, file) is allowed to lag, because the queue does not.
- **Detection runs on a local model** from the main design's tiers (§12), and idles: it drains the queue as
  resources allow, like the curator.
- **The user's words are stored verbatim.** Storing is cheap; selecting is where the budget goes. A
  paraphrase is where the intent is already lost, so the user's turn is never rewritten.
- **Tool output is never captured.** The code an agent writes and the output of the commands it runs are not
  memory; they live in the repository and in version control, which is where they belong. A tool event records
  the tool, its target and a hash — never its payload — and every captured event has a hard size cap. A store
  that grows with the code the agent generates is the failure this constraint exists to prevent.

## 6. The model changes this forces

Four additions, all small. The builder owns the exact schema; these are the shapes the loop requires, and the
first two carry decisions made here.

1. **A statement's status.** Today a `Decision` records who created it, through Norvo's actor fields, and
   nothing more. It needs *what kind of act* it was and *whether it is settled* — a settled-at time, null
   while it is only a proposal. The builder picks the enums; consider whether "an example" versus "a rule"
   deserves its own axis, because the NexusDI correction in §1 is exactly that confusion and a single act
   kind may not separate them. `MemoryKind.DECISION` is retired, so a decision has one home and the overlap
   between `Decision` and a decision-kind `Memory` disappears.
2. **The exchange, in two tiers — and both sides persist.** The queue is not the memory.
   - **The durable layer** holds both sides of the conversation, and nothing in it expires:
     - **`Utterance`** — every user turn, verbatim, with the user as its *speaker* (a field, not Norvo's
       `createdBy`, because the curator is the one writing it). It links to its session and to any decision it
       produced. Small, and the record of intent.
     - **`Memory`** — what the agent's side is worth as memory: what it did, decided or learned, with the
       rationale, curated rather than verbatim, with the agent as its actor. **This is where the agent's
       responses persist.** They must not expire.
   - **The expiring tier is the raw queue the hooks write, as `Event` rows** — the turn text as it arrived (the
     agent's turns truncated) and tool-use *references*: the tool, its target, a hash. Never a tool's output.
     About 30 days with cheap expiry, as the main design already requires. Its only job is to still be there
     when the curator gets to it.
   Detection reads the expiring tier; whatever it judges worth keeping survives in the durable layer. So
   nothing on the agent's side is lost — only its redundancy is, and the code it wrote was never here.
3. **Artifacts as things.** A mock, a screenshot, a document, a file. The mitt-coop correction in §1 is a
   memory pointing at something that no longer existed in the conversation, and today `Memory.provenance` is
   a string that cannot be linked, filtered or injected. An artifact is an entity that a memory, a decision
   or a task points at.
4. **Persistence as a link, and as content.** A decision points at the document it landed in, and the
   document points back at the decisions it carries — that is what makes "decided but unrecorded" a query.
   And, settled in conversation: the decision must be **recorded in** that document, not merely linked to it.
   For a Musai-authored spec or plan that is the main design's §9 export; for a document outside Musai it is
   a link, because the commit or the file is already the record.

## 7. The loop

```
session ──hooks──▶ queue: the Event tier ──curator──▶ candidate decisions
                                                        │
                                          one keystroke  ▼
                                              confirmed decision
                                                        │
                                    ┌───────────────────┴───────────────────┐
                                    ▼                                       ▼
                        carried into its document                 "decided, not recorded"
                        (spec, plan, task, commit)                        list
                                    │
                                    ▼
                          bounded slice at the next task
```

1. **Capture.** A hook on the user's turn appends the durable `Utterance` row; every hook appends an `Event` to
   the expiring tier. Nothing else in the loop can lose an event, so this is the only part that must be
   trivial and fast, and its write must be committed before the hook returns.
2. **Detect.** The curator reads queued exchanges and proposes decisions: the user's words, the act kind,
   the settled state it believes, and a link to the event. It proposes *few and confident* — a false
   proposal is clerk work, a missed one is the status quo.
3. **Confirm.** The proposal appears where the person already is — the app's review surface, and optionally
   an MCP tool the agent can call if it happens to be composing a spec. One keystroke: confirm, correct, or
   drop. Corrections are the detector's training signal.
4. **Persist.** A confirmed decision links to the document it belongs to. The main design's §9 export is the
   mechanism by which a Musai-authored spec or plan reaches the repository; a decision's persistence is the
   same step, and a decision whose document is code or a commit is recorded as persisted with a link.
5. **Close the gap.** A view lists decisions that are settled and unpersisted. This is the risk set, and it is
   the answer to "what did we decide that nobody wrote down?".
6. **Hand over.** At the start of a task, Musai hands the agent a slice: the settled decisions that constrain
   the work, the shape of the parts it will touch, what is planned next — selected under a token budget, with
   links to the full evidence.

## 8. Later slices (named, not designed here)

The person also uses, and wants Musai to absorb, Obsidian (notes), graphify (a structural graph of a codebase
or corpus) and an LLM-maintained wiki. What makes them absorbable is that they share one shape: evidence,
filed against a subject, linked to other subjects. So each is **one reader feeding the same filing step** —
not a new model.

Order, confirmed: (1) this loop; (2) the claude-mem migration, which is evidence that seeds the graph rather
than a payload, and reuses this document's confirmation surface to turn one-sided entries into real
decisions; (3) one reader per source, each its own slice.

### The reviewer, when the loop closes

Closed-loop automation (`§11` of the main design) hands a Task to an agent and needs a verdict on what came
back. That verdict is **this document's machinery, pointed at the agent's output instead of the person's
input**, and it is worth designing as such rather than as a separate feature:

- **Check the work against the settled decisions that constrain it**, not against the task's text alone. "You
  did the task and contradicted a decision the person settled in September" is the failure that costs real
  rework, and it is the status failure in §1: a proposal read as a decision, an example read as a rule.
- **Check the task, not the plan.** The Task is the unit handed over and the one that can carry acceptance
  criteria; the plan is the container it came from.
- **Give the verdict a statement's status too.** Who verified it, on what evidence, and is that verdict settled
  or the agent's own claim? An agent reporting "done" is an unproposed proposal until something with the
  person's authority settles it — which means the reviewer's disagreement is itself a decision, and it feeds
  back into the loop rather than into a comment.

What it must not be: a diff against the plan's text. A plan is an argument, and an implementation that deviates
while satisfying the intent is the normal case, not a defect — so a reviewer of this kind needs the deviations
and their stated reasons to adjudicate, not just the document.

**The first slice, agreed:** the loop end to end and narrow — capture, detection and a minimal confirmation
surface for Claude Code alone, plus the slice handed over when a task starts. OpenCode follows. The point of
going narrow is to answer the one bet this design rests on — that a local model can propose decisions
precisely enough that confirming them is not clerk work — before the model changes and the rest of the host
matrix are built on the answer.

## 9. What is left to the builder

- The detector's model, prompt, and its precision target; how corrections feed it.
- Where and when confirmation surfaces without interrupting the work — menu bar, review screen, batched at
  the end of a session, or all three.
- The slice's selection algorithm and its token budget.
- The export format into the repository, which the main design also leaves open (§18).
- The migration mapping, which is the next document.
- Which of the four model changes are additive to the existing schema (a `0002_*` migration) and which need
  the existing `0001_init` to change.
- The connect handshake's payload per host, and how the user's turn is obtained in each host's hook.

## 10. Calls made while writing this (for review)

- **Capture the exchange, not transcripts.** The user's turn arrives in the hook payload, not by parsing a
  transcript. *Checked, not assumed:* of the hosts claude-mem saw, all three delivered the user's own prompts —
  `claude` 16,675, `cursor` 964, `opencode` 40. And Claude Code 2.1.295 does hand `user_prompt` to
  `UserPromptSubmit`, so the mechanism is in the payload, not inferred. Codex and Pi are unverified and are
  checked when they are added.
- **The agent's last message is the one transcript read** — see §5. It is the price of keeping the agent's own
  account of its work, and it belongs to one host adapter, not to the core.
- **The queue is the expiring `Event` tier, not the engine's log.** *Checked:* no app-facing log or change
  feed exists in the C ABI or in NorvoQL's generated roots. Worth a Norvo issue for a log read-cursor; not on
  the critical path.
- **Store the user's words verbatim, select sparingly.** Disk is cheap; the budget is spent on selection.
- **The loop is Musai's machinery; MCP authoring stays a manual override.**
- **Precision over recall in detection.** A noisy proposal queue is clerk work, which is the anti-goal.
- **This document supersedes the main design's §3 non-goal and §9 authoring mechanism** rather than editing
  that approved document in place.
