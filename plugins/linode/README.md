# linode

Work with Linode inside the project's tag boundary: resources are created with the
project tag, and writes to another project's resources are refused.

A Linode account is flat — every project shares one space. This plugin rebuilds the
boundary the API does not have, along two tag axes: **project** (whose) and **env**
(which environment). `linode-cli` stays the main tool; `lingate` only covers what
`linode-cli` has no concept of.

## Install

```bash
claude plugin install linode@hieuvo-skills
```

Then, once per repo:

```bash
lingate init cme --region sg-sin-2 --envs dev,staging,prod --protect prod
lingate orphans        # older resources with no tags
lingate doctor
```

Needs a `configure`d `linode-cli`. Nothing else — the hooks and `lingate` use only
bash, awk and `linode-cli` itself. `perl` (shipped with macOS) sets the deadline on
API calls, and `jq` is used when present but not required.

## The boundary

The `PreToolUse(Bash)` hook inspects every `linode-cli` command and **fails
closed**: an API error, an unknown id, an unclassified action, or the hook itself
breaking halfway all end in a refusal. The one exception is out of its reach — if
the whole hook exceeds the `timeout` in `hooks.json`, Claude Code discards the
decision and the command proceeds; so every API call in one hook run shares a
budget (`LINGATE_BUDGET`, default 11 s, each call capped at `LINGATE_DEADLINE`
8 s) so a "refuse" can still be answered in time. Details:
`skills/linode/references/guard-rules.md`.

- Reads (`list`, `view`, …) — always pass.
- Creates — `--tags <project>` and `--tags <env>` are mandatory.
- Writes to another project's resource — refused, no exceptions.
- Writes to an untagged resource — refused, pointing at `lingate adopt`.
- Writes to a resource in another environment — refused (CROSS-ENV).
- Resources serving several environments — refused, unless the project enables
  `allowSharedEnvs`; then allowed, but **always asks** when one of the other
  environments is protected.
- Writes in `protectedEnvs` — ask the user.
- Editing or deleting the boundary tags themselves (`tags create/delete`) — refuse
  or ask.
- `--help` and local help topics — always pass; they never reach the API.
- Credentials on stdout (`kubeconfig-view`, `*-creds-view`, a literal
  `--root_pass`) — ask or refuse, pointing at the `onepassword` skill.

Full rule table: `skills/linode/references/guard-rules.md`.

It stops the ordinary mistake, it is not a sandbox — an agent that wants to evade
it can. Its value is stopping the _likely_ mistake before it becomes an incident.

## Where ownership lives

| Type                                                                     | Source of truth                  |
| ------------------------------------------------------------------------ | -------------------------------- |
| `linodes` `volumes` `nodebalancers` `domains` `lke` `firewalls` `images` | the `tags` field on the API      |
| `databases` `vpcs` `object-storage` `placement` `stackscripts` `sshkeys` | `.linode/owned.json` in the repo |

The second group has no `tags` field on the Linode API, so the id is recorded at
creation time by the `PostToolUse` hook (which is why creates in this group
require `--json`).

Both `.linode/project.json` and `.linode/owned.json` are **committed to git**.

## Configuration

`.linode/project.json`:

```json
{
  "tag": "cme",
  "labelPrefix": "cme-",
  "defaultRegion": "sg-sin-2",
  "envs": ["dev", "staging", "prod"],
  "defaultEnv": "dev",
  "protectedEnvs": ["prod"],
  "allowSharedEnvs": false
}
```

Omit `envs` (`lingate init --no-envs`) to disable the cross-env guard entirely.

`allowSharedEnvs` (`lingate init --shared-envs`) lets one resource serve several
environments — legitimate when consolidating on purpose to save cost, but every
write to it must be confirmed when the other environment is protected.
`lingate doctor` lists them as technical debt: the target state is still one
resource, one environment.

Environment variables:

| Variable           | Default      | Purpose                                                                                                                     |
| ------------------ | ------------ | --------------------------------------------------------------------------------------------------------------------------- |
| `LINODE_ENV`       | `defaultEnv` | The command's environment. A prefix on the command line (`LINODE_ENV=prod linode-cli …`) is the only form the hook can see. |
| `LINGATE_TTL`      | `60`         | Seconds a tag lookup is cached under `~/.cache/lingate`. Destructive actions always bypass the cache.                       |
| `LINGATE_GUARD`    | `on`         | `off` disables the guard. A decision for a person, not for the agent.                                                       |
| `LINGATE_DEADLINE` | `8`          | Maximum seconds for **one** tag lookup.                                                                                     |
| `LINGATE_BUDGET`   | `11`         | Maximum seconds for **all** API calls of one hook run — must stay below the 15 s `timeout` in `hooks.json`.                 |

## Tests

```bash
bash plugins/linode/scripts/test-guard.sh
```

170 assertions, fully offline: a stub `linode-cli` at the front of `PATH` answers
every ownership lookup from a fixed table, so no account, token or network is
needed. Every hole ever found has an assertion holding its place.
