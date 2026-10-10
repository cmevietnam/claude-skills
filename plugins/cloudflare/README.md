# cloudflare

Work with Cloudflare through `wrangler`, the new `cf` CLI, `cloudflared` and the REST API without
touching another project's resources, and without putting a credential in the
transcript.

## The problem

A Cloudflare account is flat. One login reaches every project's Workers, R2
buckets, KV namespaces, D1 databases, queues, tunnels and zones, and nothing in
Cloudflare records which project owns which. On the account this plugin was built
for, ten zones of five projects share one account id. A `wrangler deploy` from the
wrong directory, a route pattern copied from another repo, or a
`cloudflared tunnel route dns` run with the last-used origin certificate writes
into a neighbour's resources, and nothing stops it.

## What it does

- **`.cloudflare/project.json`** (committed) declares the boundary: the account
  id, the project's zones (name to id), the name prefixes of its resources, and
  globs for what is protected (production).
- **A `PreToolUse` hook** reads every Bash call that mentions Cloudflare, lexes it
  like a shell, and checks each `wrangler`, `cf`, `cloudflared` and `curl` invocation:
  - writes must be pinned to the project's account, name resources inside the
    project's prefixes, and use hostnames inside its zones;
  - a deploy's whole config is checked too: routes, zones, and every bound
    bucket, queue, database and service;
  - tunnel writes must use an origin certificate for the hostname's zone
    (cloudflared otherwise creates `host.<cert zone>` in the wrong zone);
  - API writes must address the project's zone ids and account;
  - credentials written on the command line are refused, and commands that print
    one (`wrangler auth token`, `cloudflared tunnel token`) ask unless the output
    goes to a variable, a file or 1Password;
  - protected names and zones, id-addressed targets and account-level changes
    ask the user.

  It makes no network calls, so it cannot time out on a slow API and fall open.

- **`cfgate`** (on PATH while the plugin is enabled): `init`, `zones`, `whoami`,
  `doctor`, and `check '<command>'`, which prints the hook's verdict and reason
  without running anything.

## Install

```bash
claude plugin install cloudflare@hieuvo-skills
```

Then, in each project:

```bash
cfgate zones                                   # find the zone ids
cfgate init --project cme --account <id> --prefix cme- \
  --zone cmevietnam.dev=<zone id> --protect '*-prod' --protect cme-vietnam
cfgate doctor                                  # pins, configs, .env files, the default cert
```

Details: `skills/cloudflare/references/project-setup.md`.

## Tests

```bash
bash plugins/cloudflare/scripts/test-guard.sh
```

No account, network or token: a fake repo, fake origin certificates and a
private `HOME`. Every refusal and prompt is asserted by the words of its reason,
and every allow by the guard's own trace of what it checked.

## Limits

The hook guards commands Claude types. A script that calls wrangler inside
(`npm run deploy`, `make deploy`) is not seen; nor is an account id exported in
the shell profile, which reaches wrangler but not the hook. The full list, with
what makes each protection stop working, is in
`skills/cloudflare/references/guard-rules.md`.
