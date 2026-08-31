# `op://` secret references and the `.env.op` file

## Syntax

```
op://<vault>/<item>/<field>
op://<vault>/<item>/<section>/<field>
```

This repo's convention: `op://Dev/<project-name>/<VARIABLE_NAME>` — no sections,
because another level only adds somewhere to make a typo without changing anything.

Vault, item and field accept either a name or an ID. Names read better, but renaming
an item in 1Password breaks every reference to it; IDs are durable and unreadable.
Use names, and do not rename items.

If a name contains a space, wrap the reference in double quotes. Better still, do not
put spaces in item names.

## `.env.op`

```
# safe to commit — references only, no values
DATABASE_URL=op://Dev/cme-api/DATABASE_URL
JWT_SECRET=op://Dev/cme-api/JWT_SECRET

# non-secret values can sit here directly
NODE_ENV=development
PORT=3000
```

`opgate list` warns when a line holds a literal value that looks like a secret. That
is the most common mistake when moving over, and it turns a file that is supposed to
be committable into a leak.

`opgate` looks for `.env.op` in the current directory, then at the git repository
root. To use a different file, pass `-f` or set `OPGATE_ENV_FILE`.

The `opgate` parser was measured against `op run` 2.34.1 (see `test-parser.sh`)
rather than written from a "dotenv spec", because the only thing that matters is
agreeing with `op`. If the parser missed a line that `op run` still resolves, the
Touch ID sheet would **under-report** the scope you are approving. What was measured:

- whitespace around `=` is accepted; a name may start with a digit
- `export` is stripped even with no space after it (`exportHIDDEN=1` → `HIDDEN`),
  with a warning
- unquoted: `#` starts a comment
- single quotes: taken absolutely literally, and may span lines
- double quotes: only `\n`, `\"` and `\\` are decoded; `\t` stays as **two**
  characters
- `$VAR` / `${VAR}` outside single quotes: `op` expands it → `opgate` **refuses**
  (see above)
- BOM, unclosed quote, NUL: `op` rejects the whole file → `opgate` rejects it too
- duplicate names: the last value wins, and the sheet shows the name once

## Common errors

**`could not resolve item`** — wrong vault, item or field name, or the item lives in a
different vault. Check with `op item list --vault Dev`.

**`authorization timeout`** — the 1Password authorization session expired. Unlock the
1Password app and run it again.

**An empty variable in the child process** — the reference is right but the field does
not exist on the item. 1Password returns an empty string rather than an error. Check
with `op item get <item> --vault Dev --format json | jq -r '.fields[].label'` (which
prints field **labels** only, never values).

**A variable not expanding inside the command you passed to `opgate run`** —
`opgate run -- echo $FOO` expands `$FOO` in the _outer_ shell, before the secret
exists. Wrap it in a subshell: `opgate run -- sh -c 'echo "$FOO"'`. Note that
1Password will mask the value in the output.

**The value appears as `<concealed by 1Password>`** — that is masking working
correctly, not a bug. The child process receives the real value; only the output is
concealed. Do not reach for `--no-masking` to "fix" it.

## Several environments

One item per environment, named explicitly:

```
.env.op          -> op://Dev/cme-api/…
.env.staging.op  -> op://Dev/cme-api-staging/…
```

```bash
opgate run -f .env.staging.op -- npm run migrate
```

Production secrets should not be within reach of an agent on a dev machine. If CI
needs them, use a 1Password service account scoped to exactly one vault — a service
account has no Touch ID, so do not use one on a personal machine.
