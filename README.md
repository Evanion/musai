# Musai

A local-first workspace where one person and their AI agents take projects from an idea,
through specs and plans, to finished — with long-term memory as the connective tissue.

Musai embeds **Norvo Lite** as its engine (single file, C ABI, through the `NorvoLite` Swift
package). This repository currently holds the data layer, `MusaiCore`: the project graph —
projects, ideas, specs, plans, tasks, decisions, memories, sessions and the typed links
between them — as a NorvoQL schema with typed Swift operations.

The design is `docs/superpowers/specs/2026-10-12-musai-design.md`; the plan that builds this
data layer is `docs/superpowers/plans/2026-10-12-musai-data-model.md`.

## Develop

`Swift 6.1` tools, macOS 14+, Apple Silicon.

`MusaiCore` depends on the `norvo-swift` checkout. By default that is `../norvo-swift`; from a
git worktree, point at it explicitly:

```sh
export MUSAI_NORVO_PATH=/Volumes/projects/Personal/norvo-swift
export NORVO_LOCAL=1        # use the engine built at NorvoDB/target/apple instead of downloading binaries
```

`NORVO_LOCAL=1` is read by `norvo-swift`'s own manifest and makes it link its `Artifacts/`
symlinks to a local engine build. Without it, the first build downloads the pinned
`binaries-v0.0.1` release.

```sh
swift build
swift test                          # all suites
swift test --filter ProjectTests    # one suite
```

## Install it into Claude Code

```sh
swift build
musai install --claude-code          # merges four hooks into ~/.claude/settings.json, with a backup
```

Then work a session as usual, run `musai review` to confirm what the curator proposes, and start a new session
to see what the agent is handed. `docs/claude-code-hooks.md` has each hook, its timeout, the model
configuration, and how to uninstall.

## Try the loop by hand

```sh
musai install --claude-code
# work a session in Claude Code as usual, then:
musai review            # confirm or correct what the curator proposes
# start a new session and read what the agent is handed
```

The question this slice exists to answer is the one a test cannot: **did confirming those proposals feel like
one keystroke, or like clerk work?** That answer decides whether the model changes and the rest of the host
matrix are worth building, so it belongs in the next design rather than in someone's memory.

## Layout

```
Sources/MusaiCore/
  schema.nql            the NorvoQL SDL (the current schema)
  migrations/           snapshot migrations, the first being 0001_init
  operations/           named queries, mutations and fragments
  MusaiLibrary.swift    opens the one file and applies migrations
  MusaiActors.swift     who Musai writes as
```

`.nql` files are excluded from compilation; the `NorvoCodegen` build plugin turns them into
`Norvo.generated.swift` (the typed operations and `NorvoSchema.migrations`).

`Sources/musai` is the executable the host's hooks call. Everything it does lives in `MusaiCore`, so that
"a hook can never break the host" is a test rather than a hope.
