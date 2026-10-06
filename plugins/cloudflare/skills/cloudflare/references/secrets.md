# Credentials: tokens, Worker secrets, tunnel tokens

Anything typed on a command line lands in three places at once: the
conversation transcript (and the model provider), the shell history, and the
process table. Anything printed to stdout lands in the transcript. Once there,
the value must be rotated. Every pattern below keeps values off both paths.

The examples use `opgate` from the onepassword plugin; any tool that reads the
value into a variable without printing it works the same way.

## API token for curl and wrangler

```bash
opgate exec CLOUDFLARE_API_TOKEN=op://Dev/cme/CLOUDFLARE_API_TOKEN -- \
  sh -c 'curl -sS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
    https://api.cloudflare.com/client/v4/zones/<zone id>/dns_records'
```

`$CLOUDFLARE_API_TOKEN` is expanded by the inner shell, so the guard sees a
variable, not a value. Scope API tokens to the project's zones and to the
permissions the task needs (`Zone.DNS:Edit` on two zones, not `All zones`): a
token is the one boundary Cloudflare itself enforces.

wrangler's own OAuth login can stand in for read-only calls:

```bash
curl -sS -H "Authorization: Bearer $(wrangler auth token --json | jq -r .token)" \
  https://api.cloudflare.com/client/v4/zones
```

The token stays inside the substitution. `wrangler auth token` on its own, or
`echo $(wrangler auth token)`, prints it: the guard asks first.

## Worker secrets

`wrangler secret put NAME` reads the value from standard input. Feed it from
where the value lives:

```bash
# from 1Password
opgate exec V=op://Dev/cme/GCS_HMAC_SECRET -- \
  sh -c 'printf %s "$V" | wrangler secret put GCS_HMAC_SECRET -c wrangler.staging.jsonc'

# from a git-ignored file
printf '%s' "$(sed -n 's/^secret: //p' ~/cme-gcs-keys/cme-cdn-reader-staging.hmac.txt)" \
  | wrangler secret put GCS_HMAC_SECRET -c wrangler.staging.jsonc

# generated, never displayed
printf '%s' "$(openssl rand -hex 32)" | wrangler secret put DIAG_HMAC_SECRET -c wrangler.staging.jsonc
```

`printf '%s'` rather than `echo`: a pipeline from `echo` appends a newline, and
the newline becomes part of the secret (a signature that never matches).

Refused: `echo hunter2 | ...`, `printf '%s' hunter2 | ...`, `<<< hunter2`, a
heredoc, and `secret put` with nothing on stdin (wrangler would prompt and hang,
or store an empty value). `secret bulk <file>` with a JSON or `.env` file is fine.

Check by name, never by value: `wrangler secret list -c <config>` prints names only.

## Credentials in wrangler options

`hyperdrive create --connection-string`, `--origin-password`,
`secrets-store secret create --value`, `pipelines sinks create
--secret-access-key`... take the value as an option. Pass a variable:

```bash
opgate exec DB_URL=op://Dev/cme/HYPERDRIVE_URL -- \
  sh -c 'wrangler hyperdrive create cme-db --connection-string "$DB_URL"'
```

## Tunnel tokens

`cloudflared tunnel token <name>` prints the token that runs the tunnel. Send it
straight to 1Password:

```bash
cloudflared tunnel token cme-api | opgate put cme TUNNEL_TOKEN
opgate exec TUNNEL_TOKEN=op://Dev/cme/TUNNEL_TOKEN -- cloudflared tunnel run
```

cloudflared reads `TUNNEL_TOKEN` from the environment, so `--token` is never
needed. `cloudflared service install <token>` puts the token in the process
table and needs root: leave it to the user.

## The origin certificate

`~/.cloudflared/cert.pem` contains an API token next to the zone and account ids.
Never `cat` it or decode it in full. `cfgate doctor` reports which zone it is for
without printing anything else.

## If a value leaked

Say so at once, name the credential and what it can reach, then rotate in an
order that keeps things running: issue the new value, switch every consumer,
verify, and only then revoke the old one.
