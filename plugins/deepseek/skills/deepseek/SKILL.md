---
name: deepseek
description: Use when the user asks for a DeepSeek review or second opinion — "ask deepseek", "deepseek review this", "have DeepSeek look at it", "second opinion from deepseek", "run dsh" — or mentions DeepSeek V4 / DeepSeek Harness for code review or analysis. Runs deepseek-flash (DeepSeek-V4.1-Flash) at effort max through a pinned, sandboxed DeepSeek Harness (dsh) via the `deepseek-review` wrapper, refuses runs that did not produce a real review, and reports findings verbatim before any code changes.
---

# DeepSeek (`deepseek-review`)

DeepSeek is consulted because its verdict may differ from mine. The run is the cheap part;
**getting its words to the user intact, before any diff, is the whole point.** Sibling of the
`codex` and `antigravity` plugins: same discipline, a third reviewer.

Built against **dsh 0.2.1-rc.5** (pinned) on 2026-11-01. dsh is a prerelease that ships breaking
changes between release candidates, and its GitHub README describes `master`, not the pinned
version. Trust `references/cli-reference.md`, which records what rc.5 actually does.

## Before every run: where the material goes

Everything in the prompt, and every file the reviewer reads, is sent to **DeepSeek's API in the
People's Republic of China**. DeepSeek's privacy policy lists model training as a purpose, and
no API retention period is published. Before sending material you did not write, or anything
under an NDA:

- tell the user;
- check the bundle for committed credentials;
- never point `--repo` at a tree that holds secrets.

The fence keeps the reviewer inside the repo, but everything inside it can be sent.

## Hard rule: present, then stop

1. **Show the complete output, verbatim.** Every finding, including the ones I disagree with,
   consider out of scope, already knew, or plan to defer. Only cosmetic edits are allowed
   (absolute path → repo-relative `file:line`, whitespace), and I say when I made one.
2. **Separate its words from mine.** Findings first, attributed to DeepSeek with the model and
   effort from the wrapper's `model:` line. My view goes in a marked section after.
3. **Stop and wait for explicit review before implementing anything.** This holds even under
   a prior "review it and then fix it": the user authorised fixing what they knew about, not
   what the reviewer just found.
4. **Verify every finding before presenting it as fact.** Reproduce each claim against the
   code without editing anything, and mark which ones reproduced. Present the unreproducible
   ones too, labelled. This reviewer's fabrication rate has not been measured yet: record it
   in `references/reporting-findings.md` as rounds accumulate.
5. **A failed run is a reportable outcome**, not a gap to fill with my own analysis.

## Setup (once)

```bash
deepseek-review --install     # npm ci --ignore-scripts from the plugin's lockfile; ~850 MB, ~15 s
deepseek-review --doctor      # version pin, key present (never printed), fence, composed config
```

The key lives in 1Password; the user stores it there (`opgate put deepseek DEEPSEEK_API_KEY`).
Every run goes through opgate, so each use gets a Touch ID prompt and the key never sits in a
shell profile:

```bash
opgate exec DEEPSEEK_API_KEY=op://Dev/deepseek/DEEPSEEK_API_KEY -- deepseek-review …
```

## Running a review

```bash
set -euo pipefail
S="$(mktemp -d)"
git diff main...HEAD > "$S/diff.txt"
[ -s "$S/diff.txt" ] || { echo "nothing to review"; exit 1; }
{ cat "$S/prompt-head.txt"; cat "$S/diff.txt"; } > "$S/prompt.txt"   # prompts: references/review-prompts.md

# The diff in the prompt, no repo access:
opgate exec DEEPSEEK_API_KEY=op://Dev/deepseek/DEEPSEEK_API_KEY -- \
  deepseek-review "$S/prompt.txt"

# Let it read the repo, and require that it read the files under review:
opgate exec DEEPSEEK_API_KEY=op://Dev/deepseek/DEEPSEEK_API_KEY -- \
  deepseek-review --repo "$PWD" --expect-read "$PWD/src/a.go" --expect-read "$PWD/src/b.go" \
  "$S/prompt.txt"
```

Run it with `run_in_background`: a review at effort max can outlast the Bash tool's 600 s cap.
The wrapper's own `--timeout` defaults to 30m.

- **Prompt.** It is sent on stdin and never appears in argv. Write it into a fresh `mktemp -d`
  dir: a prompt file reached through a symlink you own, a dotfile directly in a home, or a
  `.env`-like file is refused (`PROMPT_UNSAFE`).
- **VERDICT line.** The wrapper appends a per-run nonce and requires the answer to end with
  `VERDICT-<nonce>: FINDINGS` or `VERDICT-<nonce>: NO FINDINGS`. Do not add your own
  "reply NO FINDINGS" instruction.
- **Raw files.** They stay in the out dir it prints, mode 0700: `run-N.jsonl`, `err-N.txt`,
  `status-N.json`, `prompt-N.txt`. Tell the user where they are.
- **Follow-up in the same session:** `deepseek-review --continue OUT_DIR PROMPT_FILE`. It takes
  the next attempt number, the recorded repo and the `--expect-read` files of every earlier
  attempt.
- **Re-validate a finished attempt:** `deepseek-review --check OUT_DIR [--attempt N]`.

## A run is a review only if it proves it (exit 1 otherwise)

The wrapper prints nothing on stdout unless every check passes. Each failed check prints its own
`deepseek-review: FAIL <CODE>` line:

- dsh exited 0 and was not cancelled;
- the NDJSON stream is well formed: valid UTF-8, `session` first with an absolute cwd, exactly
  one `final`, last, no `error` event, every tool call and result with its own valid callId, no
  `tool_result` before its `tool_call`;
- the last turn ended `completed` (`max-tokens` or a refusal fails);
- the answer is non-empty and ends with this run's VERDICT line, exactly once;
- with `--repo`, at least one file inside the repo was really read (a result counts only after
  its tool call and only in dsh's file envelope; on a `--continue`, reads of earlier PASS attempts
  count too);
- every `--expect-read` file was read;
- dsh composed every row of the overlay (a drifted row id fails the run).

`--check` also fails when an attempt file is missing (`ATTEMPT_INCOMPLETE`), and keeps the
reasons a failed attempt recorded.

What it cannot catch: an answer that says "I could not review this" beside a valid VERDICT.
That is why the answer is presented verbatim and read. `--expect-read` narrows that gap.

## Model, effort, budget

- **Default:** `deepseek-flash` (DeepSeek-V4.1-Flash), effort `max`, `max_tokens` **393216**.
  That is the API's maximum for one response; the API's own default at max is 128K. Reasoning
  counts against it (a live run capped at 300 ended `max-tokens` mid-thought), so a smaller
  budget risks a failed run, never a shorter answer.
- **Other models and efforts:** `--model deepseek-v4-pro` (the larger V4-Pro, about four times
  the price per token) and `--effort low|high`, only when the user asks. Any other effort is
  refused, because the API silently maps unknown values (`xhigh`→`high`); there is nothing
  above `max`.
- **Attribution:** attribute findings to the `model:` line the wrapper prints. The rc.5
  stream does not report the served model, so that line comes from the request.
- **Cost:** on flash, about a quarter of V4-Pro's per-token price: roughly $0.05–0.15 per
  multi-turn review at peak, and about $0.47 for one response at the full budget (V4-Pro: about
  $1.52). Effort `max` spends more output tokens on reasoning than `high`. Off-peak is half
  price.
- **Peak hours (Vietnam time):** 08–11 and 13–17, Mon–Fri. Details are in
  `references/cli-reference.md`.

## Exit codes

| Exit | Meaning                                                                        |
| ---- | ------------------------------------------------------------------------------ |
| 0    | A review: stdout is the answer                                                 |
| 1    | dsh ran, but the result is not a review: report the FAIL lines and the out dir |
| 2    | Setup or usage error (`ERROR <CODE>`); nothing was sent                        |

On exit 1 or 2: stop, show the codes and the out dir to the user, and ask before rerunning.
Never silently retry a run that costs money.

## Production changes

When the review covers anything headed for production, append the breaking-change checklist
from `references/breaking-changes.md`. Short version: tightening validation on a READ or LOGIN
path locks out existing users; tighten only where the value is created or changed.

## Following up

Present the findings in full first, then use `AskUserQuestion` for next steps. Restate the model
and effort when proposing anything further.

## More

- `references/reporting-findings.md` — the reporting protocol, and why it exists
- `references/safety-model.md` — what dsh does by default, what the wrapper turns off, the
  Seatbelt fence, and what none of it covers
- `references/cli-reference.md` — the wrapper's flags and codes, observed dsh rc.5 behaviour,
  API parameters, pricing
- `references/review-prompts.md` — prompts worth reusing
- `references/breaking-changes.md` — the production breaking-change checklist
