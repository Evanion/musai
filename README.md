# Musai

A local-first workspace where one person and their AI agents take projects from an idea,
through specs and plans, to finished — with long-term memory as the connective tissue.

Musai embeds **Norvo Lite** as its engine (single file, C ABI, through the `NorvoLite` Swift
package). This repository holds the project graph — projects, ideas, specs, plans, tasks,
decisions, memories, sessions and the typed links between them — as a NorvoQL schema with typed
Swift operations, and the backend that owns it: a menu-bar agent that opens the one store,
serves a loopback endpoint and runs the curator, with the hooks reduced to clients of it.

The designs are `docs/superpowers/specs/2026-10-12-musai-design.md`,
`docs/superpowers/specs/2026-10-12-musai-decision-loop-design.md` and
`docs/superpowers/specs/2026-10-12-musai-backend-design.md`; the plans that built this are
`docs/superpowers/plans/2026-10-12-musai-data-model.md`,
`docs/superpowers/plans/2026-10-12-musai-decision-loop.md` and
`docs/superpowers/plans/2026-10-13-musai-backend.md`.

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
musai install
```

`musai install` assembles `~/Applications/Musai.app` with the agent nested inside it, registers the launch
agent, and merges the hooks into `~/.claude/settings.json` with a backup. `docs/claude-code-hooks.md` has
each hook, its timeout, the model configuration, and how to uninstall.

## Try the loop by hand

This is the half a test cannot cover: whether the backend stays out of the person's way.

1. `musai install`, and work a session in Claude Code as usual. The hooks start the agent if it is not
   already running, so the first capture is the moment the backend comes up — and it should be the last
   time you notice it.
2. If anything looks wrong — nothing captured, no status item, a hook complaining — run `musai doctor`. It
   reads the record, asks `/health` when the agent answers, and prints the tail of the log.
3. Run `musai review`, and confirm or correct what the curator proposes.
4. Watch the agent die and come back: with a session open, `launchctl kickstart -k gui/$(id -u)/dev.musai.agent`
   kills the running agent mid-flight, and launchd starts it again — `musai doctor` shows a new pid, and the next
   hook captures as though nothing had happened. Then Quit from the menu bar: that one stays quit, because Quit
   boots the job out of launchd on purpose, and `musai install` is what brings it back.
5. Start a new session, and read what the agent is handed: the decisions you confirmed, in your own words,
   and where each one landed.

Then answer the question this slice exists to answer: **did the backend stay invisible until you went
looking for it?** That answer — not the tests — decides whether the window app and the rest of the host
matrix are worth building, so record it in the next design rather than in someone's memory.

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

`Sources/musai` is the executable the host's hooks call, and it holds everything host-shaped: the payload
decode, the `Stop` transcript read, the `SessionStart` stdout shape, and the dispatch table. `MusaiCore`
knows no host at all — a new host is a new adapter there, not a backend change — and `Sources/musai-agent`
is the process that owns the store. That a hook can never break the host is a test, not a hope.
