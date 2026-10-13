# `musai mcp` — the MCP stdio server

    musai mcp

The hooks put Musai in the host's loop; this puts it in the agent's. `musai mcp` is a
[Model Context Protocol](https://modelcontextprotocol.io) server over stdio: it reads line-delimited
JSON-RPC from stdin and writes one reply per message to stdout, and stdout carries **nothing else** — a stray
write there corrupts the session, so every diagnostic goes to stderr.

Like every other client, it never opens the store. It reaches the backend's loopback endpoint through the port
in `helper.json`, with the token read from the `token` file beside the store — the record republishes that token,
but the file is the source of truth — so exactly one process, the agent, owns the store.

## The tools

| Tool | Arguments | Returns |
| --- | --- | --- |
| `context` | `cwd` (string, required) — the working directory | the slice for that directory: what the project has settled and learned, as a short text. Empty when Musai has nothing to say there. |
| `decisions` | none | the decisions settled and recorded nowhere, as JSON — the gap Musai's loop exists to surface. |

Both are reads. This slice exposes no authoring or capture tool: the loop's machinery already captures
turns and proposes decisions, and MCP authoring arrives with the slice that holds that data.

`initialize` answers with `serverInfo` (`musai`, and the build's version) and a `tools` capability, and
`tools/list` answers with both tools and their JSON schemas — **whether or not the backend is running**, so a
host can connect and handshake before the agent exists.

A tool call with no backend, or against one the agent has since left behind, is a **tool error** — a result
with `isError: true` naming the fix (`musai install`) — never a crash and never a JSON-RPC error. The server
stays up. That includes a backend that answers `503` because it could not open its store: its one line, naming
the log, is passed through whole. The server re-reads `helper.json` and the token for **every** message, so a
long-lived server is never pinned to a port the agent has since abandoned; when the agent restarts under
launchd, the next message finds the new port.

## Configuring a host

Claude Code, in `.mcp.json` at the project root (or the person's own `~/.claude.json`):

```json
{
  "mcpServers": {
    "musai": {
      "command": "/Users/you/build/musai",
      "args": ["mcp"]
    }
  }
}
```

Or from the shell:

    claude mcp add musai -- /Users/you/build/musai mcp

Point `command` at the same `musai` binary `musai install` wrote into the host's hooks — an absolute path,
because that is what the install writes and what survives a shell that does not have the checkout on `PATH`.

## Why stdio, not HTTP

Every host supports stdio, and one process per host session is exactly the lifetime an agent's tool calls
have. `POST /mcp` as Streamable HTTP would mean implementing initialize negotiation, sessions and SSE on the
endpoint — a chunk of protocol work with no user-visible gain while a stdio shim already reaches every host.
It is deferred until a host needs it.
