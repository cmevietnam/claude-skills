# Setting up a project

## 1. Find the account and the zones

```bash
wrangler whoami          # account name and id (32 hex)
cfgate zones             # every zone on the account: name, id, account
```

`cfgate zones` uses `CLOUDFLARE_API_TOKEN` when it is set, otherwise wrangler's
own OAuth login (which has `zone:read`). The token is passed to curl on stdin and
is never printed.

## 2. Write `.cloudflare/project.json`

```bash
cfgate init --project cme \
  --account <account id> \
  --prefix cme- \
  --zone cmevietnam.org.vn=<zone id> \
  --zone cmevietnam.dev=<zone id> \
  --protect cme-vietnam --protect cme-cdn \
  --protect '*-prod' --protect '*-prod-*' \
  --protect cmevietnam.org.vn
```

It writes the file at the git root. Commit it: it is the boundary, and the
boundary is part of the code.

```json
{
  "project": "cme",
  "accountId": "0123456789abcdef0123456789abcdef",
  "zones": {
    "cmevietnam.org.vn": "11111111111111111111111111111111",
    "cmevietnam.dev": "22222222222222222222222222222222"
  },
  "prefixes": ["cme-"],
  "names": [],
  "protected": [
    "cme-vietnam",
    "cme-cdn",
    "*-prod",
    "*-prod-*",
    "cmevietnam.org.vn"
  ]
}
```

| Field       | Meaning                                                                                               |
| ----------- | ----------------------------------------------------------------------------------------------------- |
| `project`   | A name for messages.                                                                                  |
| `accountId` | Every write must be pinned to this account.                                                           |
| `zones`     | Zone name to zone id. Hostnames must fall inside one; API calls address zones by these ids.           |
| `prefixes`  | A Worker, bucket, queue, database, tunnel... is the project's when its name starts with one of these. |
| `names`     | Exact names that are the project's but do not follow the prefix (an older Worker, say).               |
| `protected` | Shell globs matched against names, hostnames and zone names. A matching write asks the user first.    |

A prefix must be at least 2 characters: an empty one matches every name on the
account, which is no boundary at all.

**Protect production by name.** There is no "environment" in Cloudflare, so the
guard cannot know which Worker is production; `protected` says it. Name prod
resources so one glob catches them (`*-prod`, `*-prod-*`) and list the
exceptions explicitly (`cme-vietnam`, the production web Worker, has no suffix).
Protecting a zone name protects every hostname in it.

## 3. Pin every wrangler config to the account

```jsonc
{
  "name": "cme-cdn-staging",
  "account_id": "<account id>",
  ...
}
```

Without it, every write from that config is refused. `cfgate doctor` lists the
configs that lack it. A pin on the command line works too
(`CLOUDFLARE_ACCOUNT_ID=<id> wrangler ...`) and is the only option for commands
run where no config exists (`wrangler r2 bucket create` from the repo root).

Every `account_id` in the file is checked, including those under `env.*`, and so
is every `CLOUDFLARE_ACCOUNT_ID` in the `.env` / `.env.<env>` files wrangler loads
for itself. A mismatch anywhere is a refusal: the file is ambiguous about where it
writes.

### The cf CLI reads its own pin

`cf` ignores the wrangler config's `account_id`. Pin it with a literal
`accountId` in `cloudflare.config.ts` (`cf migrate` writes one), or with
`CLOUDFLARE_ACCOUNT_ID` on the command line. A computed `accountId` (from
`process.env` or the mode) cannot be read by the hook, so every cf write from
that directory is refused until the command line pins the account. If cf saved
another account for the directory (`.cloudflare/cache/cloudflare-account.json`,
or under `node_modules/.cache/cloudflare/`), delete that file.

## 4. One cloudflared certificate per zone

`cloudflared tunnel login` asks which zone to authorise and writes
`~/.cloudflared/cert.pem` for that zone only. Logging in again for another zone
overwrites it. Keep one file per zone and say which one you mean:

```bash
cloudflared tunnel login                         # pick cmevietnam.dev in the browser
mv ~/.cloudflared/cert.pem ~/.cloudflared/cert.pem.cmevietnam.dev
cloudflared tunnel --origincert ~/.cloudflared/cert.pem.cmevietnam.dev route dns cme-api api.cmevietnam.dev
```

The guard reads only `accountID` and `zoneID` from the certificate (the file also
holds an API token, which it never prints) and refuses a tunnel write when the
certificate's zone is not the project's, or not the zone of the hostname.

## 5. Check

```bash
cfgate doctor        # configs, pins, .env files, routes, bindings, the default cert
cfgate whoami        # what applies in the current directory
cfgate check 'wrangler deploy -c wrangler.staging.jsonc'
```
