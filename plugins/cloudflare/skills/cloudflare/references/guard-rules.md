# What the hook enforces

`scripts/guard-cloudflare.sh` runs before every Bash call. A call that does not
mention `wrangler`, `cloudflare`, `CF_API_` or `TUNNEL_TOKEN` exits at once; the
test ignores case, quotes and line continuations, so `WRANGLER`, `wran""gler` and
`wrang\<newline>ler` are all seen. The rest is lexed like a shell would: quotes
(also `$'...'`), `&&`, pipes, `( )` subshells, `$(...)`, `$((...))`, heredocs with
quoted or unquoted delimiters, `bash -c`, `eval`, `env`, `sudo`, `timeout`,
`xargs`, `pnpm`/`yarn`, `node .../wrangler.js`, `opgate exec|run`. Each invocation
of `wrangler`, `cloudflared` or `curl` is checked on its own, and a script handed
to a shell (`bash -c '...'`, `bash <<EOF`, `echo '...' | sh`) is checked in place.
A refusal anywhere refuses the whole call; a prompt is issued only if nothing
refuses.

`cfgate check '<command>'` shows the verdict for any command without running it.

## Everywhere, project or not

| Refused                                                                                 | Why                                                                    |
| --------------------------------------------------------------------------------------- | ---------------------------------------------------------------------- |
| `CLOUDFLARE_API_TOKEN=<literal>` (also `_API_KEY`, `CF_API_TOKEN`, `TUNNEL_TOKEN`, ...) | The value is in the transcript. `op://...` references are fine.        |
| `curl -H 'Authorization: Bearer <literal>'`, `X-Auth-Key`, `--oauth2-bearer`, `-u u:p`  | Same.                                                                  |
| `--value`, `--connection-string`, `--password`, `--secret-access-key`... literal        | wrangler options whose value is a credential.                          |
| `cloudflared ... --token <literal>`, `service install <literal>`                        | A tunnel token runs the tunnel for whoever holds it.                   |
| `npx` / `bunx` / `pnpm dlx` / `npm exec` wrangler, for a write                          | May download a different wrangler. Use `./node_modules/.bin/wrangler`. |

| Asks                                                                               | Unless                                                                                                                                                                                             |
| ---------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `wrangler auth token`, `cloudflared tunnel token`, `GET .../cfd_tunnel/<id>/token` | stdout goes to a file, to `opgate put`, into `X=$(...)`, or into a quiet curl header. A pipe into a command that prints does not count; neither does `echo $(...)`, `> /dev/stderr`, or `curl -v`. |

## Writes: the boundary

Reads pass untouched, including reads of other projects' data. A write first
needs `.cloudflare/project.json`, found by walking up from the directory the
command really runs in: the Bash cwd, moved by every `cd`/`pushd` on the line
(`cd -P`, `cd --`, `command cd`, a variable assigned earlier on the line), by a
wrapper's own `-C` (`env -C`, `sudo -D`, `pnpm -C`, `yarn --cwd`) and by wrangler's
`--cwd`. A `cd` inside `( )` or in a pipeline stage moves nothing after it. A `cd`
the guard cannot follow (`cd -`, `popd`, `cd $(...)`) makes every later write on
the line refused. Then:

**Names.** Every resource a write names must start with a project prefix or be in
`names`: Worker (`--name`, the config's `name`, or `<name>-<env>` for `--env`),
R2 bucket (also `bucket/key` of `r2 object`), KV namespace, D1 database, queue
(and the Worker of `queues consumer add`), Pages project, tunnel, Vectorize index,
workflow, pipeline, Hyperdrive config... A name the shell fills in (`$NAME`) is
refused: it cannot be read.

**Account.** Every place the account of a wrangler write can come from is read:
`CLOUDFLARE_ACCOUNT_ID=` on the command, `export CLOUDFLARE_ACCOUNT_ID=` earlier
on the line, the hook's own environment, `.env`, `.env.local`, `.env.<env>`,
`.env.<env>.local` (or the `--env-file` list that replaces them) in the run and
config directories, and every `account_id` in the config. Which one wrangler uses
varies by command (Pages commands prefer the environment), so each one present
must be the project's account, and at least one must be present.

**The config.** Found the way wrangler 4.61 finds it: `-c` wins; otherwise one
upward walk per file name, `wrangler.json` first, then `wrangler.jsonc`, then
`wrangler.toml` (so a `wrangler.json` in a parent beats a `wrangler.toml` here);
a `.wrangler/deploy/config.json` redirect anywhere above replaces that with its
`configPath`; and `deploy <script>` / `versions upload <script>` search from the
script's directory. `--env` (or `CLOUDFLARE_ENV`) picks `env.<name>.name`, else
`<name>-<env>`.

**Flags.** Booleans are read the way wrangler's parser reads them:
`--dry-run false`, `--dry-run=false` and `--no-dry-run` are not dry runs, and
`--help=false` does not make a command help. `--name` given twice is refused.

**The deploy itself.** `deploy`, `versions upload` and `triggers deploy` also
check the whole config: every route pattern's host is in a project zone, every
`zone_name` / `zone_id` is the project's, and every bound bucket, queue,
dead-letter queue, D1 database, service and Durable Object script is in the
project, and so are Vectorize indexes, workflow names, Analytics Engine
datasets, dispatch namespaces and pipelines. A Worker bound to another project's
bucket can write to it. `--route`, `--routes`, `--domain` (each one, when given
several times) and `--dispatch-namespace` are checked the same way.

**Hostnames.** Route patterns, `--domain` (custom domains, R2 domains) and
`cloudflared tunnel route dns|lb` hostnames must be in a project zone.

**Tunnels.** The origin certificate cloudflared will use is found by cloudflared's
own order (`--origincert`, `TUNNEL_ORIGIN_CERT`, `origincert:` in the config,
`~/.cloudflared/cert.pem`...). Its account must be the project's, its zone must be
a project zone, and for `route dns` it must be the hostname's zone: cloudflared
creates the record inside the certificate's zone, so `api.a.com` with a cert for
`b.com` becomes `api.a.com.b.com`.

**API.** `curl` to `api.cloudflare.com/client/v4` with any method but GET/HEAD
(POST `graphql` is a read): `zones/<id>/...` needs a project zone id;
`accounts/<id>/...` needs the project account; `workers/scripts/<name>`,
`r2/buckets/<name>` and `pages/projects/<name>` need a project name. The method
comes from `-X`, `-d`/`--json`/`-F` (POST), `-T` (PUT) or `-I` (HEAD), as curl
decides it, per transfer (`--next` starts another one with its own method).
The host is matched in any case; `--url` and `--expand-url` count. A URL built
from variables is resolved from assignments earlier on the same command line
(`API=https://...; curl -X POST "$API/zones/<id>/..."`); a write whose URL still
contains a variable is refused, because it could point at any zone. Also refused
for writes: URL globbing (`{a,b}`, `[1-9]`), dot segments and encoded separators
(`/zones/<ours>/../<theirs>`, `%2e%2e`), and `--request-target`, which replaces
the path curl sends.

**cf (the Cloudflare CLI).** Each `cf` command is looked up in
`scripts/lib/cf-commands.tsv`, generated from cf's own manifest, which gives the
API request it sends (`cf dns records create` is
`POST /zones/{zone_id}/dns_records`). The hook fills the template and applies the
API rules above to the result. `{account_id}` is the account cf will use: every
source present (`CLOUDFLARE_ACCOUNT_ID`, a literal `accountId` in the nearest
`cloudflare.config.ts`, the account cf saved for the directory, `.env` and
`.env.local` in the run directory, plus `.env.<mode>` and `.env.<mode>.local`
under `-m/--mode <mode>`) must be the project's, and at least one must be
present; a computed `accountId` or a mode the shell supplies is refused.
`{zone_id}` comes from `--zone`/`-z` or `CLOUDFLARE_ZONE_ID` (id or
domain). Other parameters come from the positional or option of the same name;
one the hook cannot find, or one containing `/` or `..`, is refused. An
account-level create's name option (`--name`, `--title`, `--queue-name`...) must
carry the project prefix. GET commands and dry runs pass. `cf` and its alias
`cloudflare` are recognised by name in any case, also as `npx cf` (refused for
writes) and `node .../node_modules/cf/...`.

The hook reads cf's argv the way cf's yargs does. Global options (`-q`, `-z`,
`--profile`, `-m`, `--local`, `--persist-to`, `-h`, `-v`) may come before the
command path; any other option there, `--` included, is refused. After `--`
nothing is an option. `--dry-run`, `--help` and `--version` count only bare, as
`=true` or followed by `true`, and only when every occurrence on the line says so:
`--dry-run=0`, `=1`, `=TRUE` and `--help false` all run the command for real, and
are checked as such. Options that carry a secret are flagged in the table by name,
by the manifest's own description ("The secret value..."), and for `--body` of
the commands that store secrets (`workers secrets bulk|update`,
`secrets-store secrets create|edit`...); a literal value is refused even next to
`--help`. `--body @file.json` is not a literal.

**Local state.** `kv`, `r2 object`, `d1 execute` and `d1 migrations apply` without
`--remote` touch `.wrangler/state` only and pass. `deploy --dry-run` passes.

## Writes that ask

| Command                                                                                                                | Why                                                                                                                            |
| ---------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Anything matching `protected`                                                                                          | The project said a human confirms.                                                                                             |
| Id-addressed: `hyperdrive delete <id>`, tunnel by UUID, `/d1/database/<id>`...                                         | An id says nothing about who owns it.                                                                                          |
| Account-level: mTLS/CA certs, `containers push`, `tunnel route ip`, `vnet`                                             | Belongs to no project.                                                                                                         |
| `wrangler login/logout`, `cloudflared tunnel login`, `service install`, `update`                                       | Changes the tool, not a resource.                                                                                              |
| `cloudflared tunnel --url ...` (quick tunnel)                                                                          | Publishes a local port on a public random hostname.                                                                            |
| `--overwrite-dns`, `route lb`                                                                                          | Replaces live records / creates billed load balancers.                                                                         |
| `POST /zones`, a write to `/zones/<id>` itself, `/user/tokens`                                                         | Creates or deletes a zone, mints a token.                                                                                      |
| `-K/--config` on a Cloudflare curl; `wget`/`httpie`/`xh` to the API                                                    | Options the guard cannot read.                                                                                                 |
| An unknown command in front of a Cloudflare CLI (`mytool wrangler ...`, `find -exec`)                                  | It might run it.                                                                                                               |
| A command name the shell computes (`$WR ...`, `"$(command -v wrangler)" ...`) on a line that mentions a Cloudflare CLI | The guard cannot tell what runs.                                                                                               |
| A shell reading its script from a pipe or a file (`cat x \| sh`) on such a line                                        | The guard cannot see the script.                                                                                               |
| `cf deploy`, `cf workers versions create`, `cf workers triggers deploy`, `cf pages deploy`, `cf previews deploy`       | They deploy what `cloudflare.config.ts` describes, and that is code the hook cannot evaluate. Run them with `--dry-run` first. |
| `cf` writes to `{account_or_zone}` paths (rulesets, subscriptions)                                                     | cf picks the account or a zone at run time.                                                                                    |
| `cf d1 migrations apply <id>`, other id-addressed cf writes                                                            | An id says nothing about who owns it.                                                                                          |
| A command longer than 64 KB that mentions Cloudflare                                                                   | It could not be verified before the hook's time limit.                                                                         |

## Writes that are refused, not asked

Account members, roles, billing, subscriptions and `/user` profile writes; any API
path the guard cannot attribute; any wrangler, cf or cloudflared command it does not
know (the tables in `scripts/lib/wrangler.sh` and `scripts/lib/tunnel.sh` were
generated from `--help` on wrangler 4.61.0 and cloudflared 2024.11.1, and
`scripts/lib/cf-commands.tsv` from cf 1.0.0-beta.12; a newer CLI adds commands the
guard refuses until they are classified there). `CLOUDFLARE_API_BASE_URL` set to
anything but `api.cloudflare.com` on a cf command, since every request carries
the credential.

## What it cannot see

These are real limits. Each one says what makes the guard stop protecting you.

- **Anything not on the command line.** `npm run deploy`, `make deploy-web`,
  `bash deploy.sh`, a Python script calling the API: the wrangler or curl inside
  is never seen. The guard protects commands Claude types, not scripts it runs.
- **The shell's environment.** The hook runs in Claude Code's environment, not
  the Bash tool's shell. A `CLOUDFLARE_ACCOUNT_ID` exported in `~/.zshrc` reaches
  wrangler but may not reach the guard. `cfgate doctor`, which runs in the shell,
  reports it. Do not export it globally.
- **The prefix is a naming convention.** Another project that names a bucket
  `cme-...` is inside this project's boundary. Pick prefixes no other project
  shares.
- **A URL hidden in the environment.** A curl whose URL comes entirely from an
  environment variable, on a line that never says "cloudflare" in any case, does
  not reach the guard at all (the fast path skips it). Write API URLs literally.
- **Inside a zone, every record is the zone's.** A DNS write to a project zone
  passes whatever record it names; only the zone (or `protected`) can make it ask.
- **The hook timeout.** If the hook exceeds 15 s, Claude Code discards its
  decision and the command runs. The guard makes no network calls and asks
  about any command over 64 KB (`CFGATE_MAX_BYTES`) instead of lexing it, so
  this needs a machine stalled for other reasons.
- **A script file run by a shell.** `bash deploy.sh` and `sh -c "$(cat x)"` run
  text the guard never reads. Only scripts written on the command line itself
  are checked.
- **Reads are free.** `wrangler d1 export --remote`, `r2 object get` and
  `kv key get` of another project's data all pass.

## Turning it off

`CFGATE_GUARD=off` in Claude Code's environment disables the hook. For a single
command the user wants anyway, the user runs it themselves.

## Testing

```bash
bash plugins/cloudflare/scripts/test-guard.sh   # every rule, asserted by its reason text
```
