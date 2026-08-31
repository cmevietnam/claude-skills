# Moving a project onto 1Password

Once per project. `opgate scan` and `opgate import` handle the mechanical part; two
decisions stay yours and cannot be automated: which variables are genuinely secret,
and which secrets should be **rotated** rather than copied across intact. Any value
that has ever been in git, in a log, or in a settings file should be treated as
disclosed.

## 0. One-time setup for the machine

```bash
op vault create Dev          # if it does not exist yet
opgate doctor                # everything green before going further
```

## 1. See what the project has

```bash
opgate scan
```

Lists every `.env`, counts variables by classification, suggests item names — and
also reports secrets sitting inside config or source files. It reads no value out,
and works even while 1Password is locked.

## 2. Import one file at a time

```bash
opgate import api/.env
```

One Touch ID for the whole file; the sheet lists every variable about to be written.
What it does:

- creates or updates the item `<project>-<directory>-<environment>` in the `Dev`
  vault, tagged `opgate` and `project:<name>`
- writes a reference file next to the original: `.env` → `.env.op`,
  `.env.production` → `.env.production.op`. Secrets become `op://` refs; non-secret
  variables stay as literals (quoted where needed)
- **neither** deletes **nor** backs up the original. The original is still there, so
  a second plaintext copy would only widen the exposure. If you want one, pass
  `--backup` — and delete it yourself.

It stops rather than overwriting when: the item exists but was not created by opgate,
two different files derive the same item name, or the target `.op` file is being
generated from a different source. `--force` skips those checks.

For variables it is unsure about it asks you, and the question describes only the
shape of the value, never the value. With no terminal it stops rather than guessing —
`--yes` sends every ambiguous case to the vault. Only names on an exact-match
allowlist (`NODE_ENV`, `PORT`, `API_URL`…) stay literal automatically, so expect a
fair number of questions the first time.

`import` **refuses** the files that `op run` also refuses, instead of guessing: a BOM
at the start, an unclosed quote, a NUL byte. It also refuses a value containing `$VAR`
outside single quotes — `op run` expands it and the vault does not, so importing would
change what the value means. Wrap it in single quotes to keep a literal `$`.

To preview without writing anything: `opgate import api/.env --dry-run`.

For secrets that need rotating (a key that has been in git, in a settings file, in a
log): **create the new key at the provider first**, edit `.env`, and import after that.

### Adding a single variable later

```bash
opgate put cme-api NEW_TOKEN                    # hidden prompt
opgate put cme-api GOOGLE_SA_JSON --multiline < service-account.json
```

Then add the line `NEW_TOKEN=op://Dev/cme-api/NEW_TOKEN` to `.env.op`.

## 3. Check the `.env.op`

`import` already wrote this next to the original. It is safe to commit — secrets are
`op://` refs, non-secret variables stay literal:

```
NODE_ENV=development
DATABASE_URL=op://Dev/cme-api/DATABASE_URL
JWT_SECRET=op://Dev/cme-api/JWT_SECRET
```

Confirm before dropping the original:

```bash
opgate list -f api/.env.op                    # names + refs, no values
opgate run -f api/.env.op -- npm run dev      # the app has to actually run
```

`opgate list` warns if a variable with a secret-looking name is still a literal. That
is a sign of a misclassification, and it is the one thing that can turn `.env.op` from
a committable file into a leaking one.

## 4. Clean up the plaintext

`import` leaves the original alone. Once you are sure the app runs from the `.op` file:

```bash
git check-ignore .env || echo ".env" >> .gitignore
rm api/.env
```

Do not delete it early. If a variable was missed and the original is gone, there is no
way back — which is why `import` leaves the file in place rather than tidying up for
you.

If `.env` was ever committed, the values are still in git history; adding it to
`.gitignore` does not remove them. Those secrets have to be rotated.

## 5. Change how the app is started

```diff
-npm run dev
+opgate run -- npm run dev
```

In `package.json`, if you want `npm run dev` to go through the gate by itself:

```json
{ "scripts": { "dev": "opgate run -- vite", "dev:raw": "vite" } }
```

Docker Compose, and other tools that insist on a real file:

```bash
opgate inject -i .env.op -o .env.local && docker compose up
rm .env.local
```

`.env.local` has to be in `.gitignore` — `opgate inject` refuses to write otherwise.

## 6. For Codex

Codex has no hook system, so the rules have to live in the project's `AGENTS.md`:

```markdown
## Secrets

Secrets live in 1Password, not on disk. Run the app with `opgate run -- <cmd>`.
Do not open `.env`, do not call `op` directly, and never print a secret value to
stdout. `opgate list` shows which variables the project has without exposing values.
```

The Touch ID gate stops Codex exactly as it stops Claude — it sits at the CLI level,
not at the hook level.
