# Codex CLI reference

The default `gpt-6.2-sol` at `xhigh` was tested on **codex-cli 0.171.0** on 2026-11-22.
Use `--help` on the exact subcommand to check its flags after an upgrade.

## Subcommands worth knowing

| Command                              | Purpose                                                 |
| ------------------------------------ | ------------------------------------------------------- |
| `codex exec [PROMPT]`                | Non-interactive run (alias `codex e`)                   |
| `codex exec resume`                  | Continue a session by id, or `--last`                   |
| `codex exec fork`                    | Branch a previous session into a new one                |
| `codex exec review` / `codex review` | Code review against the repository                      |
| `codex apply`                        | `git apply` the agent's latest diff to the working tree |
| `codex queue`                        | Queue a message for an existing session                 |
| `codex login status` / `codex login` | Check or perform auth                                   |
| `codex doctor`                       | Diagnose install, config, auth, and runtime health      |
| `codex update`                       | Upgrade in place (or `brew upgrade --cask codex`)       |
| `codex sandbox`                      | Run a command inside Codex's own sandbox                |
| `codex features`                     | Inspect feature flags                                   |

## `codex exec` flags

| Flag                               | Purpose                                                                  |
| ---------------------------------- | ------------------------------------------------------------------------ |
| `-m, --model <MODEL>`              | Override the configured model. The skill defaults to `gpt-6.2-sol`       |
| `-c, --config <key=value>`         | TOML override; dotted paths for nested values                            |
| `-s, --sandbox <MODE>`             | `read-only`, `workspace-write`, `danger-full-access`                     |
| `-C, --cd <DIR>`                   | Working root for the agent                                               |
| `--add-dir <DIR>`                  | Extra writable directories alongside the workspace                       |
| `--skip-git-repo-check`            | Allow running outside a git repo — always pass this                      |
| `-o, --output-last-message <F>`    | Write the final message to a file (clean capture)                        |
| `--json`                           | Emit events as JSONL on stdout                                           |
| `--output-schema <FILE>`           | JSON Schema constraining the final response shape                        |
| `-i, --image <FILE>...`            | Attach images to the prompt                                              |
| `--oss` + `--local-provider <P>`   | Run a local model through lmstudio or ollama                             |
| `--thread-source <SOURCE>`         | Source classification for new or forked threads                          |
| `-p, --profile <NAME>`             | Layer `$CODEX_HOME/<name>.config.toml` over the base config              |
| `--ephemeral`                      | Don't persist the session — this disables `resume --last`                |
| `--enable` / `--disable <FEATURE>` | Shorthand for `-c features.<name>=true\|false`                           |
| `--strict-config`                  | Error out on config keys this build doesn't recognise                    |
| `--ignore-user-config`             | Skip `$CODEX_HOME/config.toml` (auth still uses `CODEX_HOME`)            |
| `--ignore-rules`                   | Skip user and project execpolicy `.rules` files                          |
| `--approve-for-me`                 | Route approval requests through automatic review under `workspace-write` |
| `--color <always\|never\|auto>`    | Output colour                                                            |

Removed: **`--full-auto` no longer exists.** `--sandbox workspace-write` is the
apply-edits mode.

Ask the user before `--sandbox danger-full-access` or
`--dangerously-bypass-approvals-and-sandbox`. Never use the latter outside an externally
sandboxed environment, and treat `--dangerously-bypass-hook-trust` the same way.

## `codex review` flags

Choose a single review target (`--uncommitted`, `--base <BRANCH>`, `--commit <SHA>`,
or a positional custom prompt). Include the scope in the custom prompt if you also
need to give specific instructions. Use `-` to read the prompt from stdin.

`codex exec review` accepts `-m` and `-o`. Pin the skill defaults with `-m gpt-6.2-sol`,
`-c 'review_model="gpt-6.2-sol"'`, and `-c 'model_reasoning_effort="xhigh"'`. Set the
sandbox with `-c 'sandbox_mode="read-only"'`. The review thread reads `review_model`
before falling back to the parent model. [Codex CLI source](https://github.com/openai/codex/blob/rust-v0.171.0/codex-rs/core/src/session/review.rs)

For standalone `codex review`, use `-c 'model="gpt-6.2-sol"'` in place of `-m`.
Use `codex exec review` when you need `-o` to capture the final message.

## `codex exec resume` and `fork`

Both subcommands take `-m`, `-c`, `-o`, and `--skip-git-repo-check`. Pass
`-c 'sandbox_mode="..."'` to set the sandbox. `resume` accepts `--last` and `--all`.
`fork` requires the saved session ID.

Pass the model, reasoning effort, and sandbox explicitly on every resume. Earlier
CLI versions applied current config defaults to resumed sessions when flags were
omitted. Check the banner for the settings used.

Without `--skip-git-repo-check`, a resume outside a trusted directory exits 1 with
`Not inside a trusted directory and --skip-git-repo-check was not specified.`

## Streams and stdin

- Final agent message → **stdout**. Banner, reasoning, and errors → **stderr**.
- Default to `2>/dev/null`; on a non-zero exit, rerun once with `2>&1` to capture the
  error. Suppressing stderr hides failures, so never leave it suppressed while debugging.
- If stdin is piped _and_ a prompt argument is given, stdin is appended as an extra
  `<stdin>` block — hence `</dev/null` on every argument-form invocation. 0.153.4 still
  prints `Reading additional input from stdin...` to stderr even with `</dev/null`; that
  line is noise, not a sign the redirect failed.

## Auth and failure modes

- **Quota exceeded** → the API key has no credit. The user adds billing at
  platform.openai.com, or switches to ChatGPT-plan auth with `codex login` (an interactive
  browser flow they must run themselves — suggest they type `! codex login`).
- **Exit 137 plus a macOS "will damage your computer" popup** → the installed build's
  signing certificate was revoked (seen on cask 0.107.0). Fix:
  `brew upgrade --cask codex`, then
  `xattr -d com.apple.quarantine "$(readlink -f /opt/homebrew/bin/codex)"`.
- **400 "requires a newer version of Codex"** → update with `codex update` or
  `brew upgrade --cask codex`.
- **A model the release notes announced is missing from the list** → the cache is stale.
  It refreshes on a real `codex exec` run, not from `codex doctor`, so run something
  trivial first and re-read the file.
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

The CLI flags override the corresponding defaults in `~/.codex/config.toml`.
The skill passes `-m gpt-6.2-sol -c 'model_reasoning_effort="xhigh"'` each time,
with `review_model` set explicitly for reviews.
