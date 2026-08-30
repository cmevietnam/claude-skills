# linode-cli recipes

The reference is still `linode-cli <group> <action> --help`. These are the things
used most, and the traps actually hit.

Every example assumes project `cme`, env `staging`. Change the tags to match
`lingate whoami`.

## The account through the project lens

```bash
linode-cli linodes list --tags cme --json | jq -r '.[] | "\(.id)\t\(.label)\t\(.status)"'
linode-cli linodes list --tags cme --text --no-headers --format 'id,label,tags'
lingate ls                                   # includes the ledger-backed types
```

Filtering runs server-side, so it is cheap. Conditions combine:
`--tags cme --region sg-sin-2`.

## Compute

```bash
# create — the two tags always travel together
linode-cli linodes create --tags cme --tags staging \
  --label cme-web-1 --region sg-sin-2 --type g6-standard-1 --image linode/ubuntu26.04

# change type (stops the machine; not immediately reversible)
linode-cli linodes resize 12345 --type g6-standard-2

# reinstall from an image — wipes the disk
opgate exec ROOT_PASS=op://Dev/cme/LINODE_ROOT_PASS -- \
  linode-cli linodes rebuild 12345 --image linode/ubuntu26.04 --root_pass "$ROOT_PASS"

linode-cli linodes ips-list 12345 --json | jq -r '.ipv4.public[].address'
```

## Volumes, DNS, firewalls

```bash
linode-cli volumes create --tags cme --tags staging --label cme-data --size 20 --region sg-sin-2
linode-cli volumes attach 555 --linode_id 12345      # the hook checks BOTH ends

linode-cli domains create --tags cme --tags staging --domain cme.example --type master --soa_email a@b.c
linode-cli domains records-create 22000001 --type A --name api --target 1.2.3.4 --ttl_sec 300

linode-cli firewalls create --tags cme --tags staging --label cme-fw \
  --rules.inbound_policy DROP --rules.outbound_policy ACCEPT
linode-cli firewalls device-create 999 --id 12345 --type linode
```

`domains records-create 22000001 …` — the first id is the parent domain, and
ownership is inherited from it; the record itself carries no tags.

## LKE

```bash
linode-cli lke cluster-create --tags cme --tags staging \
  --label cme-k8s --region sg-sin-2 --k8s_version 1.35 \
  --node_pools.type g6-standard-1 --node_pools.count 2

linode-cli lke pools-list 580172 --json | jq -r '.[] | "\(.id)\t\(.count)\t\(.type)"'
linode-cli lke pool-update 580172 848275 --count 3
```

Worker nodes (`lke580172-…`) carry no tags of their own; to know whose they are,
look at the cluster. Do not tag them by hand — one recycle and the tag is gone.

## Types that cannot carry tags

```bash
linode-cli vpcs create --label cme-vpc --region sg-sin-2 --json      # --json is mandatory
linode-cli databases mysql-create --label cme-db --region sg-sin-2 \
  --engine mysql/8 --type g6-nanode-1 --cluster_size 1 --json
```

`--json` lets the `PostToolUse` hook read the id and write `.linode/owned.json`.
Run the create **alone** — no `&&` with another command, no stdout redirect —
because the hook reads the id from the whole call's stdout. If it reports that it
could not read the id, record it by hand: `lingate own <group> <id> --env <env>`.

## Following background work

Resize, rebuild and migrate are asynchronous. Their state lives in `events`:

```bash
linode-cli events list --json | jq -r '.[:5][] | "\(.action)\t\(.status)\t\(.entity.label // "")"'
linode-cli linodes view 12345 --text --no-headers --format 'status'
```

## Common traps

- **`update --tags` is a PUT** that replaces the whole tag array; it does not
  append. To add a tag use `lingate adopt`, never a hand-written update.
- **The default table truncates** and hides columns. Use `--json`, or
  `--no-truncation` with `--all-columns`.
- **The API-version mismatch warning** prints on every command
  (`The API responded with version …`). It is stderr; `--suppress-warnings` when
  scripting.
- **Pagination**: `list` returns one page by default. `--all-rows` for everything.
- **`--raw-body`** for endpoints the CLI has no flags for yet; POST/PUT only.
- **`images`** mixes Linode's public images with private ones; filter with
  `--is_public false` or `--tags cme`.
