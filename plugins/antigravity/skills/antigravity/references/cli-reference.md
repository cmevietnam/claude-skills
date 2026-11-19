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

As an argument, a prompt is bounded by `ARG_MAX` (1 MB on macOS), but **`agy` keeps only
the first 192000 bytes of a message**, whatever the input path. It wraps the message
(`<USER_REQUEST>` tags, the local time, on the first one a note naming the model), cuts
the wrapped text at 192000 bytes (191998 once, to end on a whole UTF-8 character),
appends `\n<truncated N bytes>`, and reports SUCCESS. Read on 2026-11-12 from the
requests agy records in `~/.gemini/antigravity-cli/conversations/<id>.db` (table
`gen_metadata`): 40 of 501 conversations had a message cut, `-p` prompts and stream-json
turns alike, from 2026-09-09 to agy 1.5.7; the longest wrapped message sent whole was
191568 bytes. `agy-review` holds every message to 170 KB.

The cut is agy's, not the model's. On 2026-11-15 (agy 1.5.9) a 260058-byte `-p` message
to `claude-opus-5-5-high`, with a random marker at its start, middle and end, was recorded
with `<truncated 68477 bytes>` in place of its tail and no end marker; the model saw the
filler up to line 2306 of 3126 and said the message was cut. The 170 KB refusal applies
to every model.

## Flags

| Flag                             | Purpose                                                                            |
| -------------------------------- | ---------------------------------------------------------------------------------- |
| `-p`, `--print`, `--prompt`      | Headless run                                                                       |
| `--model`                        | Model id; `agy models` lists them                                                  |
| `--effort`                       | `low`, `medium`, `high`, `xhigh`, `max` — base `gemini-*`, `claude-*` ids          |
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
| `--settings`                     | Settings for this run only, never saved: settings.json keys as JSON (agy 1.5.9)    |

Subcommands: `models`, `agents`, `mcp`, `plugin`, `install`, `update`, `changelog`,
`remote-control`, `mic-serve`.

**There is no flag for the output or thinking budget.** The full `agy --help` flag list is
the table above; nothing in it raises the limit that produces
`exceeded the output token limit`. Only `--model` and `--effort` move that budget, which
is why the remaining lever is to shrink the input.

**The budget differs by model.** What one response may spend, as agy reported it:

- `claude-opus-5-5-high`: **128000 output tokens**, `thinking_tokens: 0`. Measured on
  2026-11-15 (agy 1.5.9) with a prompt asking for numbered lines until cut off: 5818
  lines, `output_tokens: 128000`, then agy's own `error_message` step ("exceeded the
  output token limit. Please continue from where you left off, keeping your response
  shorter. Retries remaining: 3") and a continue request in the same run.
- `gemini-4-argon-high`: about **70000**, thinking included. Not measured the same way:
  Argon refused the filler prompt twice, and a list of the numbers 1 to 10000 in words
  stopped at line 216 with `status: ERROR`, blocked by Google's filter ("may contain
  material that resembles existing copyrighted works"). The figure is the 2026-10-15
  `--repo` overrun, `output_tokens: 69998` of which 63058 thinking (SKILL.md).

- `gemini-4-neon-high`: **more than 170000**, not reached. Measured on 2026-11-19 (agy
  1.5.12) with a prompt asking for "n: n squared" lines until cut off: one response (one
  `gen_metadata` row in agy's record, no continue step) ran until `--print-timeout 22m`
  ended it at 11570 lines, 170961 bytes, with `finished_reason: print_timeout` and no
  token counts. The same format, completed at 3000 lines, was 39436 bytes for
  `output_tokens: 40351` of which `thinking_tokens: 915`: one token a byte, so the cut
  answer was about 171000 visible tokens. A first wording, which named 60000 lines,
  was declined by the model itself as longer than one response can be.

So a Claude id has close to twice Argon's room, but a run that reaches it is expensive:
see Quota below. Neon has more room than either, and at the rate that probe wrote, about
7800 tokens a minute, a 9-minute `--print-timeout` ends a Neon answer near 70000 tokens:
for Neon the wall clock comes before the budget. So `agy-review`'s default `--timeout`
went from 9m to 20m on 2026-11-20, about 156000 tokens at that rate. Whether thinking
streams at the same rate was not measured.

**There is no long-output setting to turn on.** agy 1.5.9's settings page
(`antigravity.google/docs/settings`, read 2026-11-15) lists no key for output length or
thinking, and the binary holds no such setting. Its changelog (1.5.7) says the built-in
Gemini models run at a **65,535-token output limit**, which custom models behind an
enterprise gateway now share; only an admin `maxOutputTokens` for such a model overrides
it. On a Google sign-in account the budget is fixed per model.

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

With `--input-format stream-json` (agy 1.4.12) every turn ends in its own `result`
event, `{"event":"result","result":{...}}`, holding the fields of a `json` envelope.
Its `num_turns`, `duration_seconds` and `usage` are cumulative for the session. A turn
cut by `--print-timeout` still says `SUCCESS`, with a partial response and
`"finished_reason":"print_timeout"` (the field arrived in agy 1.4.11); after a failed
turn the session goes on to the next one.

### `--input-format stream-json`

Not in `agy --help`: found by probing agy 1.4.12, whose errors name the fields. One user
turn per line:

```json
{ "event": "user", "message": { "content": "<the turn's text>" } }
```

A `content` list of `{"type":"text","text":...}` parts was accepted too. A line
without `event` fails the run (`missing the "event" field`, exit 1); an unknown event
is skipped with a warning (`ignoring unsupported stream input message event`), and a run
of only those exits 0 having answered nothing. `--print-timeout` bounds each turn, not
the session: three turns of about 3 s each finished under a 6 s timeout, 9 s in total.
Each turn is a message of its own, cut past 192000 bytes like a `-p` prompt (above).

### `--output-format text`

The response prose alone on stdout. Diagnostics — errors, progress, permission notices —
always go to **stderr**, which keeps the captured answer clean but means discarding stderr
discards the explanation of any failure.

## Exit codes

| Code | Meaning                                                                                |
| ---- | -------------------------------------------------------------------------------------- |
| 0    | `SUCCESS` — **including runs whose every tool was denied and whose response is empty** |
| 1    | `ERROR` — bad flags, unknown model, not signed in, a stream-json line without `event`  |
| 3    | `ERROR` — a model or agent API failure (a spent quota); stderr has `AGY_ERROR: {...}`  |

## Quota

`agy -p /quota` costs nothing and prints one counter per line: group, counter, percent
remaining, reset time (UTC). On a Google AI Pro account on 2026-11-15 (agy 1.5.9):

```
Gemini Models          Weekly Limit Remaining       100%  2026-11-22T06:55:40Z
Gemini Models          Five Hour Limit Remaining    100%  2026-11-15T11:55:40Z
Claude and GPT models  Weekly Limit Remaining       100%  2026-11-22T06:55:40Z
Claude and GPT models  Five Hour Limit Remaining    100%  2026-11-15T11:55:40Z
Gemini 4 Argon         Gemini 4 Argon Weekly Limit  100%  2026-11-22T06:55:40Z
```

Every Claude and GPT id draws on one pair of counters, separate from Gemini's. Argon has
its own weekly counter and no five-hour one. Google publishes no sizes. Its plans page
(`antigravity.google/docs/plans`, read 2026-11-15) says Pro gets "a high, generous quota,
refreshed every five hours until the weekly limit is reached", Ultra "the highest", and
that the baseline limits "are primarily determined by available capacity". The percentages
are the only measure there is.

**The Claude counters are small.** On 2026-11-15 two probes on `claude-opus-5-5-high`
took them from 100% to **40% weekly and 0% five-hour**: one 260 KB message (83838 input
tokens, 64 output), and one answer cut at the 128000-token budget (7411 input). agy's
continue request after that cut failed with exit 3 and
`RESOURCE_EXHAUSTED (code 429): Individual quota reached. Please upgrade your subscription
to increase your limits. Resets in 4h44m41s.` Over the same hour four short Argon runs
moved its counter from 100% to 98%, and the Gemini counters stayed at 100%. Read `/quota`
before a large Claude run: one answer near its output budget can spend a whole five-hour
window and more than half a week.

## Models

`agy models` prints `id<TAB>label`. Live list on 2026-11-19 (agy 1.5.12, a Google AI Pro
sign-in), in the order printed:

```
gemini-4-neon-high              Gemini 4 Neon (High)
gemini-4-neon-xhigh             Gemini 4 Neon (XHigh)
gemini-4-neon-medium            Gemini 4 Neon (Medium)
gemini-4-neon-low               Gemini 4 Neon (Low)
gemini-4-argon-medium           Gemini 4 Argon (Medium)
gemini-4-argon-high             Gemini 4 Argon (High)
gemini-4-argon-low              Gemini 4 Argon (Low)
gemini-4-hydrogen-high          Gemini 4 Hydrogen (High)
gemini-4-hydrogen-xhigh         Gemini 4 Hydrogen (XHigh)
gemini-4-hydrogen-medium        Gemini 4 Hydrogen (Medium)
gemini-4-hydrogen-low           Gemini 4 Hydrogen (Low)
gemini-pro-orchestrator-neon    Orchestrator (Neon)
gemini-pro-orchestrator-g1-pro  Orchestrator (Argon)
gemini-3.8-flash-high           Gemini 3.8 Flash (High)
gemini-3.8-flash-medium         Gemini 3.8 Flash (Medium)
gemini-3.8-flash-low            Gemini 3.8 Flash (Low)
claude-opus-5-5-low/medium/high
claude-sonnet-5-5-low/medium/high
gpt-oss-120b-medium             GPT-OSS 120B (Medium)
```

The list of 2026-11-15 (agy 1.5.9) had the same ids without the four Neon lines and
Orchestrator (Neon). agy 1.5.12's changelog adds Neon only "when you connect with a
`GEMINI_API_KEY`", yet a Google sign-in listed it, as it listed Hydrogen on 2026-11-15,
which 1.5.8's changelog names only for an API key and Application Default Credentials. The lists of 2026-11-01 (agy 1.4.10, then recorded as a Google AI Ultra account)
and 2026-10-14 (agy 1.3.4) also lacked the four Hydrogen lines and Orchestrator (Argon).

`agy-review`'s default is none of these lines as printed: it is the base id
`gemini-4-neon` with `--effort high`, which selects the same model and level as
`gemini-4-neon-high`. agy's own record of a probe run that way on 2026-11-19 (table
`gen_metadata` of the conversation's `.db`) names `gemini-4-neon-high`.

The lines depend on the account's plan, and they change without an agy update. Google's
models page (`antigravity.google/docs/models`, read 2026-11-15) lists Gemini 4 Argon and
Orchestrator (Argon) for paid Google AI Pro plans (or a trial on eligible premium
devices), Ultra and Enterprise; Claude Sonnet 5.5 and Opus 5.5 for Pro "for non-trial
subscriptions only", Ultra and Enterprise; Gemini 4 Carbon for Ultra and Enterprise only;
Hydrogen and 3.8 Flash on every plan. Claude Sonnet 4.6, Claude Opus 4.6 and GPT-OSS-120b
"will be removed on November 18, 2026". On 2026-10-14 the Argon lines were missing until
the account was upgraded, and `--model gemini-4-argon` answered `model gemini-4-argon is
not recognized as a known model or custom model in settings`. On 2026-11-15 they were
missing for some hours on agy 1.5.9 and back by 13:56 on the same version.

The list of 2026-09-25 (agy 1.2.11, unchanged from 2026-09-05) was different, and the
transcripts below were recorded against it:

```
gemini-3.8-flash-high      Gemini 3.8 Flash (High)
gemini-3.8-flash-medium    Gemini 3.8 Flash (Medium)
gemini-3.8-flash-low       Gemini 3.8 Flash (Low)
gemini-3.7-flash-high/medium/low
gemini-3.6-flash-high/medium/low
gemini-3.1-pro-high        Gemini 3.1 Pro (High)   <- banned, agy-review refuses it
gemini-3.1-pro-low         Gemini 3.1 Pro (Low)    <- banned, agy-review refuses it
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
Argon follows the same rule (agy 1.3.4): `--model gemini-4-argon --effort high` and
`--effort medium` both returned `SUCCESS`, and `--model gemini-4-argon-low --effort high`
failed with `--model gemini-4-argon-low conflicts with --effort=high`. Neon takes it on
the base id too: `--model gemini-4-neon --effort high` returned `SUCCESS` (agy 1.5.12,
2026-11-19). The `-xhigh` ids follow the rule as well (agy 1.5.12, 2026-11-20):
`--model gemini-4-neon-xhigh --effort high` failed with `--model gemini-4-neon-xhigh
conflicts with --effort=high`, while `--model gemini-4-neon-xhigh` alone and
`--model gemini-4-neon --effort xhigh` returned `SUCCESS`. agy 1.5.12's `--help` lists
`--effort low|medium|high|xhigh|max`; no `-max` id was listed.

The Claude and GPT-OSS ids follow it as well (agy 1.3.4):

```
$ agy -p "..." --model claude-opus-5-5 --effort high       -> SUCCESS
$ agy -p "..." --model claude-sonnet-5-5 --effort medium   -> SUCCESS
$ agy -p "..." --model claude-opus-5-5                     -> SUCCESS (agy picks the level)
$ agy -p "..." --model gpt-oss-120b --effort medium        -> SUCCESS
$ agy -p "..." --model claude-opus-5-5-low --effort high
{"status":"ERROR","error":"invalid model selection (--model \"claude-opus-5-5-low\"
 --effort \"high\"): --model claude-opus-5-5-low conflicts with --effort=high"}
$ agy -p "..." --model gpt-oss-120b-medium --effort high
{"status":"ERROR","error":"invalid model selection (--model \"gpt-oss-120b-medium\"
 --effort \"high\"): --model gpt-oss-120b-medium conflicts with --effort=high"}
```

That was not always so. On agy 1.1.27 the Claude ids refused `--effort` outright rather
than conflicting with it, and `claude-sonnet-4-6` carried no suffix and still rejected it:

```
$ agy -p "..." --model claude-sonnet-4-6 --effort high
{"status":"ERROR","error":"invalid model selection (--model \"claude-sonnet-4-6\"
 --effort \"high\"): --effort is not supported for model \"claude-sonnet-4-6\""}
```

Those ids are gone from the listing, and the same wording is now what an unknown id gets
when `--effort` is passed (see the end of this section).

`agy-review` applies its **default** effort to a `gemini-*` or `claude-*` id without an
effort suffix (`-low`, `-medium`, `-high`, `-xhigh`, `-max`) only. Any other family gets
no flag and `agy` picks the level, so a model that takes no effort still runs. It
forwards an **explicit** `--effort` unconditionally, including to ids that will reject
it, so `agy`'s own error reaches you instead of being silently dropped.

It is also why its pinned default is the **unsuffixed** `gemini-4-neon`: every id the
listing offers carries a suffix, and pinning `gemini-4-neon-high` would turn the default
`--effort high` into the conflict above.

A long prompt that invites a long answer can also fail after the model has run:

```json
{"status":"ERROR","response":"",
 "error":"Your previous response was cut off because it exceeded the output token limit.
          Please continue from where you left off... Retries remaining: 3"}
```

Observed on a 57 KB review prompt. Cap the requested output in the prompt itself.

An unknown model is **never silently substituted**: exit 1 and `"status":"ERROR"`. What
`.error` holds depends on `--effort` (agy 1.3.4, `--model gemini-9-nope`):

- without `--effort`: `model gemini-9-nope is not recognized as a known model or custom
model in settings`, followed by `Available models:` and the full list of labels;
- with `--effort high` (and so with any `--effort`, which `agy-review` sends with every
  unsuffixed `gemini-*` or `claude-*` id): only
  `--effort is not supported for model "gemini-9-nope"`, and no list.

## Sessions

```bash
agy -p "follow-up" --continue --output-format json </dev/null
agy -p "follow-up" --conversation <ID> --output-format json </dev/null
```

`conversation_id` is returned in every envelope. Multi-turn inside a single process needs
`--input-format stream-json`, fed one NDJSON message per line; closing stdin ends the
session. The message shape is under `--input-format stream-json` above; `agy-review`
uses it for a diff bigger than one part.
