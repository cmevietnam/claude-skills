# Setting up the boundary for a project

Once per repo. After this, every write is checked automatically.

## 1. Declare the project

At the repo root:

```bash
lingate init cme --region sg-sin-2 --envs dev,staging,prod --protect prod
```

This produces `.linode/project.json`:

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

- `tag` — the hard boundary. Every write is checked against it.
- `envs` — the valid environments. Leave it out (`--no-envs`) to disable the
  cross-env guard entirely; only sensible for a single-environment project.
- `defaultEnv` — the env when the command line says nothing. Make it the **least
  dangerous** one.
- `protectedEnvs` — envs where every write needs the user's confirmation.
- `allowSharedEnvs` — lets one resource serve several environments. Enable with
  `lingate init --shared-envs` when consolidating on purpose to save cost; every
  write to a shared resource still asks when the other env is protected, and
  `lingate doctor` lists them so splitting them later is not forgotten.

**Commit the whole `.linode/` directory.** It is the team's shared contract, and
it gets reviewed in a PR — unlike an environment variable that differs per machine.

## 2. Adopt older resources

Resources created before the plugin usually carry no tags. Under this guard,
"untagged" means "belongs to no project", so every write to them is refused —
that is by design, not a bug.

```bash
lingate orphans
```

This prints the untagged resources, for example:

```
linodes        95747451     cme-postgres
lke            580172       cme-cluster
```

LKE worker nodes (`lke580172-848275-…`) do **not** appear here: the cluster creates
them, and ownership follows the cluster.

For each one, dry-run first:

```bash
lingate adopt lke 580172 --env prod
```

It only prints what it would do. **Ask the user whether the resource really
belongs to this project** — a name suggests, it does not prove — and only then run
it for real:

```bash
lingate adopt lke 580172 --env prod --yes
lingate adopt linodes 95747451 --env prod --yes
```

`adopt` **adds** tags, it does not overwrite: `linode-cli … update --tags` is a PUT
that replaces the whole array, so the real command sends every existing tag back
along with the new one. That is also why you should never write the update
yourself to attach a tag.

## 3. Types that cannot carry tags

VPC, Managed Database, Object Storage, Placement Group, StackScript and SSH key
have no `tags` field on the API. Their ownership lives in `.linode/owned.json`:

```bash
lingate own vpcs 12345 --env staging --label cme-vpc
```

When creating one, just add `--json` and the `PostToolUse` hook records it:

```bash
linode-cli vpcs create --label cme-vpc --region sg-sin-2 --json
```

This ledger must be committed too. When it drifts from reality, the guard drifts
with it — `lingate ls` to compare, `lingate disown` to clean out deleted ids.

## 4. Check

```bash
lingate doctor
```

Checks `linode-cli`, the token, the project config, the env list, the ledger, and
the guard's state. Every broken item is printed with the command that fixes it.
