---
name: onepassword
description: Reach a project's secrets in 1Password through `opgate`, behind a Touch ID gate on every use. Use when you need an API key / DB URL / token to run something, when an app fails for a missing environment variable, when setting up secrets for a new project, or when you find a plaintext secret in a repo.
---

# 1Password secrets through `opgate`

A project's secrets live in 1Password, not on disk. Every time something reaches for
one, a Touch ID sheet appears on the user's machine — you cannot approve it for
them, and that is the point.

## The rule that matters most

**Never let a secret value reach stdout.** Anything printed to the terminal goes
into the conversation transcript and is shipped to the model provider. A secret
that lands there is disclosed and has to be rotated — which makes the vault
pointless.

That is why `opgate` has **no `read` command**. A secret only ever travels to three
places: the environment of a child process, the clipboard, or a git-ignored file.
(`opgate import --backup` makes one more plaintext copy — off by default, and if
you turn it on, deleting it is your job.)

## What not to do

- Calling `op read …`, `op item get …`, `op run …` directly → use `opgate` instead.
  The hook blocks it, but do not make it block you.
- `cat .env`, `grep TOKEN .env`, opening `.env` with the Read tool → the values go
  into the transcript. To learn which variables a project has, use `opgate list`.
- Printing a secret "just to check". Check inside the child process instead:
  `opgate run -- sh -c '[ -n "$JWT_SECRET" ] && echo present'`.
- Writing a secret into a file you create, a commit message, a comment, an issue.
- Adding a secret to `.claude/settings*.json` as an allow rule.

## Commands

| Command                           | Use it when                                                                                                                                  |
| --------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `opgate list`                     | You want to know which secrets a project has. **Shows no values**, needs no Touch ID — call it freely.                                       |
| `opgate scan`                     | Find every `.env` in the project and any secret embedded in a config or source file. Works even while 1Password is locked. Prints no values. |
| `opgate import <file>`            | Move a `.env` into the vault and generate `.env.op`. One Touch ID for the whole file.                                                        |
| `opgate items -p <project>`       | List a project's items in the vault (filtered by tag).                                                                                       |
| `opgate run -- <cmd>`             | The main one. Runs `<cmd>` with all the secrets in its environment. 1Password masks the values in the output.                                |
| `opgate exec VAR=op://… -- <cmd>` | You need exactly one secret.                                                                                                                 |
| `opgate copy op://…`              | The user needs to paste a secret somewhere themselves. Goes to the clipboard, clears after 90s.                                              |
| `opgate inject -i tpl -o out`     | A tool insists on a real file. Refuses to write unless `out` is git ignored.                                                                 |
| `opgate put <ITEM> <FIELD>`       | Put a secret **into** 1Password. Reads the value from stdin. Add `--multiline` for a PEM key or multi-line JSON.                             |
| `opgate doctor`                   | Something is not working. Checks the whole setup and prints how to fix it.                                                                   |
| `opgate audit -n 20`              | Which secrets were reached for recently.                                                                                                     |
| `opgate grants`                   | Which files the hook currently has an approval window open for, and for how long. No Touch ID.                                               |
| `opgate unlock -m 60 <file>`      | Open a window up front so the hook stops asking about that one file. One Touch ID.                                                           |
| `opgate lock [file]`              | Close a window now. No argument closes every one. No Touch ID.                                                                               |

## Common workflows

**An app needs secrets to run** — do not go hunting for `.env`:

```bash
opgate list                  # see what there is
opgate run -- npm run dev    # run it; one Touch ID at startup
```

**One command needs exactly one secret**:

```bash
opgate exec DATABASE_URL=op://Dev/cme-api/DATABASE_URL -- \
  sh -c 'psql "$DATABASE_URL" -c "\dt"'
```

The `sh -c '…'` is required: writing `-- psql "$DATABASE_URL"` lets the **outer**
shell expand the variable before opgate has loaded anything, and psql gets an empty
string.

**A variable is missing**: add a `VAR=op://Dev/<project>/VAR` line to `.env.op`, then
ask the user to run `opgate put <project> VAR` to enter the value. Do not ask them
for the value in chat — it would land in the transcript.

**A plaintext `.env` in the repo**: run `opgate scan` — it lists the files, counts the
variables and suggests item names without reading a single value out. Then propose
`opgate import <file>`. Do not `cat` the file "to see what's in it".

`opgate import` asks you about the variables it is unsure of, and the question
describes only the **shape** of the value (`30 chars · lower/UPPER/symbols`), never
the value. With no terminal to ask on it **stops** rather than guessing — unless you
pass `--yes`. It also stops when the file has a BOM, an unclosed quote, or a `$VAR`
outside single quotes; do not "fix" that by skipping it, tell the user to fix the
file.

**How to group things**: one item per env file, named `<project>-<directory>-<environment>`
(`cme-api`, `cme-web-production`), all carrying the tag `project:<name>`. Group by
tag rather than by naming alone, so filtering works in the app as well as the CLI.

**The hook asked and the user approved** — it will **not ask again for 60 minutes**
for that one file. Which means: a `cat .env` going through does not mean you are now
free to read as you like, only that the user agreed recently. The rule about never
putting a secret value on stdout does not change. To learn which variables a project
has, it is still `opgate list`.

A window covers **one file**, by resolved path. It never covers `op read` or
`op item get` — those stay blocked. `opgate lock` closes it immediately.

**A command exits 77**: the user declined at the Touch ID sheet. That is a "no" —
stop and ask, do not retry or look for a way around. Exit 78 means the prompt could
not be shown (or the gate binary changed) — run `opgate doctor`.

## Storage convention

Vault `Dev`, one item per project (a Secure Note), one field per environment
variable:

```
op://Dev/<project-name>/<VARIABLE_NAME>
```

The `.env.op` file lives in the repo and is **safe to commit**, because it holds
only references:

```
DATABASE_URL=op://Dev/cme-api/DATABASE_URL
JWT_SECRET=op://Dev/cme-api/JWT_SECRET
```

## Further reading

- `references/project-setup.md` — taking a project from a plaintext `.env` to 1Password
- `references/secret-references.md` — `op://` syntax, `.env.op`, the usual mistakes
- `references/security-model.md` — what the gate protects and what it does **not**
