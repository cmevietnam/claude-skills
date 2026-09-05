# What a headless `agy` run is allowed to do

The headline: **a headless run that was blocked from every tool it wanted still exits 0
and reports `"status": "SUCCESS"`.** Everything else in this file follows from that.

Verified on 2026-09-05 against `agy 1.1.27` by running the commands shown and reading the
`stream-json` event log.

## The default

`~/.gemini/antigravity-cli/cli.log` records the default on startup:

```
CLI settings initialized: permissions=<nil>, toolPermission=request-review
```

`request-review` means every tool call is queued for a human. Headless there is no human,
so the call is **auto-denied** — and, critically, the run continues and finishes normally.

## The failure signature

Asking a headless run to read a file, with no allow-rules configured:

```bash
agy -p "Read plugins/foo/plugin.json and reply with its version field" \
  --model gemini-3.8-flash-low --output-format json </dev/null
```

```json
{
  "conversation_id": "0f1e907b-...",
  "status": "SUCCESS",
  "response": "",
  "duration_seconds": 2.27,
  "num_turns": 1,
  "usage": {
    "input_tokens": 13315,
    "output_tokens": 67,
    "total_tokens": 13382
  },
  "denied_actions": [{ "action": "command", "display_name": "RunCommand" }]
}
```

Exit code **0**. Status **SUCCESS**. Response **empty**. Only two things give it away:

- `denied_actions` in the JSON envelope
- this line on **stderr**:

```
jetski: no output produced — a tool required the "command" permission that headless mode
cannot prompt for, so it was auto-denied. Add an allow-rule under permissions.allow in
settings.json (e.g. command(<target>)). Alternatively, re-run with
--dangerously-skip-permissions to auto-approve all tools.
```

Which is why stderr is captured to a file on every run, never sent to `/dev/null`.

## Three ways this bites

1. A review reports SUCCESS having read nothing.
2. `jq -r '.response // "failed"'` on the resulting file prints **nothing and exits 0** —
   a zero-byte file makes `jq` produce no output at all, so the `//` fallback never runs.
   (On malformed _non-empty_ JSON `jq` does error, exit 4. The dangerous case is the empty
   one.) Verified with `jq-1.6`.
3. The model may burn thinking tokens and still emit nothing: one denied run showed
   `output_tokens: 67` with an empty `response`.

## The fix that needs no permissions

Put the material in the prompt and forbid tools explicitly:

```
Answer entirely from the material in this prompt. Do NOT call any tools, do NOT run shell
commands, do NOT read files — tool calls are auto-denied here and will make you produce no
output at all. Write the review directly.
```

Without that instruction, a model handed 47 KB of self-contained material _still_ reached
for a shell command, was denied, and returned an empty response. With it, the same prompt
produced an 11 KB review and `denied_actions: null`. The instruction is not optional.

## Allow-rules, if the run really must touch the repo

`~/.gemini/antigravity-cli/settings.json`, pattern `action(target)`:

```json
{
  "permissions": {
    "allow": ["command(cat)", "read_file(/abs/path/to/repo)"]
  }
}
```

Verified behaviour, one step at a time:

| Allow-list                           | Result                                                                     |
| ------------------------------------ | -------------------------------------------------------------------------- |
| _(none)_                             | `run_command` denied, empty response                                       |
| `command(cat)`                       | `cat` **runs**; `pwd && ls -la` denied — matching is per binary            |
| `command(cat)`                       | model falls back to `read_file` → `denied_actions: [read_file / ViewFile]` |
| `command(cat)` + `read_file(<repo>)` | `denied_actions: null`, correct file contents returned                     |

So every tool the model might reach for needs its own rule. Tool names observed:

| Tool           | Display name | Rule                       |
| -------------- | ------------ | -------------------------- |
| `run_command`  | RunCommand   | `command(<binary>)`        |
| `read_file`    | ViewFile     | `read_file(<path prefix>)` |
| `find_by_name` | —            | not exercised              |

This file is the user's global settings. Ask before writing to it, and prefer the
no-tools shape.

## Working directory

**`agy` does not run tools in the shell's current directory.** Given
`cat README.md` from a repo root, the `stream-json` log showed:

```json
{"tool_name":"run_command","tool_info":{"parameters":{"CommandLine":"cat README.md"},
 "output":"cat: README.md: No such file or directory\n"}}
{"tool_name":"find_by_name","tool_info":{"parameters":{"Pattern":"README.md",
 "SearchDirectory":"/Users/hieuvo/.gemini/antigravity-cli"}}}
```

It searched its own config directory. Use **absolute paths**, or `--add-dir <DIR>` to put
the repo in the workspace.

## Escalation

- `--mode accept-edits` — auto-approve edit tools.
- `--mode plan` — read-only planning mode.
- `--dangerously-skip-permissions` — auto-approve everything, writes and shell included.
- `--sandbox` — terminal restrictions, orthogonal to the permission engine.

`--dangerously-skip-permissions` is the only one that reliably unblocks an agentic run, and
it is also the one that lets the model rewrite the repository. Ask first, every time, and
say which mode was used when reporting results.

## Debugging with stream-json

`--output-format stream-json` emits NDJSON: one `init`, many `step_update`, one `result`.
A `step_update` with `step_type: "tool"` carries `tool_name`, `tool_info.parameters`, and
either `tool_info.output` or `tool_info.error`:

```json
{
  "event": "step_update",
  "step_update": {
    "step_index": 6,
    "state": "ERROR",
    "step_type": "tool",
    "tool_name": "run_command",
    "tool_info": {
      "parameters": { "CommandLine": "pwd && ls -la" },
      "error": {
        "type": "TOOL_ERROR",
        "message": "permission check failed for command ..."
      }
    }
  }
}
```

This is the only way to see _which_ commands were attempted and why they failed. Do not
merge stderr into stdout while doing it (`2>&1`) — the `jetski:` warning is not JSON and
will break a line-by-line parser.
