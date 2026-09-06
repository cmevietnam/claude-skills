# Review prompts

Every prompt here starts with the same preamble. It is not decoration — without it a model
handed 47 KB of self-contained material still reached for a shell tool, was auto-denied,
and returned an empty response with `status: SUCCESS`.

```
Answer entirely from the material in this prompt. Do NOT call any tools, do NOT run shell
commands, do NOT read files — tool calls are auto-denied here and will make you produce no
output at all. Write the review directly.
```

**Bound the output too.** A 57 KB review prompt with no length limit came back as
`status: ERROR`, `error: "Your previous response was cut off because it exceeded the output
token limit"` — an entirely wasted run. Add a cap to every review prompt:

```
HARD LIMIT: report AT MOST 6 findings, most serious first, each one AT MOST 6 lines.
Quote only the single line you object to, never a block. No preamble, no closing summary.
If you cannot fit a finding in 6 lines, drop it and report a more serious one instead.
```

**And drop the effort as the bundle grows.** Thinking tokens are charged against the same
output budget and dominate it — a successful 92 KB review used 55,850 output tokens of
which 54,977 were thinking. On that bundle `--effort high` hit the limit twice while
`--effort medium` succeeded on the identical prompt. Reach for `high` on a small diff, not
on a whole subsystem.

Two more things separate a useful review from a list of platitudes:

- **Demand a trigger.** "For each finding, give the concrete input or state that produces
  the wrong behaviour." A finding that cannot name one is usually not a finding.
- **Forbid the filler explicitly.** Without it you get "consider adding tests" and
  "you may want to handle errors here".

## Correctness pass (the default)

```
Review the diff below. Report only defects you can point at in the diff.
For each finding give:
  - file:line
  - what breaks
  - the concrete input, state, or sequence that triggers it
Do not report style, naming, formatting, or "consider adding tests".
Do not summarise the diff back to me. Do not praise it.
If you find nothing, reply with exactly: NO FINDINGS
```

## Security pass

```
Review the diff below for security defects only:
  - injection (SQL, shell, template, path traversal)
  - authentication and authorization gaps, especially checks applied to the wrong path
  - secrets, tokens, or credentials reaching logs, errors, or client responses
  - unsafe deserialization, SSRF, unchecked redirects
  - TOCTOU and race conditions on shared state
For each: file:line, the attack, and what an attacker gets.
Rank by what an attacker actually gains, not by CVSS vocabulary.
Ignore anything not exploitable in this codebase.
If nothing is exploitable, reply with exactly: NO FINDINGS
```

## Breaking-change pass

Use with `breaking-changes.md` appended when the diff is headed for production.

```
Review the diff below for changes that break EXISTING users or EXISTING data, as opposed
to new ones. For each: what breaks, who is affected, and how to mitigate.
Pay particular attention to validation added on read or login paths, changes to token or
cache formats, renamed or removed API fields, and anything needing a coordinated deploy.
If you find no breaking changes, reply with exactly: NO FINDINGS
```

## Document or plan review

For prose rather than code — a design doc, a skill, a migration plan.

```
Review the material below for DEFECTS. Priority order:
1. FACTUAL ERRORS: wrong names, wrong values, claims that contradict each other.
2. INTERNAL CONTRADICTIONS: the same fact stated two different ways in two places.
3. UNSUPPORTED CLAIMS: anything asserted as verified that the evidence does not establish.
4. DANGEROUS ADVICE: anything that could cause data loss, leak a credential, or grant more
   access than the text claims.
5. INSTRUCTIONS THAT WOULD NOT WORK: shell quoting or ordering bugs, commands whose output
   would not be what the text says.
For each: the quoted phrase you object to, what is wrong, what it should say instead.
Do not report style, tone, length, or "add more examples".
If you find no defects, reply with exactly: NO FINDINGS
```

This is the prompt that produced 9 findings on this plugin's predecessor — 4 correct, 3
fabricated. Useful, and exactly why rule 4 of `reporting-findings.md` exists.

## Second opinion on a proposal

```
Above is a proposed change. Say whether it is correct and whether it will do what it
claims. Lead with the verdict: CORRECT, NEEDS CHANGE, or WRONG.
Then list what is wrong or missing, most serious first, each with the specific failure it
causes. Do not restate the plan back to me.
```

## Assembling and running

```bash
set -euo pipefail            # a failed producer must not yield a half-built prompt
S="$(mktemp -d)"             # private 0700; never a predictable /tmp path

git diff main...HEAD > "$S/diff.txt"     # committed only — omits uncommitted work
[ -s "$S/diff.txt" ] || { echo "nothing to review"; exit 1; }

cat "$S/preamble.txt" "$S/instructions.txt" "$S/diff.txt" > "$S/prompt.txt"

agy-review --out "$S/flash" "$S/prompt.txt"        # newest Flash, effort high
```

With no `--model`, `agy-review` asks `agy models` for the newest Flash generation and
prints which id it picked. Pass `--model <id>` when the run has to be reproducible — a
re-run weeks later would otherwise silently use a newer model than the one the findings
were attributed to.

Without `set -e` and the emptiness check, a missing base branch leaves `diff.txt` empty,
the model reviews the instructions alone, and a confident `NO FINDINGS` comes back on a
diff nobody looked at.

Give each model its own `--out` subdirectory: `agy-review` refuses to overwrite an
existing `out.json`, so a second model pointed at the same directory fails rather than
destroying the first raw report.

## Reading the result

`agy-review` prints the review on stdout only when the envelope proves one exists, and
exits 1 with a diagnosis otherwise. To validate a run made some other way:

```bash
agy-review --check "$S/out.json"
```

`NO FINDINGS` is a real result and gets reported as such. An empty `response`, a populated
`error`, a non-empty `denied_actions`, or a non-zero exit is a **failed run** — report the
failure, never a clean review.

`jq -r '.response // "failed"'` is not a substitute: on a zero-byte file it prints nothing
and exits 0, so a failed run is indistinguishable from a quiet one.

## Choosing the model

Start with the default — the newest Flash, at `--effort high`. Escalate to
`gemini-3.1-pro-high` for subtle concurrency, cross-module invariants, or cryptographic
logic.

For a genuine second opinion — a different training run, different blind spots — use
`claude-opus-4-6-thinking`. On security-sensitive code run both and diff the findings
instead of merging them.

Say which model and effort produced which findings when reporting.
