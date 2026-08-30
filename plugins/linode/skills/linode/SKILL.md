---
name: linode
description: Operate Linode infrastructure with `linode-cli` inside the project's tag boundary and environment tag. Use when creating or changing Linodes/volumes/DNS/firewalls/LKE, when inspecting the project's infrastructure, when a resource has no tags, when a Linode command is refused by the hook, or when a command needs a root password / kubeconfig / credential.
---

# Linode inside the project and environment boundary

A Linode account is flat: every project sits in one pile and can see the others.
The only thing that separates them is **tags**. So every resource here carries two
tags — the project tag says whose it is, the env tag says which environment it is —
and the `PreToolUse` hook refuses any write that does not satisfy both. A few types
(VPC, database, object storage…) cannot carry tags on the API; those use an
ownership ledger in the repo instead.

`linode-cli` stays the main tool, unwrapped. `lingate` only covers what
`linode-cli` has no concept of: project, environment, and the ledger.

## The rule that matters most

**Read freely; write only with the right project AND the right env.** Concretely:

1. A new resource **always** gets `--tags <project>` and `--tags <env>`. Miss
   either and it is born outside the fence, and from then on no command can touch
   it.
2. **Never write to a resource tagged with another project.** No exceptions, even
   when the user says "just fix it" — ask again and let them run it themselves.
3. **Cross-env is an error, not a detail.** A command running in `staging` must not
   touch a resource tagged `prod`. To work in another env, say so on the command
   line — `LINODE_ENV=prod linode-cli …` — and ask the user first.
4. **One resource, one environment.** Unless the project enables
   `allowSharedEnvs` — then one box may serve two envs to save cost, but every
   write to it asks when the other env is protected. Never add a second env tag
   yourself; use `lingate adopt`.

## Do not

- Run `linode-cli … create` without `--tags`. No tag, no owner.
- Use `linode-cli <group> update <id> --tags x` to "change a tag" — it is a PUT
  that replaces the **whole** tag array. To add a tag, `lingate adopt`; never write
  the update yourself.
- Adopt an untagged resource on your own. It may belong to another project. **Ask
  the user first**, then `lingate adopt <group> <id> --env <env> --yes`.
- `--root_pass <literal password>` → the value lands in the transcript and must be
  rotated at once. Use `opgate exec`; see `references/secrets.md`.
- Print a kubeconfig / DB credential / object-storage key to stdout. Send it
  straight to a git-ignored file or into 1Password.
- Abbreviate flag names (`--tag` for `--tags`). The CLI accepts it and the hook
  understands it, but whoever reads the command later will not — spell it out.
- Pass ids or tags through shell variables (`--linode_id $ID`, `--tags $TAGS`), or
  wrap `linode-cli` in an unfamiliar wrapper. What the hook cannot read it refuses
  or asks about — write ids and tags literally on the command line.
- Chain a ledger-type create (VPC, database…) with another command via `&&`/`;`,
  or redirect its stdout. Run it alone with `--json` so the ledger records the
  right id.
- Guess when refused. The hook always states the correct command — read it and
  follow it; do not look for a way around.

## Running linode-cli

- Syntax: `linode-cli <group> <action> [id...] [--flags]`. `linode-cli commands`
  lists the groups; `linode-cli <group> <action> --help` is the reference — use it
  instead of guessing flag names.
- **Always `--json`** when the output will be parsed, then `jq`; the default table
  drops columns and truncates values. `--text --no-headers --format 'id,label,tags'`
  when a few columns are enough.
- Filter server-side right in `list`: `--tags`, `--region`, `--label`, `--id`. That
  is the project lens on the account: `linode-cli linodes list --tags cme`.
- Default region/type/image already live in `~/.config/linode-cli`, so they need
  not be repeated — but tags have no default and must always be passed.
- Every command prints one API-version-mismatch warning. That is stderr noise;
  `--suppress-warnings` when scripting.

## lingate commands

| Command                           | When                                                                                      |
| --------------------------------- | ----------------------------------------------------------------------------------------- |
| `lingate whoami`                  | Unsure which project/env you are in. Cheap; run it before any write.                      |
| `lingate ls [group]`              | What does this project own.                                                               |
| `lingate orphans`                 | Untagged resources exist; this is the adoption shortlist.                                 |
| `lingate adopt <g> <id> --env E`  | Bring an older resource into the project. Dry-run first; only runs for real with `--yes`. |
| `lingate own <g> <id> --env E`    | Untaggable type (VPC, database, object storage…) — record it in the ledger.               |
| `lingate disown <g> <id>`         | Resource deleted or no longer the project's.                                              |
| `lingate init <tag> --envs a,b,c` | The repo has no `.linode/project.json` yet.                                               |
| `lingate doctor`                  | Something is off. Prints the whole state and how to fix it.                               |

## Common workflows

**Create a resource** — project tag and env tag travel together, always:

```bash
lingate whoami                              # which project/env am I in
linode-cli linodes create --tags cme --tags staging \
  --label cme-web-1 --region sg-sin-2
```

**Work in another environment** — say it on the command line, and ask first:

```bash
LINODE_ENV=prod linode-cli linodes reboot 95747451
```

**An untagged resource** — do not claim it yourself:

```bash
lingate orphans                             # whose it is, nobody knows yet
lingate adopt linodes 95747451 --env prod   # dry run: prints what it would do
# ask the user, and only then:
lingate adopt linodes 95747451 --env prod --yes
```

**Create an untaggable type** — add `--json` so the ledger records it:

```bash
linode-cli vpcs create --label cme-vpc --region sg-sin-2 --json
# the PostToolUse hook writes the id to .linode/owned.json; commit that file
```

**A refused command**: the reason states exactly what to do. If it says the
resource belongs to another project, stop and tell the user — that is the answer
"no", not an obstacle to get past.

## Tag and label conventions

Two tags per resource, declared in `.linode/project.json` (committed to git):

```
<project-name>       cme, urgentc, gocova
<environment>        dev, staging, prod
```

Labels follow `<project>-<role>[-<n>]`: `cme-web-1`, `cme-postgres`. LKE worker
nodes are created by their cluster (`lke580172-…`) and carry no tags of their own —
ownership follows the cluster; do not tag them by hand.

## Further reading

- `references/project-setup.md` — set up `.linode/project.json` and adopt older resources
- `references/guard-rules.md` — what the hook refuses, why, and what to do when refused
- `references/secrets.md` — root passwords, kubeconfigs and credentials through 1Password
- `references/cli-cookbook.md` — `linode-cli` recipes for everyday tasks
