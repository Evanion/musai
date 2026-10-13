# Installing the loop into Claude Code

    musai install [--settings <path>]

It assembles `~/Applications/Musai.app` with the agent nested inside it, registers the launch agent that keeps
that agent running, and merges four hooks into `$CLAUDE_CONFIG_DIR/settings.json` (or `~/.claude/settings.json`),
keeps a backup of what was there as `settings.json.musai-backup`, and leaves every other hook alone. Merging
twice changes nothing. `--claude-code` is still accepted, but the install is the whole install either way.

| Event | What it does | Timeout |
| --- | --- | --- |
| `SessionStart` (`startup\|resume\|clear`) | hands the agent the settled decisions that constrain its task, as `hookSpecificOutput.additionalContext` | 60 s, blocking |
| `UserPromptSubmit` | records the person's turn, verbatim, as the durable `Utterance` and a queue `Event` | 15 s, blocking |
| `PostToolUse` (`*`) | records the tool, its target and a digest — never its result | 120 s, async |
| `Stop` | records the agent's own last message (text blocks only) | 120 s, async |

The hooks only ever write to the queue. The drain — turning captured events into proposals through the configured
model — belongs to the agent's curator, off the request path.

Every command ends in `|| true`: a hook may never fail the session it is reporting on. A model that
is down therefore costs nothing — the events stay in the queue and the curator's next drain retries them.

## Configuration

`~/Library/Application Support/Musai/config.json`, written with defaults on first use:

```json
{
  "baseURL" : "http://127.0.0.1:11434/v1",
  "kind" : "openAICompatible",
  "maxTokens" : 2048,
  "model" : "qwen3.6:27b",
  "timeoutSeconds" : 60
}
```

`kind` is `openAICompatible` (Ollama, LM Studio, vLLM, llama.cpp, OpenAI), `anthropic`, or `mlx` for an
embedded model. Add `"apiKeyEnv": "OPENAI_API_KEY"` for a cloud provider and put the key in that environment
variable: the key is read at the moment it is needed and is never written to this file or to the store. The
same directory holds the store, `Musai.norvo`.

## Uninstalling

    musai install --uninstall

It stops the agent, removes `Musai.app` and its launch agent, and takes the four hooks back out. By hand, that is
the four entries removed from `settings.json` (or `settings.json.musai-backup` restored), the bundle deleted, and
`~/Library/LaunchAgents/dev.musai.agent.plist` removed. The store is a single file;
`rm ~/Library/Application\ Support/Musai/Musai.norvo` is the whole of the rest.
