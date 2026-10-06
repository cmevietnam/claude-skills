# wrangler recipes

Run from the directory that holds the wrangler config, or pass `-c <file>`.
Use the project's binary (`./node_modules/.bin/wrangler`) or the global
`wrangler`, never `npx`. `wrangler <cmd> --help` is the reference: use it instead
of guessing option names. Add `--json` where offered when the output is parsed.

## Look before writing

```bash
wrangler whoami                       # account id, token scopes
cfgate whoami                         # project, zones, which config applies here
wrangler deployments list             # what is live, by version
wrangler versions list
wrangler secret list -c wrangler.staging.jsonc   # names only
wrangler tail cme-cdn-staging --format json      # live logs (read)
```

## Workers

```bash
wrangler deploy --dry-run --outdir /tmp/out -c wrangler.staging.jsonc   # bundle only, nothing uploaded
wrangler deploy -c wrangler.staging.jsonc
wrangler deploy --env staging                     # Worker <name>-staging unless env.staging.name is set
wrangler versions upload -c wrangler.staging.jsonc   # upload without routing traffic
wrangler versions deploy <version-id>@100% -c wrangler.staging.jsonc
wrangler rollback <version-id> -c wrangler.jsonc  # protected Workers ask first
wrangler delete --dry-run -c wrangler.staging.jsonc
```

A deploy publishes more than code: its routes, custom domains and bindings. The
guard checks all of them against the project, so a config that routes to another
project's zone, or binds another project's bucket, is refused before upload.

After a deploy, verify the new version is the one answering before running any
check that depends on it: poll a version endpoint (or `wrangler deployments
status`) until it reports the version just deployed, with a bound.

## R2

```bash
wrangler r2 bucket list
wrangler r2 bucket create cme-staging-public --location apac
wrangler r2 bucket info cme-staging-public
wrangler r2 object put cme-staging-public/path/key --file ./local.txt --remote
wrangler r2 object get cme-staging-public/path/key --file ./out.txt --remote
wrangler r2 bucket domain add cme-staging-public --domain files.cmevietnam.dev --zone-id <zone id>
wrangler r2 bucket lifecycle list cme-staging-public
```

`r2 object put/delete` without `--remote` writes to `.wrangler/state` only.

## KV

```bash
wrangler kv namespace list
wrangler kv namespace create cme-sessions
wrangler kv key list --binding SESSIONS --remote
wrangler kv key put user:1 '{"a":1}' --binding SESSIONS --remote
wrangler kv bulk put entries.json --binding SESSIONS --remote
```

Address namespaces by `--binding` from the config. `--namespace-id` is accepted
only for an id the config declares.

## D1

```bash
wrangler d1 list
wrangler d1 create cme-staging-db
wrangler d1 execute DB --command "select count(*) from users" --remote
wrangler d1 migrations create DB add_users          # local file only
wrangler d1 migrations list DB --remote
wrangler d1 migrations apply DB --remote            # a backup is taken first
wrangler d1 time-travel info DB
wrangler d1 export DB --remote --output backup.sql
```

Without `--remote`, `execute` and `migrations apply` run against the local
database. Try a migration locally first, then once with `--remote`.

## Queues

Create the dead-letter queue before a consumer names it, and both before the
first deploy that binds them: a binding to a queue that does not exist fails the
deploy.

```bash
wrangler queues create cme-cdn-telemetry-staging-dlq
wrangler queues create cme-cdn-telemetry-staging
wrangler queues consumer add cme-cdn-telemetry-staging cme-cdn-staging --batch-size 100
wrangler queues info cme-cdn-telemetry-staging
wrangler queues purge cme-cdn-telemetry-staging     # destructive
```

## Pages

```bash
wrangler pages project list
wrangler pages deploy dist --project-name cme-site --branch main
wrangler pages deployment list --project-name cme-site
cat .secrets/x | wrangler pages secret put API_KEY --project-name cme-site
```

## Hyperdrive, Vectorize, Workflows

```bash
opgate exec DB_URL=op://Dev/cme/HYPERDRIVE_URL -- sh -c 'wrangler hyperdrive create cme-db --connection-string "$DB_URL"'
wrangler vectorize create cme-docs --dimensions 768 --metric cosine
wrangler workflows list
wrangler workflows instances list cme-ingest
```

Commands that address their target by id (`hyperdrive delete <id>`,
`secrets-store secret delete`) ask the user: the id does not say whose it is.
