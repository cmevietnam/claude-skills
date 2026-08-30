# Codex CLI reference

Verified against **codex-cli 0.149.1** on 2026-08-31 by reading `codex --help`,
`codex exec --help`, `codex exec review --help`, and `~/.codex/models_cache.json`.
Re-verify after every upgrade — flags move between releases.

## Subcommands worth knowing

| Command | Purpose |
|---|---|
| `codex exec [PROMPT]` | Non-interactive run (alias `codex e`) |
| `codex exec resume` | Continue a session by id, or `--last` |
| `codex exec fork` | Branch a previous session into a new one |
| `codex exec review` / `codex review` | Code review against the repository |
| `codex apply` | `git apply` the agent's latest diff to the working tree |
| `codex queue` | Queue a message for an existing session |
| `codex login status` / `codex login` | Check or perform auth |
| `codex doctor` | Diagnose install, config, auth, and runtime health |
| `codex update` | Upgrade in place (or `brew upgrade --cask codex`) |
| `codex sandbox` | Run a command inside Codex's own sandbox |
| `codex features` | Inspect feature flags |

## `codex exec` flags

| Flag | Purpose |
|---|---|
| `-m, --model <MODEL>` | Override the config default |
| `-c, --config <key=value>` | TOML override; dotted paths for nested values |
| `-s, --sandbox <MODE>` | `read-only`, `workspace-write`, `danger-full-access` |
| `-C, --cd <DIR>` | Working root for the agent |
| `--add-dir <DIR>` | Extra writable directories alongside the workspace |
| `--skip-git-repo-check` | Allow running outside a git repo — always pass this |
| `-o, --output-last-message <F>` | Write the final message to a file (clean capture) |
| `--json` | Emit events as JSONL on stdout |
| `--output-schema <FILE>` | JSON Schema constraining the final response shape |
| `-i, --image <FILE>...` | Attach images to the prompt |
| `-p, --profile <NAME>` | Layer `$CODEX_HOME/<name>.config.toml` over the base config |
| `--ephemeral` | Don't persist the session — this disables `resume --last` |
| `--enable` / `--disable <FEATURE>` | Shorthand for `-c features.<name>=true|false` |
| `--strict-config` | Error out on config keys this build doesn't recognise |
| `--ignore-user-config` | Skip `$CODEX_HOME/config.toml` (auth still uses `CODEX_HOME`) |
| `--ignore-rules` | Skip user and project execpolicy `.rules` files |
| `--approve-for-me` | Route approval requests through automatic review under `workspace-write` |
| `--color <always\|never\|auto>` | Output colour |

Removed: **`--full-auto` no longer exists.** `--sandbox workspace-write` is the
apply-edits mode.

Ask the user before `--sandbox danger-full-access` or
`--dangerously-bypass-approvals-and-sandbox`. Never use the latter outside an externally
sandboxed environment, and treat `--dangerously-bypass-hook-trust` the same way.

## `codex review` flags

`--uncommitted`, `--base <BRANCH>`, `--commit <SHA>`, `--title <TITLE>`, plus a positional
prompt for custom review instructions (`-` reads it from stdin).

## Streams and stdin

- Final agent message → **stdout**. Banner, reasoning, and errors → **stderr**.
- Default to `2>/dev/null`; on a non-zero exit, rerun once with `2>&1` to capture the
  error. Suppressing stderr hides failures, so never leave it suppressed while debugging.
- If stdin is piped *and* a prompt argument is given, stdin is appended as an extra
  `<stdin>` block — hence `</dev/null` on every argument-form invocation.

## Auth and failure modes

- **Quota exceeded** → the API key has no credit. The user adds billing at
  platform.openai.com, or switches to ChatGPT-plan auth with `codex login` (an interactive
  browser flow they must run themselves — suggest they type `! codex login`).
- **Exit 137 plus a macOS "will damage your computer" popup** → the installed build's
  signing certificate was revoked (seen on cask 0.107.0). Fix:
  `brew upgrade --cask codex`, then
  `xattr -d com.apple.quarantine "$(readlink -f /opt/homebrew/bin/codex)"`.
- **400 "requires a newer version of Codex"** → 5.6-class models are rejected by CLI
  builds older than 0.144. Upgrade.
- Any non-zero exit: stop, report it, rerun once with `2>&1`, then ask for direction
  rather than retrying blind.
- Warnings or partial results get summarised to the user with an `AskUserQuestion` about
  how to adjust — they are not silently dropped.

## Model cache

`~/.codex/models_cache.json` carries the live list: slug, default reasoning level, and
supported efforts per model. Read it rather than trusting a table that has gone stale.

```bash
python3 -c "
import json,os
d=json.load(open(os.path.expanduser('~/.codex/models_cache.json')))
for m in d['models']:
    if m.get('visibility')=='list':
        print(m['slug'], '| default:', m['default_reasoning_level'],
              '|', ','.join(x['effort'] for x in m['supported_reasoning_levels']))
"
```

Note that a model's own `default_reasoning_level` (Sol ships `low`) is overridden by
`model_reasoning_effort` in `~/.codex/config.toml` — check both before claiming what the
effective default is.
