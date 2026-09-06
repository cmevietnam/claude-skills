# Antigravity CLI reference

Verified against **agy 1.1.27** on 2026-09-05 by running `agy --help`, `agy models`, and
the commands shown. `agy` self-updates in the background, so re-verify after any gap.

```bash
agy --version
agy update
agy changelog
```

## Install

```bash
set -euo pipefail
d="$(mktemp -d)"
curl -fsSL --proto '=https' https://antigravity.google/cli/install.sh -o "$d/install.sh" \
  && less "$d/install.sh" \
  && bash "$d/install.sh"
```

Download into a **fresh private directory**, read it, then run that exact file. Three
things this avoids:

- piping into `bash` executes network content nobody has seen;
- a failed `curl` leaves an empty script that `bash` accepts happily, so the install
  silently does nothing;
- a fixed name like `/tmp/agy-install.sh` can be pre-created by another local user as a
  symlink, or swapped between the read and the run.

So the documented one-liner
(`curl -fsSL https://antigravity.google/cli/install.sh | bash`) is not what to use.

The installer fetches a per-platform manifest, verifies a **SHA512** against it, writes the
binary to `~/.local/bin/agy`, clears the macOS quarantine attribute, and runs `agy install`
to configure the shell.

Be aware that `agy install` appends a PATH line to **every** shell profile it finds:
`.zshrc`, `.zprofile`, `.bashrc`, `.bash_profile`, `.profile`, and
`.config/fish/config.fish`. An already-running shell will not see the new PATH; a new
terminal will. `--dir <path>` installs elsewhere.

## Auth

Sign-in is an interactive TUI flow and **must happen in a real terminal**. There is no
headless sign-in: without a TTY the process dies with

```
CLI error: bubbletea: error opening TTY: bubbletea: could not open TTY: device not configured
```

This includes Claude Code's `!` prefix, which provides no TTY. Faking `SSH_CONNECTION` /
`SSH_TTY` to trigger the documented remote device-code flow does not help — the TTY check
happens first.

Unauthenticated commands fail clearly:

```
$ agy models
Error: Please sign in to view available models. Launch the CLI without arguments to sign in.
```

Once signed in interactively, headless runs reuse the cached credentials. The OAuth
authorization code the browser hands back is a **single-use credential bound to the waiting
process** — it goes into that terminal, never into a chat or a log.

State lives in `~/.gemini/antigravity-cli/` (note: under `~/.gemini`, shared with the
now-defunct Gemini CLI path):

| Path                                           | Holds                                            |
| ---------------------------------------------- | ------------------------------------------------ |
| `settings.json`                                | Permissions and CLI settings — absent by default |
| `cli.log` → `log/cli-<timestamp>.log`          | Startup diagnostics, permission decisions        |
| `conversations/`, `conversation_summaries.db`  | Session history                                  |
| `cache/default_project_id.txt`                 | Default project                                  |
| `crashes/`, `updater/`, `brain/`, `knowledge/` | Internal                                         |

## Invocation

| Form              | Mode                                                |
| ----------------- | --------------------------------------------------- |
| `agy`             | Interactive TUI — needs a real TTY                  |
| `agy -p "prompt"` | Headless (`--print` / `--prompt` are the same flag) |
| `agy -i "prompt"` | Prompt, then stay interactive                       |
| `agy --acp`       | Agent Client Protocol server                        |

**`-p` does not read stdin.** Verified: piping `MARKER-XYZZY-4711 is the secret token` and
asking for the token returned `NONE` with `status: SUCCESS`. Anything the model must see
goes in the prompt argument, or through `--input-format stream-json`.

Prompt size is bounded by `ARG_MAX` (1 MB on macOS), so a 47 KB review bundle passes
comfortably as an argument.

## Flags

| Flag                             | Purpose                                                                            |
| -------------------------------- | ---------------------------------------------------------------------------------- |
| `-p`, `--print`, `--prompt`      | Headless run                                                                       |
| `--model`                        | Model id; `agy models` lists them                                                  |
| `--effort`                       | `low`, `medium`, `high` — only unsuffixed `gemini-*` ids accept it                 |
| `--agent`                        | Select a named agent (`agy agents`)                                                |
| `--output-format`                | `text` (default), `json`, `stream-json`                                            |
| `--input-format`                 | `text` (default), `stream-json`; the latter requires `--output-format stream-json` |
| `--json-schema`                  | Schema string or `.json` path to constrain output                                  |
| `--print-timeout`                | Default `5m0s`                                                                     |
| `--disable-slash-commands`       | Stop prompt content being expanded as slash commands                               |
| `-c`, `--continue`               | Resume the most recent conversation                                                |
| `--conversation <ID>`            | Resume a specific one                                                              |
| `--add-dir <DIR>`                | Add a directory to the workspace (repeatable)                                      |
| `--mode`                         | `accept-edits` or `plan`                                                           |
| `--dangerously-skip-permissions` | Auto-approve every tool                                                            |
| `--sandbox`                      | Terminal restrictions                                                              |
| `--new-project`, `--project`     | Project selection                                                                  |
| `--log-file`                     | Override the log path                                                              |

Subcommands: `models`, `agents`, `mcp`, `plugin`, `install`, `update`, `changelog`,
`remote-control`, `mic-serve`.

`agy models` prints the listing on **stdout**, one `<id>\t<label>` per line, and its
`Fetching available models...` progress note on **stderr** — so the listing can be parsed
without filtering. It needs auth and a network round-trip (~3s measured); `agy-review`
uses it to resolve its default model and caches the answer for a day.

Always pass `--disable-slash-commands` when the prompt carries user or repository content —
a diff line beginning with `/` is otherwise expanded.

## Output

### `--output-format json`

One object on stdout:

```json
{
  "conversation_id": "8849d232-d82b-454f-b31e-fe23d47b3d6b",
  "status": "SUCCESS",
  "response": "PONG\n",
  "duration_seconds": 2.62,
  "num_turns": 1,
  "usage": {
    "input_tokens": 13282,
    "output_tokens": 2,
    "thinking_tokens": 0,
    "cache_read_tokens": 0,
    "total_tokens": 13284
  }
}
```

`error` appears on failure; `denied_actions` appears when a tool was auto-denied. Both
matter more than the exit code — see `headless-permissions.md`.

`num_turns`, `duration_seconds` and `usage` are **cumulative for the conversation**, not
for the turn.

### `--output-format stream-json`

NDJSON: one `init`, many `step_update`, one terminal `result`. Tool steps carry
`tool_name`, `tool_info.parameters`, and `tool_info.output` or `tool_info.error`. Keep
stderr separate — the `jetski:` auto-deny warning is not JSON.

### `--output-format text`

The response prose alone on stdout. Diagnostics — errors, progress, permission notices —
always go to **stderr**, which keeps the captured answer clean but means discarding stderr
discards the explanation of any failure.

## Exit codes

| Code | Meaning                                                                                |
| ---- | -------------------------------------------------------------------------------------- |
| 0    | `SUCCESS` — **including runs whose every tool was denied and whose response is empty** |
| 1    | `ERROR` — bad flags, unknown model, not signed in                                      |
| 2    | `ERROR` — unsupported stream message under `--input-format stream-json`                |

## Models

`agy models` prints `id<TAB>label`. Live list on 2026-09-07, unchanged from
2026-09-05:

```
gemini-3.8-flash-high      Gemini 3.8 Flash (High)
gemini-3.8-flash-medium    Gemini 3.8 Flash (Medium)
gemini-3.8-flash-low       Gemini 3.8 Flash (Low)
gemini-3.7-flash-high/medium/low
gemini-3.6-flash-high/medium/low
gemini-3.1-pro-high        Gemini 3.1 Pro (High)
gemini-3.1-pro-low         Gemini 3.1 Pro (Low)
claude-sonnet-4-6          Claude Sonnet 4.6 (Thinking)
claude-opus-4-6-thinking   Claude Opus 4.6 (Thinking)
gpt-oss-120b-medium        GPT-OSS 120B (Medium)
```

Effort is expressed **either** by the suffix in the id **or** by `--effort` on the base
name. Both together is an error:

```
$ agy -p "..." --model gemini-3.8-flash-low --effort high
{"status":"ERROR","error":"invalid model selection (--model \"gemini-3.8-flash-low\"
 --effort \"high\"): --model gemini-3.8-flash-low conflicts with --effort=high"}
```

`--model gemini-3.8-flash --effort high` works, as does `--effort low` with no `--model`.

Some models refuse `--effort` outright rather than conflicting with it:

```
$ agy -p "..." --model claude-sonnet-4-6 --effort high
{"status":"ERROR","error":"invalid model selection (--model \"claude-sonnet-4-6\"
 --effort \"high\"): --effort is not supported for model \"claude-sonnet-4-6\""}
```

So the rule is narrower than "unsuffixed ids take `--effort`": only **unsuffixed
`gemini-*`** ids do. A suffixed id conflicts, and every Claude id refuses outright —
`claude-sonnet-4-6` carries no suffix and still rejects it.

`agy-review` applies its **default** effort under exactly that rule, and forwards an
**explicit** `--effort` unconditionally, including to models that will reject it, so
`agy`'s own error reaches you instead of being silently dropped.

It is also why its default model is the **unsuffixed** newest Flash: every id the listing
offers carries a suffix, and resolving to `gemini-3.8-flash-high` would turn the default
`--effort high` into the conflict above.

A long prompt that invites a long answer can also fail after the model has run:

```json
{"status":"ERROR","response":"",
 "error":"Your previous response was cut off because it exceeded the output token limit.
          Please continue from where you left off... Retries remaining: 3"}
```

Observed on a 57 KB review prompt. Cap the requested output in the prompt itself.

An unknown model is **never silently substituted**: exit 1, `"status":"ERROR"`, and the
full available list inside `.error`.

## Sessions

```bash
agy -p "follow-up" --continue --output-format json </dev/null
agy -p "follow-up" --conversation <ID> --output-format json </dev/null
```

`conversation_id` is returned in every envelope. Multi-turn inside a single process needs
`--input-format stream-json`, fed one NDJSON message per line; closing stdin ends the
session.
