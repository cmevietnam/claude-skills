# onepassword

Reach a project's secrets in 1Password. Every time `opgate` reads from or writes to
the **vault**, macOS shows a Touch ID sheet naming which project is asking for which
variables to run which command. No approval, no command.

Stated precisely: the gate protects **reading or writing a secret value in the
vault**. What deliberately does not go through it:

- `scan` and `import --dry-run` read plaintext `.env` files on disk. The file is
  already sitting there and `cat` can read it; blocking here would add nothing.
  Neither **prints** a value.
- `scan`, `items`, `doctor`, and the checks `import`/`put` run before asking for a
  fingerprint, read vault **metadata** (item titles, category, tags) via
  `op item list` — no field values are in that. `import` additionally reads the
  `opgate_source` field (a path) to detect two files deriving the same item name. An
  item's secret values are only read **after** you approve.

Separately, `op run` resolves any `op://` variable already present in the environment
(for example `export GITHUB_TOKEN=op://…` in `.zshrc`). `opgate run` and `exec` list
those on the sheet under "from the environment", so you know they are resolved too.

**Scope, stated plainly:** this is a _cooperative control_ plus a layer of accident
prevention, not a sandbox. It binds whoever calls `opgate`. 1Password authorizes `op`
per terminal session (roughly 10 minutes, self-renewing, inherited by child
processes), so anything that can run a command as you can call `op` directly and skip
this tool. Real enforcement needs a broker in an environment where the agent cannot
see `op` — a different architecture, not a patch. The full list of known ways around
it is in `skills/onepassword/references/security-model.md`; read it before trusting
the tool.

## Why another layer is needed

The 1Password desktop app integration authorizes `op` **per terminal session**: after
the first Touch ID, every later `op` command in that session goes through. For a
person typing, that is sensible; for an agent running hundreds of commands, it is
not. `opgate` builds its own authentication layer at the CLI level — meaning Claude,
Codex and shell scripts all pass through it _when they use `opgate`_. Nothing forces
them to; see the scope note above.

The second problem is specific to the agent era: if an agent runs a command that
prints a secret, the value goes to stdout → into the transcript → to the model
provider. That is why `opgate` has **no `read` command**, and why `op run` — which
masks values in its output — is the primary primitive.

## Install

```bash
claude plugin marketplace add cmevietnam/claude-skills
claude plugin install onepassword@hieuvo-skills
```

One-time setup:

```bash
op vault create Dev     # where project secrets live
opgate build            # compile the Touch ID gate (needs Xcode CLT)
opgate doctor           # everything should be green
```

Requirements: a Mac with Touch ID, 1Password 8 with **Settings ▸ Developer ▸
Integrate with 1Password CLI** enabled, the `op` CLI, and Xcode command line tools.

## Use

```bash
opgate scan                   # find .env files and embedded secrets across the project
opgate import api/.env        # move one file into the vault, generate .env.op
opgate items -p cme           # which items this project has in the vault
opgate list                   # which secrets the project has (no values)
opgate run -- npm run dev     # run the app with the secrets in its env
opgate copy op://Dev/x/API_KEY
opgate put myapp DB_URL       # put a secret INTO the vault (--multiline for PEM/JSON)
opgate audit -n 20            # what was reached for recently
```

Also needed: `jq` (`brew install jq`) for `opgate put` and `opgate import`.
`opgate doctor` checks for it.

Five test suites, no fingerprint required. Four of them need no vault;
`test-parser.sh` has an extra section that **measures directly against `op run`** —
it runs when 1Password is unlocked and skips itself when it is not:

```bash
bash plugins/onepassword/scripts/test-guards.sh    # the three PreToolUse hooks
bash plugins/onepassword/scripts/test-grants.sh    # approval windows, Pre/Post handshake
bash plugins/onepassword/scripts/test-classify.sh  # secret / config classification
bash plugins/onepassword/scripts/test-scan.sh      # scanning + item naming
bash plugins/onepassword/scripts/test-parser.sh    # the dotenv parser vs op run
```

## Moving a project into the vault

```bash
opgate scan                    # see what there is, without reading a value out
opgate import api/.env         # one Touch ID for the whole file
opgate run -f api/.env.op -- npm run dev
```

`import` creates an item named `<project>-<directory>-<environment>` (for example
`cme-api`, `cme-web-production`) tagged `opgate` and `project:<name>`, then writes a
reference file next to the original: `.env` → `.env.op`, `.env.production` →
`.env.production.op`. It **neither deletes nor backs up** the original — the original
is still there, so a second plaintext copy would only widen the exposure without
adding safety. If you want one anyway, pass `--backup`, and remember to delete it.

`import` refuses to overwrite when the item exists but was not created by opgate (no
`opgate` tag), when two different files derive the same item name, and when the
target `.op` file is being generated from a different source. `--force` skips those
checks.

Only variables whose **name matches an exact allowlist** (`NODE_ENV`, `PORT`,
`LOG_LEVEL`, `API_URL`…) stay in the `.op` file as literals. There are no wildcards,
and no rule looks at a _value_ to demote a variable to a literal — three consecutive
review rounds broke three versions that had such a rule (`DB_PASS=hunter2` was once
classified "config"; `PUBLIC_PASSCODE` once matched `PUBLIC_*`). For every other
variable it does not recognise as a secret, `import` **asks you**, and the question
describes only the shape of the value — `30 chars · lower/UPPER/symbols` — never the
value. With no terminal it stops rather than guessing, unless you pass `--yes` (send
everything to the vault). You will be asked more often; that is the price of an `.op`
file that is genuinely safe to commit.

`opgate scan` also reports secrets sitting **inside config or source files** (an AWS
key in a `settings.local.json`, a JWT in a JSON file). It reports only `file:line` and
the credential type, prints no values, and fixes nothing automatically — fixing those
needs a code change, and if it is a real credential the first step is to rotate it.

See `skills/onepassword/references/project-setup.md` for taking a project from a
plaintext `.env` to 1Password.

## For Codex and ordinary shells

`opgate` is a plain shell script with no dependency on Claude Code:

```bash
ln -s "$(claude plugin path onepassword 2>/dev/null || echo ~/.claude/plugins/cache/hieuvo-skills/onepassword/*/)"/bin/opgate ~/.local/bin/opgate
```

Codex has no hook system, so put the rules in the project's `AGENTS.md` (there is a
template in `project-setup.md`). The Touch ID gate stops Codex **when Codex uses
`opgate`** — it sits at the CLI level and does not care who calls it. But nothing
stops Codex from calling `op` directly, exactly as with any process running under
your account. See the scope note at the top of this file and
`references/security-model.md`.

## Configuration

| Variable                | Default   | Meaning                                                           |
| ----------------------- | --------- | ----------------------------------------------------------------- |
| `OPGATE_VAULT`          | `Dev`     | The vault holding project secrets                                 |
| `OPGATE_ENV_FILE`       | `.env.op` | Default secret-reference filename                                 |
| `OPGATE_ALLOW_PASSWORD` | off       | Set to `1` to accept the device password instead of a fingerprint |

No variable disables or weakens the gate. Earlier versions had `OPGATE_GATE=none` and
`OPGATE_TTL`; both let a single environment variable skip the prompt, so both were
removed.

## Hooks

The plugin installs three `PreToolUse` hooks and one `PostToolUse` hook:

- **Bash** — blocks direct calls to `op` that surface a value (`op item get`,
  `op run`, `--reveal`, `--raw`, `op item share`, `op service-account create`,
  `op connect token create`, and the plain value-printing subcommand), including
  through `bash -c`, and asks before `cat`/`grep`/`sort`/`diff`/`cp`/`source` on a
  plaintext secret file.
- **Read** — asks before the Read tool opens `.env`, `.envrc`, `*.pem`, `id_rsa`,
  `.netrc`, `.git-credentials`… Skips `.env.example`, `.env.op`, `*.pub`.
- **Grep** — asks when Grep points straight at a secret file. A directory-wide Grep is
  **not** asked about (too noisy) and can still read a `.env` inside it — see
  `security-model.md`.
- **PostToolUse (Bash|Read|Grep)** — when you approve one of the prompts above, this
  hook records that decision as a **60-minute window for that one file**, so it is not
  asked again. It classifies nothing itself: the PreToolUse hook already wrote the key
  into `pending/<call-id>`, and the only job here is promoting it to a grant.

The hooks are an **accident-prevention** layer, not a sandbox. The layer that actually
enforces is the Touch ID gate. Details:
`skills/onepassword/references/security-model.md`.

## Approval windows (`unlock` / `grants` / `lock`)

```bash
opgate grants                          # which windows are open, and for how long
opgate unlock --minutes 60 .env        # open one up front, with one Touch ID
opgate lock                            # close them all now
opgate lock .env                       # close exactly one file
```

These affect the hook layer only. They cannot skip a Touch ID prompt, cannot reach the
vault, and never turn a `deny` into an `allow` — direct `op` calls stay blocked as
before. A window is keyed by **resolved path**, so approving `.env` does not open
`.env.production`, and a command reading two secret files needs both windows.

`opgate doctor` warns when a window is still open. Why this is a different trade from
the removed `OPGATE_TTL`: see `security-model.md`.

## You may see two prompts in a row

The 1Password authorization session expires fairly quickly. When it has, one `opgate`
command shows **two** dialogs: opgate's own Touch ID sheet (naming project, variables
and command), then 1Password's own prompt to reopen the CLI session. Those are two
different layers, not a bug. If `op` reports `authorization timeout`, unlock the
1Password app again.

The Touch ID sheet appears every time and never reuses a recent unlock — verified via
`touchIDAuthenticationAllowableReuseDuration = 0`. When two sheets appear seconds
apart it is easy to tap the wrong one; read the description line before you do.

## Exit codes

| Code | Meaning                                                                                                            |
| ---- | ------------------------------------------------------------------------------------------------------------------ |
| `77` | You declined at the Touch ID sheet — the command did not run                                                       |
| `78` | The prompt could not be shown, or the gate binary does not match the hash recorded at build time → `opgate doctor` |

## The log

`~/.local/state/opgate/access.log` (chmod 600), tab-separated:
`time · status · caller · project · action · variable names`. It holds no values.

Statuses relating to approval windows: `GRANT` (opened; the action field is `unlock`
or `auto`), `GRANT-USED` (one time a hook let something through because of a window),
`GRANT-REVOKED`. A grant that exists with no matching `GRANT` record is a sign
somebody wrote the file themselves — that is **evidence**, not a blocking mechanism.
