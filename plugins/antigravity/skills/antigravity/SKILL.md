---
name: antigravity
description: Use when the user asks to run Antigravity CLI or `agy` for code review, a second opinion, code analysis, or a headless agent run — "ask antigravity", "agy review this", "have gemini flash look at it", "second opinion on this diff". Google's Antigravity CLI, which replaced Gemini CLI for personal accounts; reviews with gemini-3.8-flash at effort high by default and never uses gemini-3.1-pro. Reports findings verbatim before any code changes.
---

# Antigravity CLI (`agy`)

Antigravity is consulted precisely because its verdict may differ from mine. Everything
here follows from that: the run is the cheap part, and **getting its words to the user
intact, before any diff, is the whole point**.

Sibling of the `codex` plugin — same discipline, different reviewer. It replaces the
Gemini CLI path entirely: Google closed `gemini-cli` to personal Google accounts and
points them here (`references/why-not-gemini-cli.md`).

Verified against **agy 1.1.27** (2026-09-05) by running every command below; the model
list was re-checked on agy 1.2.11 (2026-09-25). Re-verify after an upgrade — `agy`
self-updates in the background, so the version can move under you.

## Hard rule: present, then stop

1. **Show the complete output, verbatim** — every finding, including the ones I disagree
   with, consider out of scope, already knew, or plan to defer. Only cosmetic edits are
   allowed (absolute path → repo-relative `file:line`, whitespace), and I say when I made
   one.
2. **Separate its words from mine.** Findings first, attributed to Antigravity with the
   model used. My agreement, disagreement, or scoping opinion goes in a clearly marked
   section after.
3. **Stop and wait for explicit review before implementing anything** — no edits, no
   tests, no implementation subagents, no rerun with `--dangerously-skip-permissions`.
   This holds even under a prior "review it and then fix it": the user authorised fixing
   the problems they knew about, not the ones the reviewer just found.
4. **Verify every finding before presenting it as fact.** Reproduce each claim against the
   code — without editing anything — and mark which ones reproduced. Across the five
   review rounds that built this plugin, **4 of 52 findings were fabricated** — three in
   the first round, against the predecessor plugin, and one repeated invention that
   recurred in three separate rounds: a confident claim that a tool used in every session
   does not exist. Present the unreproducible ones too, labelled. Counts and detail:
   `references/reporting-findings.md`.
5. **A crashed or empty run is a reportable outcome**, not a gap to fill with my own
   analysis.

Full protocol: `references/reporting-findings.md`.

## The trap that matters most: success is not success

`agy` returns **exit 0 and `"status": "SUCCESS"` with an empty `response`** when a tool it
wanted was auto-denied. A review that never read a line of code looks exactly like a clean
review. Verified:

```json
{
  "status": "SUCCESS",
  "response": "",
  "denied_actions": [{ "action": "command", "display_name": "RunCommand" }]
}
```

So **never trust the exit code or `status`**, and never call `agy` directly for a review.
Use `agy-review`, which this plugin puts on PATH — it runs the prompt and then refuses to
print anything unless the envelope proves a review actually happened:

```bash
agy-review [--model M] [--effort E] [--out DIR] PROMPT_FILE   # run, validate, print
agy-review --no-retry [...] PROMPT_FILE                        # never step the effort down
agy-review --check out.json                                    # validate an existing run
```

It exits 1 with a diagnosis on an empty output file, non-JSON output, a populated `error`,
a non-`SUCCESS` status, any `denied_actions`, or an empty/whitespace response — and it
tells you where the raw `out.json` and `err.txt` are. Confirmed against the live CLI: a
prompt that triggers an auto-deny gives `agy` exit 0 / SUCCESS and `agy-review` exit 1.

`scripts/test-agy-review.sh` has 144 checks, 15 of them meta-tests that deliberately make
each assertion helper fail — because a test that cannot go red proves nothing.

Do not substitute `jq -r '.response // "failed"'`: on a zero-byte file `jq` prints
**nothing and exits 0**, so the fallback never fires and the failure reads as silence.

## Two more traps

**`-p` does not read stdin.** Piping a diff into `agy -p "review this"` reviews _nothing_
and reports SUCCESS. Verified with a marker string: the answer was `NONE`. Content must go
into the prompt argument, or through `--input-format stream-json` on stdin.

**`agy` does not run tools in your shell's working directory.** A relative `cat README.md`
resolved somewhere under `~/.gemini/antigravity-cli`. Use absolute paths, or `--add-dir`.

## Reviewing a diff — the default shape

Put the material _in the prompt_. No tools means no permissions to configure, nothing to
be silently denied, and a deterministic run.

**The "do not call any tools" preamble is behavioural guidance, not a security boundary.**
Nothing in it enforces anything: if a persistent allow-rule such as `command(cat)` already
sits in `~/.gemini/antigravity-cli/settings.json`, the model can still run tools, no
`denied_actions` appears, and the run is accepted as clean. An instruction planted in the
material being reviewed could use that to read credentials.

So before reviewing anything you did not write: **read** that settings file. If it has no
`permissions.allow`, the default denies every tool and you are fine. If it does, **stop and
tell the user what is in it** — that file is theirs, it may hold configuration unrelated to
this plugin, and removing rules is their call, not mine. If they authorise a temporary
change, keep a copy and restore it afterwards.

**The whole prompt travels in `agy`'s argv**, since `agy -p` does not read stdin — on a
shared machine anyone who can list processes can read it, diff included. Check the bundle
for an accidentally committed credential before sending it, and do not use this path for
material that must not leak locally.

```bash
set -euo pipefail                      # an empty diff.txt must not become a clean review
S="$(mktemp -d)"                       # private 0700, not a predictable shared path

# Pick the scope deliberately. `main...HEAD` reviews committed work only and silently
# omits uncommitted changes — usually not what you want mid-task.
git diff main...HEAD > "$S/diff.txt"   # or: git diff (unstaged) / --cached / <SHA>
[ -s "$S/diff.txt" ] || { echo "nothing to review"; exit 1; }

{
  echo "Answer entirely from the material in this prompt. Do NOT call any tools, do NOT"
  echo "run shell commands, do NOT read files — tool calls are auto-denied here and will"
  echo "make you produce no output at all. Write the review directly."
  echo
  echo "Review the diff below. Report only defects you can point at in the diff."
  echo "For each: file:line, what breaks, and the concrete input or state that triggers it."
  echo "No style notes, no praise, no summary of the diff."
  echo "If you find nothing, reply with exactly: NO FINDINGS"
  echo
  cat "$S/diff.txt"
} > "$S/prompt.txt"

agy-review --out "$S/flash" "$S/prompt.txt"   # gemini-3.8-flash, effort high
```

`agy-review` adds `--disable-slash-commands`, `--output-format json` and
`--print-timeout 9m`, keeps `out.json` and `err.txt` in `--out`, validates the envelope,
and prints the review only if there is one. A non-zero exit means no review happened —
report that, do not report a clean result.

It prints the model it chose, and where the id came from, before the run:

```
model:      gemini-3.8-flash (default), effort high
```

**That line is what you attribute the findings to** — not "the default", and not the id
you expected. A fallback says so in the same place.

Its **default** effort is applied only to an unsuffixed `gemini-*` id, since every other
id rejects `--effort`. An **explicit** `--effort` is always forwarded, so `agy`'s own error
surfaces instead of being silently dropped — meaning
`agy-review --model gemini-3.8-flash-high --effort high` still fails, by design.

`--disable-slash-commands` matters: a diff containing a line that starts with `/` would
otherwise be expanded as a slash command.

More prompts: `references/review-prompts.md`.

## Models

### The default is `gemini-3.8-flash` at `--effort high`, pinned

The user's decision (2026-09-25): every review runs on `gemini-3.8-flash` with
`--effort high` unless they name another model. It is pinned in `DEFAULT_MODEL` in
`bin/agy-review`, not discovered. A newer Flash appearing in `agy models` changes nothing
until someone edits that line. The base id is used, not `gemini-3.8-flash-high`, so the
effort travels as a flag and the retry ladder can step it down (see Failure modes).

### Never use `gemini-3.1-pro`

**Do not run `gemini-3.1-pro` in any form:** not as an escalation, not as a second
opinion, not as the "different budget" route when a run overruns the output limit. This
is the user's standing instruction. `agy-review` enforces it: `--model gemini-3.1-pro`,
`-high`, `-low`, in any letter case, exits 2 before `agy` runs.

When a harder review or a second opinion is wanted, use a Claude id
(`claude-opus-4-6-thinking`). When calling `agy` directly (the follow-ups under
Sessions), do not choose a Pro model either.

- `--model <id>` pins a different reviewer. Use it when a second opinion needs a specific
  model.

### What `agy models` lists

`agy models` is authoritative and needs auth. As of 2026-09-25 (agy 1.2.11) it lists:

| Model                                           | Notes                                                               |
| ----------------------------------------------- | ------------------------------------------------------------------- |
| `gemini-3.8-flash-high` / `-medium` / `-low`    | The default (base id + `--effort high`). Fast, cheap, good on diffs |
| `gemini-3.7-flash-*`, `gemini-3.6-flash-*`      | Older Flash generations                                             |
| `gemini-3.1-pro-high` / `-low`                  | **Banned.** Never use; `agy-review` refuses it                      |
| `claude-sonnet-4-6`, `claude-opus-4-6-thinking` | A genuinely different training run — best for a true second opinion |
| `gpt-oss-120b-medium`                           | Open-weights option                                                 |

Effort is either **baked into the model id** (`gemini-3.8-flash-high`) or passed separately
against the base name (`--model gemini-3.8-flash --effort high`). Both at once is an error,
and so is `--effort` on a model that does not take it:

```
--model gemini-3.8-flash-low --effort high  → conflicts with --effort=high
--model claude-sonnet-4-6    --effort high  → --effort is not supported for model "claude-sonnet-4-6"
```

`agy-review` handles this: given no explicit `--effort` it applies the default only to an
unsuffixed `gemini-*` id, and passes an explicit one straight through so `agy`'s own error
surfaces rather than being swallowed. It is also why the pinned default is the base id:
`gemini-3.8-flash-high` would make the default effort an error.

An unknown model is never silently substituted: exit 1, `"status":"ERROR"`, with the model
list in `.error`.

When the user wants a real second opinion on security-sensitive code, prefer
`claude-opus-4-6-thinking` or run two models and diff their findings.

## Letting it read the repo (only when needed)

Headless, every tool that needs approval is denied. To grant access, add allow-rules to
`~/.gemini/antigravity-cli/settings.json` — **one rule per tool**, verified working:

```json
{
  "permissions": {
    "allow": ["read_file(/abs/path/to/repo)"]
  }
}
```

`read_file(<prefix>)` is the rule to reach for: it is scoped to a path. **`command(cat)`
is not** — despite reading like "let it read the repo", it permits `cat` against every
file the user can read, `~/.ssh/id_ed25519` and `~/.aws/credentials` included, and the
rule is global and persists into every later session. Add it only if something truly needs
a shell, say so explicitly, and remove it afterwards.

One rule per tool: `command(cat)` alone still leaves `read_file` denied, and vice versa.
Tool names seen: `run_command` (`command(<binary>)`), `read_file` (`ViewFile`),
`find_by_name`. Ask the user before writing to their global settings, and prefer the
no-tools shape above — it needs no permissions at all.

`--dangerously-skip-permissions` auto-approves everything including writes. Ask first, say
so plainly, and consider `--sandbox` alongside it.

Rule-by-rule evidence: `references/headless-permissions.md`.

## Sessions

`agy-review` has no session flag yet, so a follow-up is the one place `agy` is called
directly — and the false-success trap applies in full, so **validate the envelope**:

```bash
S="$(mktemp -d)"
agy -p "follow-up" --continue --output-format json </dev/null \
  >"$S/out.json" 2>"$S/err.txt"
echo "exit=$?"
agy-review --check "$S/out.json"      # never read .response directly

agy -p "follow-up" --conversation <ID> --output-format json </dev/null \
  >"$S/out2.json" 2>"$S/err2.txt"
agy-review --check "$S/out2.json"
```

A follow-up that reaches for a tool exits 0 with `SUCCESS` and an empty response exactly
like any other denied run; `--check` is what catches it.

`conversation_id` comes back in every JSON envelope. Note that `num_turns`,
`duration_seconds` and `usage` are **cumulative over the session**, not per-turn.

## Failure modes

| Exit | Meaning                                                                 |
| ---- | ----------------------------------------------------------------------- |
| 0    | `SUCCESS` — but see the trap above; 0 does not mean the review happened |
| 1    | `ERROR` — bad flags, unknown model, auth missing                        |
| 2    | `ERROR` — unsupported stream message in `--input-format stream-json`    |

- **`Please sign in`** — headless cannot authenticate. The user runs `agy` in a **real
  terminal** (not `!` in Claude Code, which has no TTY: `bubbletea: could not open TTY`).
- **`exceeded the output token limit`** — `status: ERROR` with an empty response, and it
  arrives **after** the model has run, so the attempt is already spent. **Thinking tokens
  count against that budget and dominate it**: a successful 92 KB review reported
  `output_tokens: 55850` of which `thinking_tokens: 54977`. `agy --help` offers no flag
  for the budget — only `--model` and `--effort` move it.

  `agy-review` **retries one effort rung lower** (high → medium → low), keeps each
  attempt's raw report (`out.json`, `out-2.json`, …), and prints
  `effort=… attempts=…` — the effort on that line is the one the findings are attributed
  to, not the one you asked for.

  **To keep the effort, shrink the input.** The budget is per run, so half the diff is
  half the thinking: `references/review-prompts.md` has the split-and-merge recipe, and
  `--no-retry` turns the ladder off so a run either answers at the effort you asked for
  or fails. A Claude id has a different budget, also at full effort (never
  `gemini-3.1-pro`). Bounding the answer in the prompt buys little — the visible answer
  was ~2% of that budget.

  Invisible to anything that reads `.response` without checking `.error`; `agy-review`
  catches it.

- **stderr carries the diagnosis**, including the auto-deny warning. Never discard it —
  capture it to a file. Mixing it into stdout corrupts `stream-json` output with non-JSON
  lines.
- Any non-zero exit: stop, report it with the stderr text, ask for direction.

## Production changes

When the review covers anything headed for production, append the breaking-change
checklist from `references/breaking-changes.md`. Short version: tightening validation on a
READ or LOGIN path locks out existing users; tighten on WRITE/CREATE paths only, unless the
existing data is migrated first.

## Following up

Present the findings in full first, then use `AskUserQuestion` for next steps. The
follow-up question never stands in for showing the findings. Restate the model and effort
when proposing anything further.

## More

- `references/reporting-findings.md` — the reporting protocol, and why it exists
- `references/headless-permissions.md` — the soft-deny trap and working allow-rules
- `references/cli-reference.md` — verified flags, JSON shapes, exit codes, install, auth
- `references/review-prompts.md` — review prompts worth reusing
- `references/why-not-gemini-cli.md` — why this replaced the `gemini` CLI path
- `references/breaking-changes.md` — the production breaking-change checklist
