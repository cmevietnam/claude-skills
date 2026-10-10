# cf (the Cloudflare CLI) recipes

`cf` is Cloudflare's unified CLI, in beta since 2026-09-28 (`npm install --global cf`,
then `cf auth login` in a terminal). More than 2,900 commands cover the public API,
and `cf init/dev/build/deploy` replace wrangler for projects that use
`cloudflare.config.ts`. Commands and configuration can change before the stable
release.

## How the hook reads cf

Almost every `cf` command sends one API request. `scripts/lib/cf-commands.tsv`,
generated from cf's own manifest (`node_modules/cf/dist/_meta/commands.json`),
records it: `cf dns records create` is `POST /zones/{zone_id}/dns_records`. The
hook fills that template from the command line and checks the result like a
curl call:

- `{account_id}` is the account cf will use, which must be the project's: from
  `CLOUDFLARE_ACCOUNT_ID`, a literal `accountId` in the nearest
  `cloudflare.config.ts`, or the account cf saved for the directory
  (`.cloudflare/cache/cloudflare-account.json` or
  `node_modules/.cache/cloudflare/`). cf does **not** read a wrangler config's
  `account_id`.
- `{zone_id}` comes from `--zone`/`-z` or `CLOUDFLARE_ZONE_ID`, as an id or a
  domain name, and must be a project zone.
- Every other `{param}` comes from the positional or option of the same name,
  and a name in it (bucket, Worker, queue...) must carry the project prefix.
- An account-level create names its resource in an option (`--name`,
  `--title`, `--queue-name`...); that name is checked too. When the name is only
  in `--body`, the hook asks. Inside a zone (DNS records, rules) the zone is the
  boundary.
- GET commands and `--dry-run` pass. `{account_or_zone}` commands (rulesets,
  subscriptions) ask: cf decides at run time whether they hit the account or a
  zone.
- Put the command path first: `cf r2 buckets delete x -q`, not `cf -x ... r2`.
  Only cf's global options may come before it. Write a dry run as bare
  `--dry-run`: `--dry-run=1` and `--dry-run=TRUE` are real runs in cf.
- `-m <mode>` makes cf load `.env.<mode>` and `.env.<mode>.local` too; an account
  set there is checked like `.env`.
- On a write, spell options as `cf <cmd> --help` lists them and give each
  positional once: an option the command does not declare, or an extra
  positional, is refused (cf would reject it anyway). A custom domain's hostname
  and any `--zone-id`/`--zones` must be the project's.

When cf is upgraded, regenerate the table, or new commands are refused:

```bash
npm install --prefix /tmp/cfmeta cf@<version>
python3 plugins/cloudflare/scripts/gen-cf-table.py /tmp/cfmeta/node_modules/cf
bash plugins/cloudflare/scripts/test-guard.sh
```

## Find a command

```bash
cf cli search "create a DNS record"      # describe the action; no names, ids or domains
cf dns records create --help
cf schema dns records create             # the exact API request, nothing is sent
```

## Recipes

```bash
export CLOUDFLARE_ACCOUNT_ID=<account id>    # or accountId in cloudflare.config.ts

cf zones list
cf dns records list --zone cmevietnam.dev
cf dns records create --zone cmevietnam.dev \
  --body '{"type":"CNAME","name":"cdn","content":"cme-cdn-staging.workers.dev","proxied":true}'
cf dns records delete <record id> --zone cmevietnam.dev --dry-run
cf cache purge --zone cmevietnam.dev --body '{"files":["https://cdn.cmevietnam.dev/a.css"]}'

cf r2 buckets list
cf r2 buckets create --name cme-staging-public
cf queues create --queue-name cme-cdn-telemetry-staging
cf kv namespaces create --title cme-sessions
```

## Projects

```bash
cf migrate                # wrangler config -> cloudflare.config.ts (local only)
cf build                  # local only
cf deploy --dry-run       # prints the Worker and bindings; uploads nothing
cf deploy                 # the hook asks: it cannot evaluate cloudflare.config.ts
```

Write `accountId` in `cloudflare.config.ts` as a literal string. When it is
computed (`process.env`, a ternary on `mode`), the hook cannot tell which account
a write lands in and refuses until `CLOUDFLARE_ACCOUNT_ID` pins it.

## Credentials

`cf auth login` stores an OAuth login per profile. In automation, cf reads
`CLOUDFLARE_API_TOKEN` (fill it with `opgate exec`). The hook refuses
`CLOUDFLARE_API_BASE_URL` pointing anywhere but `api.cloudflare.com`, since every
request carries the credential, and any credential option (`--secret`, `--token`,
`--password`, `workers secrets update --text`, `secrets-store secrets edit
--value`, the `--body` of a secrets command...) written literally. Pass the value
from a variable (`--text "$STRIPE_KEY"` under `opgate exec`) or a file
(`workers secrets bulk --body @secrets.json`).
