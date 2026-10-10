---
name: cloudflare
description: Operate Cloudflare with `wrangler`, the new `cf` CLI, `cloudflared` and the REST API (curl) inside the project's account, zones and name prefixes. Use when deploying or deleting Workers or Pages, managing R2/KV/D1/Queues/Hyperdrive, setting Worker secrets, creating or routing Cloudflare Tunnels, changing DNS records or purging cache, when a wrangler/cf/cloudflared/curl command is refused by the cfgate hook, or when a Cloudflare token or tunnel token is involved.
---

# Cloudflare inside the project boundary

A Cloudflare account is flat: every project's Workers, buckets, queues, tunnels
and zones sit side by side, and any login can reach all of them. Nothing in
Cloudflare says which project owns what. The repo says it instead, in
`.cloudflare/project.json`:

- `accountId`: the account every write must be pinned to
- `zones`: the zones (name to id) whose hostnames are this project's
- `prefixes`: the name prefix of every Worker, bucket, queue, database, tunnel...
- `protected`: globs over names, hostnames and zones; a matching write asks first

A `PreToolUse` hook (`cfgate`) refuses any wrangler, cf, cloudflared or API write that
leaves that boundary, and refuses or asks about any credential that would land in
the transcript. It never calls the network: it decides from the command text, the
repo's files and the local cloudflared certificate.

## The rules that matter most

1. **Read freely; write only inside the boundary.** Never write to a resource
   whose name lacks the project prefix, or to a hostname outside the project's
   zones, even when the user says "just fix it". Another project's resource
   is the answer "no". Tell the user and let them run it themselves.
2. **Pin the account.** Every wrangler write needs `account_id` in its wrangler
   config (commit it once) or `CLOUDFLARE_ACCOUNT_ID=<id>` on the command line.
   `cf` ignores the wrangler config: it needs `CLOUDFLARE_ACCOUNT_ID` or a literal
   `accountId` in `cloudflare.config.ts`. Without a pin, both use whichever
   account the login reaches first.
3. **Credentials never touch the command line or stdout.** No literal token in
   `CLOUDFLARE_API_TOKEN=...`, `-H "Authorization: Bearer ..."`, `--token`,
   `--value`, `--connection-string`. No `echo secret | wrangler secret put`.
   Values come from `opgate` or a git-ignored file; see `references/secrets.md`.
4. **The cloudflared certificate decides the zone.** `cert.pem` is issued for
   ONE zone, and tunnel DNS writes happen inside it. Pass `--origincert` with the
   cert for the hostname's zone.

## Do not

- `npx wrangler`, `bunx wrangler`, `pnpm dlx wrangler` for a write: from a
  directory with no local install they download whatever wrangler is latest. Use
  the project's binary by path (`./node_modules/.bin/wrangler`) or the global
  `wrangler`.
- Hide the command: `$WR deploy`, `find -exec wrangler`, `cat script | sh`. The
  hook asks about what it cannot read; write the command out so it can check it.
- Pass names, ids or config paths through shell variables (`--name $W`,
  `-c $CFG`, `/zones/$ZONE/...`). What the hook cannot read it refuses: write
  them literally.
- Use `--namespace-id` for KV. Use `--binding` from the project's config.
- Run `cloudflared tunnel --url ...` (a quick tunnel puts a local port on a public
  random hostname) or `--overwrite-dns` without the user asking.
- Guess around a refusal. The reason states the fix; follow it, or stop and ask.

## Working with the tools

- **wrangler** writes need the wrangler config: run from its directory or pass
  `-c <file>`. `kv`, `r2 object` and `d1 execute`/`migrations apply` act on
  LOCAL state unless `--remote` is given; say `--remote` only when you mean it.
- **Dry runs first**: `wrangler deploy --dry-run`, `wrangler delete --dry-run`
  never reach the account.
- **cf** (Cloudflare CLI, beta) maps each command to one API request; the hook
  checks that request. Zone commands need `--zone <id or domain>`. Prefer
  `cf` over raw curl for DNS, cache and zone settings. `cf deploy` reads
  `cloudflare.config.ts`, which the hook cannot evaluate: run
  `cf deploy --dry-run` first, and the hook asks before the real one.
  See `references/cf-cookbook.md`.
- **API calls**: curl with `-H "Authorization: Bearer $CLOUDFLARE_API_TOKEN"`,
  the variable filled by `opgate exec` or `opgate run`. Address zones by id (`cfgate whoami`
  lists them). Prefer wrangler for Workers/R2/KV/D1; use the API for DNS,
  cache purge and zone settings, which wrangler does not cover.
- Before any write you are unsure about: `cfgate check '<command>'` prints what
  the hook would decide and why, without running anything.

## cfgate commands

| Command                     | When                                                                |
| --------------------------- | ------------------------------------------------------------------- |
| `cfgate whoami`             | Which project, account and zones apply here; which wrangler config. |
| `cfgate check '<cmd>'`      | Before a write: the hook's verdict and reason, nothing runs.        |
| `cfgate doctor`             | A write was refused unexpectedly, or a new repo: lists every gap.   |
| `cfgate zones`              | Zone names and ids of the account, to fill `zones`.                 |
| `cfgate init --project ...` | The repo has no `.cloudflare/project.json` yet.                     |

## Further reading

- `references/project-setup.md`: write `.cloudflare/project.json`, pin configs, certs per zone
- `references/guard-rules.md`: every rule the hook enforces, why, and what it cannot see
- `references/secrets.md`: Worker secrets, API tokens and tunnel tokens through 1Password
- `references/wrangler-cookbook.md`: Workers, R2, KV, D1, Queues, Pages recipes
- `references/tunnel-cookbook.md`: cloudflared tunnels, DNS routes, certificates per zone
- `references/cf-cookbook.md`: the `cf` CLI: DNS, R2, queues, deploys, and how the hook reads it
- `references/api-cookbook.md`: DNS records, cache purge, zone settings with curl
