# What the hook refuses, and why

The guard is `PreToolUse(Bash)` → `scripts/guard-linode.sh`.

## How far "fail closed" goes

When ownership cannot be verified — the API fails, the id does not exist, the
action is unknown, or this script itself errors halfway — the answer is
**refuse**. A latch that opens itself when in doubt is worse than no latch.

There is exactly **one** case it cannot decide, and it deserves saying plainly: if
the whole hook exceeds the `timeout` declared in `hooks/hooks.json` (15 seconds),
Claude Code kills the hook and **discards its decision** — the command proceeds
through the normal permission flow. There is no way for a timed-out hook to mean
"block". So every API call in one hook run shares **one budget**
(`LINGATE_BUDGET`, default 11 seconds); each call gets what is left, capped at
`LINGATE_DEADLINE` (8 seconds), via `perl -e alarm` and `--no-retry`. When the
budget is spent, `resolve_tags` fails and the guard **refuses** while there is
still time to answer — even when a command has to look up three resources (owner,
target, parent cluster). What remains of the fail-open window is bash itself
hanging, not a slow network.

And one limitation that is inherent, not a bug: the hook reads the **text** of a
command; it does not execute it. Content held in a variable is invisible to it —
`bash -c "$CMD"`, `eval "$SCRIPT"`, `$RUNNER linodes delete 1` pass as unrelated
commands. Ids and tags in variables are the opposite: a visible `$` is a
**refusal**, because there, unreadable means unverifiable. And an unknown head
with `linode-cli` behind it **asks**. Three different treatments for three
different situations, and the first is the one this hook can never close by
reading strings.

It is not a sandbox. It stops the ordinary mistake before it becomes an incident;
it does not resist a deliberate actor.

## Rule table

| Situation                                                                                                          | Decision                                                              |
| ------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------- |
| Any read (`list`, `view`, `*-list`, `*-view`…)                                                                     | pass                                                                  |
| A credential read (`*-creds-view`, `kubeconfig-view`, `keys-list`, `*-ssl-cert`) without a redirect/pipe           | **ask**                                                               |
| Create of a taggable type missing `--tags <project>` or `--tags <env>`                                             | **refuse**                                                            |
| Create of an untaggable type missing `--json`                                                                      | **refuse** (cannot be recorded)                                       |
| Write to a resource with the right project tag and the right env                                                   | pass                                                                  |
| Write to a resource tagged with another project                                                                    | **refuse**                                                            |
| Write to a resource with no tags                                                                                   | **refuse**, pointing at `lingate adopt`                               |
| Write to this project's resource in a **different env**                                                            | **refuse** (CROSS-ENV)                                                |
| Resource with several env tags, project **without** `allowSharedEnvs`                                              | **refuse**                                                            |
| Shared-env resource whose other env **is protected**                                                               | **ask** (every time)                                                  |
| Shared-env resource whose other env is **not** protected                                                           | pass                                                                  |
| A second resource on the line (`--linode_id`, `--firewall_id`, `--id --type`, `--linodes`) outside the project/env | **refuse**                                                            |
| Ledger declares a `"tag"` other than the current project                                                           | **refuse**                                                            |
| Target id is a shell variable or JSON (`--linode_id $ID`)                                                          | **refuse** (unreadable is unverifiable)                               |
| `--tags $VAR`                                                                                                      | **refuse**                                                            |
| `linode-cli` behind a wrapper the hook **does not know** (`mystery-tool linode-cli …`)                             | **ask**                                                               |
| Ledger create sharing a Bash call with another `linode-cli` invocation                                             | **refuse** (the recording hook cannot tell which id is which)         |
| Credential read piped into something that still prints (`\| base64 -d`), or with only stderr redirected            | **ask** (not a sink yet)                                              |
| Write in an env listed in `protectedEnvs`                                                                          | **ask**                                                               |
| `--tags` on a write dropping the project tag or the env tag                                                        | **refuse**                                                            |
| `--tags` adding a second env tag                                                                                   | **refuse** (ambiguous resource)                                       |
| Anything with `--help`, or a local help topic (`commands`, `env-vars`, `plugins`)                                  | pass (never reaches the API)                                          |
| `tags create/delete` with a label that is neither the project tag nor an env                                       | **refuse**                                                            |
| `tags create --linodes/--volumes/…` (attaching a tag directly to resources)                                        | **refuse**, pointing at `lingate adopt`                               |
| `tags delete` of the project's own project or env tag                                                              | **ask** (deleting a tag strips it from every resource on the account) |
| Ledger create with stdout piped or redirected                                                                      | **refuse** (the recording hook cannot read the id)                    |
| Several ledger creates in one Bash call                                                                            | **refuse** (cannot tell which id is which)                            |
| `--root_pass` with a literal value                                                                                 | **refuse**                                                            |
| No `.linode/project.json` found                                                                                    | **refuse**                                                            |
| Tags cannot be read (API error, unknown id)                                                                        | **refuse**                                                            |
| Action not classifiable as read or write                                                                           | **refuse**                                                            |
| Write to account-level state (`account`, `users`, `profile`…)                                                      | **refuse**                                                            |
| `linode-cli configure`, `set-user`, `remove-user`                                                                  | **ask**                                                               |

## One resource, one environment — and the declared exception

By default a resource may carry **one** env tag. Two is ambiguous, and worse: it
turns every command run in staging into one that can reach prod.

Reality sometimes differs: one box serves both environments to save cost. That is
a legitimate choice, but it must be **stated**, in `.linode/project.json`:

```json
{ "allowSharedEnvs": true }
```

Once enabled:

- A command running in an env within the resource's env set → allowed.
- If the resource also serves another env that is **protected** (usually `prod`),
  **every write asks**, with a reminder that the change reaches prod as well.
  Sharing between `dev` and `staging` asks nothing — there is nothing to lose.
- A command running in an env **outside** that set is still refused as usual.

`lingate doctor` lists every shared-env resource and calls it what it is:
technical debt. The target state is still one resource, one environment; the
flag only makes the gap between now and that target visible, instead of letting
it become an invisible habit.

## Where the env comes from

In order: a `LINODE_ENV=…` prefix on the command line → the `LINODE_ENV`
environment variable → `defaultEnv` in the config.

The prefix on the command line is the only reliable one: the hook runs in its own
process and inherits nothing from the command about to run — it reads the text
`LINODE_ENV=` out of the command itself.

## Which types can carry tags

Verified against `linode-cli` v5.67.0, not read from the docs:

| Taggable                                                                 | Not taggable                                                             |
| ------------------------------------------------------------------------ | ------------------------------------------------------------------------ |
| `linodes` `volumes` `nodebalancers` `domains` `lke` `firewalls` `images` | `databases` `vpcs` `object-storage` `placement` `stackscripts` `sshkeys` |

The right-hand group uses the `.linode/owned.json` ledger.

## How the hook reads a command line

- The line goes through a **real shell lexer**: `'...'`, `"..."` and `\` are
  handled correctly (so a `&&` inside a label does not split the command, and
  `--tags="cme --tags staging"` is **one** tag); a **newline** is a command
  boundary; `$( )` and backticks are opened **even inside double quotes**; a
  redirection's target (`> file`) is swallowed rather than taken as an id; heredoc
  bodies are skipped; a trailing `\` is line continuation.
- `bash -c "..."`, `sh -lc`, `eval …`, `env -S "…"` are opened and inspected as
  command lines of their own.
- A `linode-cli`/`linode`/`lin` token (matched by **basename**) only counts as an
  invocation where it would actually run: at the head of a segment, after a shell
  keyword (`do`, `then`, `!`, `{`, `time`), after an assignment
  (`LINODE_ENV=prod`), or after a wrapper whose **flag arity** the hook knows:
  `env`, `sudo`/`doas`, `command`, `exec`, `nohup`, `nice`, `stdbuf`, `timeout`,
  `xargs`, `watch`, `caffeinate`, and `opgate exec|run … --`. `sudo -u root`,
  `timeout 10`, `xargs -I{}` all land on the right word. `echo linode-cli`,
  `grep linode`, `cat linode-notes.txt` are data → ignored. An **unknown** head
  with `linode-cli` behind it → **ask**, because whether it executes what follows
  is unknown.
- **Flags resolve like argparse**: the full name matches first, then an
  unambiguous prefix. So `--domain` is the real field of `domains create` (not an
  abbreviation of `--domains`), while `--tag`, `--ta`, `--root_pas`, `--linode_i`
  are still recognised. Nested fields take their last component: `--devices.linodes`,
  `--interfaces.vpc_id`, `--placement_group.id` all point at a second resource and
  are checked like the primary id.
- The working directory comes from the payload's `cwd` field (where the Bash tool
  actually runs), and a `cd` inside the command moves it for later segments —
  `.linode/project.json` is searched from there, not from where Claude Code was
  launched.
- The hook knows which global flags take **no** value (`--json`,
  `--suppress-warnings`, `--pretty`, …), so `linodes reboot --suppress-warnings 123`
  still sees id `123`, and `volumes --format nodebalancers delete 555` does not
  mistake `nodebalancers` for the action. Unknown flags are assumed to take a
  value — erring toward a false refusal, never toward a miss.
- **Ids are positional**: the first non-flag token after the invocation is the
  group, the next is the action, the rest are positionals. For nested resources
  (`domains records-update <domainID> <recordID>`) the **first** id is the owner.
- LKE worker nodes have labels of the form `lke<clusterID>-…`; when a node carries
  no tags of its own, the hook uses the cluster's.
- Tag lookups are cached for 60 seconds under `~/.cache/lingate` (change with
  `LINGATE_TTL`). `lingate adopt` clears the cache of the resource it just changed.
- **Destructive actions bypass the cache.** `delete`, `rebuild`, `resize`,
  `recycle`, `restore`, `revoke`… always re-ask the API. A cached answer is a bet
  that nothing changed in the last minute; for these the bet is not worth taking.
- Beyond the primary id, the hook checks every **second resource** a command
  names: `--linode_id`, `--linodes`, `--firewall_id(s)`, `--volume_id`, `--vpc_id`,
  `--devices.linodes`, `--interfaces.vpc_id`, `--placement_group.id`, and the
  `--id`/`--type` pair of `firewalls device-create`. Attaching the project's volume
  to another project's Linode is a write to their resource too. A value that
  cannot be read (`$ID`, a JSON list) → refuse, not skip.
- **Sinks are per segment.** For a credential read, stdout must end in a file
  (`> …`) or in `opgate` at the end of the pipeline; `2>/dev/null`, `< file`, or a
  pipe into a command that still prints do **not** count. For a ledger create the
  rule inverts: stdout must **not** go to a file or a pipe, and the command must be
  **alone** in the Bash call — the recording hook reads the id from the whole call's
  stdout.
- `ask` does not end the review: the hook walks every segment, and a `deny` in a
  later segment beats an `ask` in an earlier one. Confirming one command never
  releases another that was not checked.

## When refused

A refusal always comes with the correct command. Three cases call for stopping and
asking the user instead of handling it yourself:

- **"belongs to another project"** — that is the answer "no". Do not look for a
  way around.
- **"carries no tags"** — this needs a decision about ownership, not a command.
  Ask, then `lingate adopt`.
- **"CROSS-ENV"** — the hook does not guess intent between two environments.
  Confirm the user really means the other env, then add the `LINODE_ENV=` prefix.

## Disabling the guard

`LINGATE_GUARD=off`. That is a decision for a person, not for the agent — if you
are reaching for it to get around a refusal, the refusal was right.
