---
name: antigravity
description: Use when the user asks to run Antigravity CLI or `agy` for code review, a second opinion, code analysis, or a headless agent run — "ask antigravity", "agy review this", "have gemini look at it", "second opinion on this diff". Google's Antigravity CLI, which replaced Gemini CLI for personal accounts; reviews with gemini-4-argon at effort high by default and never uses gemini-3.1-pro. Reports findings verbatim before any code changes.
---

# Antigravity CLI (`agy`)

Antigravity is consulted precisely because its verdict may differ from mine. Everything
here follows from that: the run is the cheap part, and **getting its words to the user
intact, before any diff, is the whole point**.

Sibling of the `codex` plugin — same discipline, different reviewer. It replaces the
Gemini CLI path entirely: Google closed `gemini-cli` to personal Google accounts and
points them here (`references/why-not-gemini-cli.md`).

Verified against **agy 1.1.27** (2026-09-05) by running every command below; the model
list was re-checked on agy 1.2.11 (2026-09-25), the default model, the model list and the
effort rules on agy 1.3.4 (2026-10-14), and the model list, a default review and a
`--repo` review on agy 1.4.10 (2026-11-01), and the multi-turn review on agy 1.4.12 the
same day. Re-verify after an upgrade — `agy` self-updates in the background, so the
version can move under you.

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
agy-review --part-kb N [...] PROMPT_FILE                      # parts of N KB (default 48)
agy-review --single-turn [...] PROMPT_FILE                    # one turn, whatever the size
agy-review --check out.json                                    # validate an existing run
agy-review --repo DIR [...] PROMPT_FILE                       # let it read DIR for this run
agy-review --restore                                           # drop grants of killed runs
```

It exits 1 with a diagnosis on an empty output file, non-JSON output, a populated `error`,
a non-`SUCCESS` status, a `finished_reason` (a turn that ended early), any
`denied_actions`, or an empty/whitespace response — in every turn of a multi-turn run —
and it tells you where the raw `out.json` (or `out.ndjson`) and `err.txt` are. Confirmed against the live CLI: a
prompt that triggers an auto-deny gives `agy` exit 0 / SUCCESS and `agy-review` exit 1.

`scripts/test-agy-review.sh` has 347 checks, 14 of them meta-tests that deliberately make
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

**A single-turn prompt travels in `agy`'s argv**, since `agy -p` does not read stdin — on
a shared machine anyone who can list processes can read it, diff included. A multi-turn
review (below) sends its turns on stdin instead and keeps them in `in.ndjson` (0600)
beside the output. Either way, check the bundle for an accidentally committed credential
before sending it, and do not use this path for material that must not leak locally.

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

agy-review --out "$S/argon" "$S/prompt.txt"   # gemini-4-argon, effort high
```

`agy-review` adds `--disable-slash-commands`, `--output-format json` and
`--print-timeout 9m`, keeps `out.json` and `err.txt` in `--out`, validates the envelope,
and prints the review only if there is one. A non-zero exit means no review happened —
report that, do not report a clean result.

It prints the model it chose, and where the id came from, before the run:

```
model:      gemini-4-argon (default), effort high
```

**That line is what you attribute the findings to** — not "the default", and not the id
you expected. A fallback says so in the same place.

Its **default** effort is applied only to an unsuffixed `gemini-*` or `claude-*` id: a
suffixed id carries its own level and conflicts with the flag, and any other family is
left for `agy` to pick the level. An **explicit** `--effort` is always forwarded, so
`agy`'s own error surfaces instead of being silently dropped — meaning
`agy-review --model gemini-3.8-flash-high --effort high` still fails, by design.

`--disable-slash-commands` matters: a diff containing a line that starts with `/` would
otherwise be expanded as a slash command.

### A diff bigger than one part: one conversation, a turn per part

The default since 0.8.0 (the owner's decision, 2026-11-01). When the prompt holds a git
diff (lines starting `diff --git `) bigger than one part — 48 KB, `--part-kb N` to change
it — `agy-review` runs it as **one conversation**: turn 1 carries the instructions and the
whole diff and asks for `READY`, then one turn per part names that part's files and asks
for the defects located in them, reading the rest of the diff as context. Whole files are
packed in diff order; a file bigger than a part is a part of its own. The turns go to
`agy --input-format stream-json` on stdin, one NDJSON message each
(`{"event":"user","message":{"content":"..."}}`).

Why: the output budget, thinking included, is per turn, so each part gets all of it while
the model still sees every file. Measured on 2026-11-01 (agy 1.4.12, gemini-4-argon high,
a 131 KB diff with two planted cross-file defects): the three review turns thought 18403,
5909 and 7777 tokens, and each defect was found twice, once from each side. A single run
on the same diff thought 23177 tokens and found both too; the conversation cost about
1.7 times its tokens (119557 against 71855) and found one real defect the single run
missed.

What changes for you:

- The review comes back **part by part**, each under `## Part k/N: <files>`. Report it
  that way. A load turn that answered with more than `READY` is printed first, under its
  own heading: those are the reviewer's words too.
- Every turn passes the same checks as a single-turn envelope, plus "N turns were sent and
  M answered". One bad turn fails the whole review (exit 1).
- The summary line adds `parts=` and `turns=`. `--out` keeps `in.ndjson`, `out.ndjson`
  and `err.txt` (`-2`, `-3` … per retry).
- A limit failure in any turn reruns the whole conversation one effort rung lower, as a
  single-turn run does. With `--no-retry` the message names `--part-kb` at half the size.
- `--print-timeout` bounds each turn, not the session (agy 1.4.12: three turns of about
  3 s each all finished under a 6 s timeout, 9 s in total).
- `--single-turn` keeps the one-prompt run. `--repo` always runs one turn, since the
  reviewer reads what it needs itself. A prompt without a git diff, or a diff within one
  part, is one turn as before.

More prompts: `references/review-prompts.md`.

## Models

### The default is `gemini-4-argon` at `--effort high`, pinned

The user's decision (2026-10-14; it was `gemini-3.8-flash` from 2026-09-25): every review
runs on `gemini-4-argon` with `--effort high` unless they name another model. It is pinned
in `DEFAULT_MODEL` in `bin/agy-review`, not discovered. A newer model appearing in
`agy models` changes nothing until someone edits that line. The base id is used, not
`gemini-4-argon-high`, so the effort travels as a flag and the retry ladder can step it
down (see Failure modes).

`agy` offers Argon to Google AI Ultra and eligible Gemini Enterprise accounts only. On an
account without it `agy` rejects the id with `invalid model selection` (seen on
2026-10-14, before the account was upgraded) and `agy-review` exits 1: report that, and
re-run with `--model gemini-3.8-flash` only if the user asks for it. Seeing Argon in the
Gemini app does not mean `agy` has it; `agy models` decides.

Through `agy-review` that failure probably reads `--effort is not supported for model
"gemini-4-argon"`, not "not recognized", because the default sends `--effort high`. This
is inferred from an unknown id (`gemini-9-nope`) run on agy 1.3.4, not reproduced on an
account without Argon. When the default fails with that message, run `agy models` before
concluding anything about effort.

### Never use `gemini-3.1-pro`

**Do not run `gemini-3.1-pro` in any form:** not as an escalation, not as a second
opinion, not as the "different budget" route when a run overruns the output limit. This
is the user's standing instruction. `agy-review` enforces it: `--model gemini-3.1-pro`,
`-high`, `-low`, in any letter case, exits 2 before `agy` runs.

When a harder review or a second opinion is wanted, use a Claude id
(`--model claude-opus-5-5`, which runs at `--effort high`). When calling `agy` directly
(the follow-ups under Sessions), do not choose a Pro model either.

- `--model <id>` pins a different reviewer. Use it when a second opinion needs a specific
  model.

### What `agy models` lists

`agy models` is authoritative and needs auth. As of 2026-11-01 (agy 1.4.10, a Google AI
Ultra account; the same ids as on agy 1.3.4 on 2026-10-14) it lists:

| Model                                                   | Notes                                                               |
| ------------------------------------------------------- | ------------------------------------------------------------------- |
| `gemini-4-argon-high` / `-medium` / `-low`              | The default (base id + `--effort high`). Ultra / Enterprise only    |
| `gemini-3.8-flash-high` / `-medium` / `-low`            | The previous default. Fast, cheap, good on diffs                    |
| `claude-opus-5-5-*`, `claude-sonnet-5-5-*` (three each) | A genuinely different training run — best for a true second opinion |
| `gpt-oss-120b-medium`                                   | Open-weights option                                                 |

The listing of 2026-09-25 (agy 1.2.11) also had `gemini-3.7-flash-*`, `gemini-3.6-flash-*`,
`gemini-3.1-pro-high` / `-low` (**banned**: never use, `agy-review` refuses it) and
`claude-sonnet-4-6` / `claude-opus-4-6-thinking`. None of those is listed any more:
`--model claude-opus-4-6-thinking` now fails as an unknown model.

Effort is either **baked into the model id** (`gemini-4-argon-high`) or passed separately
against the base name (`--model gemini-4-argon --effort high`). Both at once is an error.
Verified on agy 1.3.4 for all three families:

```
--model gemini-4-argon-low   --effort high    → conflicts with --effort=high
--model claude-opus-5-5-low  --effort high    → conflicts with --effort=high
--model gpt-oss-120b-medium  --effort high    → conflicts with --effort=high
--model claude-opus-5-5      --effort high    → SUCCESS
--model claude-sonnet-5-5    --effort medium  → SUCCESS
--model gpt-oss-120b         --effort medium  → SUCCESS
--model claude-opus-5-5                       → SUCCESS (agy picks the level)
```

The Claude ids of agy 1.1.27 refused `--effort` outright (`--effort is not supported for
model "claude-sonnet-4-6"`); the 5.5 ids take it like a Gemini id does.

`agy-review` handles this: given no explicit `--effort` it applies the default only to an
unsuffixed `gemini-*` or `claude-*` id, and passes an explicit one straight through so
`agy`'s own error surfaces rather than being swallowed. It is also why the pinned default
is the base id: `gemini-4-argon-high` would make the default effort an error. So
`--model claude-opus-5-5` runs at `--effort high` and is stepped down on an output-limit
failure, while `--model claude-opus-5-5-high` runs once at the level in its id and reports
`effort=n/a`.

An unknown model is never silently substituted: exit 1 and `"status":"ERROR"`. On agy
1.3.4 the model list is in `.error` only when `agy` is called without `--effort`. Through
`agy-review`, an unsuffixed `gemini-*` or `claude-*` id carries `--effort`, and `.error`
is then just `--effort is not supported for model "<id>"`, with no list: that wording
means "unknown id" as often as it means "this model takes no effort".

When the user wants a real second opinion on security-sensitive code, prefer
`claude-opus-5-5` or run two models and diff their findings.

## Letting it read the repo: `--repo`

```bash
agy-review --repo /abs/path/to/repo --timeout 30m PROMPT_FILE   # read access, this run
agy-review --restore                              # drop grants of runs killed with -9
```

Headless, every tool is denied, and the only way to allow one is an allow-rule in the
**global** `~/.gemini/antigravity-cli/settings.json`. `--repo DIR` adds
`read_file(<DIR, resolved>)` there for the length of the run, appends the repo's
`git ls-files` list to the prompt, and takes the rule out again: on success, on failure,
on Ctrl-C, SIGTERM and SIGHUP. Verified on agy 1.3.5: the rule matches whole path
components (a sibling `DIR-secret` is denied), resolves symlinks and normalises `..`.

**Several `--repo` runs can overlap**, on the same repo or different ones: the allow-list
is always the union of the rules of the runs still alive, each run takes out only its
own, and the last one out puts the original bytes of `settings.json` back. While they
overlap, each reviewer can read the other repos too (the owner's accepted trade-off,
2026-10-15). A run killed with SIGKILL leaves its grant behind; the next `--repo` run or
`agy-review --restore` drops it, telling a dead run from an unrelated process that later
got the same pid by its start time. Edits are serialised by an `flock` on
`agy-review.lock` beside `settings.json`; the registry of live grants is
`agy-review-grants/` there.

Write the prompt for `--repo` without the "do not call any tools" preamble: name the
files or the change to review and let it read. The wrapper adds its own rules: read with
the file-viewing tool only, no commands, no search, no directory listing. A model told to
explore runs `find`, which is denied and empties the review; with the list it reads with
`view_file` alone.

**Give it a longer `--timeout`.** Reading files first makes the run slower: one Argon
high `--repo` review was still working at the default 9 minutes, and agy then printed
`print timeout ... returning partial output` and reported SUCCESS. `agy-review` refuses
that run (exit 1). The same review with `--timeout 30m` finished in 377 s.

**`--repo` does not keep a review under the output token limit.** On 2026-10-15 a
`--repo` review of an 84 KB diff at Argon high overran it (`output_tokens: 69998`, of
which 63058 thinking, then `status: ERROR`) and succeeded on the retry at medium. An
earlier pair of runs on a smaller bundle had gone the other way (47153 output tokens with
the material in a 122 KB prompt, 35215 for the `--repo` session), so the size of the
material, not the way it reaches the model, is what decides. agy reports usage per
session, not per response. A `--repo` review is always one turn: the multi-turn split
does not apply to it.

What it refuses, before `agy` starts (exit 2, settings untouched):

- `settings.json` already has allow-rules of the user's. Show them and let the user
  decide: with them in place the run could do more than read.
- `settings.json` is not a plain JSON object, or is a symlink.
- `DIR` is `/`, the home directory or above it; sits inside, or contains (through a
  symlink, as dotfiles setups do), `~/.gemini` (agy's OAuth token), `~/.ssh`, `~/.gnupg`
  or `~/.aws`; is outside a git work tree, or in one rooted at the home directory (a
  dotfiles repo); contains `(`, `)` or a control character; or has more than 3000
  tracked files (pass a subdirectory). `GIT_*` variables of the caller are ignored.
- `settings.json` was changed by someone else while grants were in place: it is never
  overwritten. The message names the original's backup and what to do by hand.

What it does not protect:

- **Every file under `DIR` is readable**, untracked `.env` included. The prompt lists only
  tracked files and says to read only those, but that is guidance, not a fence. Do not use
  `--repo` on a tree holding secrets you would not send to Google.
- **While the run lasts, every other `agy` session of this user has the rule too.**

Any rule beyond that one is still a manual change to the user's global settings. Ask
first. `command(cat)` in particular is not a read-only rule: it permits `cat` against
every file the user can read, `~/.ssh/id_ed25519` included, and persists into every later
session. `--dangerously-skip-permissions` auto-approves everything, writes included.

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
| 1    | `ERROR` — bad flags, unknown model, auth missing, a bad stream message  |
| 3    | an API failure such as a spent quota; stderr has an `AGY_ERROR:` line   |

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

  **To keep the effort, give each turn less.** The budget is per turn, so a git diff is
  reviewed as one conversation in parts by default (see "A diff bigger than one part"
  above), and `--part-kb` makes the parts smaller. `--no-retry` turns the ladder off so
  a run either answers at the effort you asked for or fails. A Claude id has a different
  budget, also at full effort (never `gemini-3.1-pro`). Bounding the answer in the
  prompt buys little — the visible answer was ~2% of that budget.

  Invisible to anything that reads `.response` without checking `.error`; `agy-review`
  catches it.

- **`print timeout ... returning partial output`** on stderr — `--print-timeout` ended the
  turn early, and agy still reports `SUCCESS`, with an empty or a cut-off response.
  `agy-review` refuses it (exit 1). Re-run with a longer `--timeout`; `--repo` reviews
  need it most. agy 1.4.11 and later also mark such a turn
  `"finished_reason": "print_timeout"`, which `agy-review` refuses as well.

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
