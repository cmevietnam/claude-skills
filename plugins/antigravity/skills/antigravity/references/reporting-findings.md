# Reporting Antigravity findings

**Every finding must be surfaced to the user, and the user must review them before any
change is made.**

Identical in substance to the `codex` plugin's protocol — the rule is about second
opinions, not about which vendor produced them.

## The five rules

1. **Show the complete output, verbatim.** Reproduce every finding — including the ones I
   disagree with, consider out of scope, already knew, or plan to defer. Do not drop,
   merge, soften, or re-rank them. The only permitted edits are cosmetic: shortening
   absolute paths to repo-relative `file:line`, and fixing whitespace or wrapping. Say
   explicitly when such an edit was made.
   - Keep the raw `--output-format json` file and tell the user where it is.
   - If the report is long, publish it as an Artifact and hand over the link. Long is not
     a licence to summarise.

2. **Separate its words from mine.** Present the findings first, attributed to Antigravity
   with the model and effort used. Any agreement, disagreement, or scoping opinion of mine
   goes in a clearly marked section afterwards. Never blend the two into one voice.

3. **Stop and wait for explicit user review before implementing anything.** After
   presenting the findings, do not edit production code, write tests, spawn implementation
   subagents, or rerun with `--dangerously-skip-permissions`. Wait for the user to say
   which findings to act on.

   This holds even when the user pre-authorised the work ("review it and then fix it"). A
   review that surfaces new concerns invalidates the earlier go-ahead, because the user
   authorised fixing the problems they knew about, not the ones the reviewer just found.

4. **Verify before you believe — this reviewer fabricates, and it repeats itself.**
   Measured across the two reviews that built this plugin:

   | Round | Target                                  | Findings | Correct | Partly | Fabricated |
   | ----- | --------------------------------------- | -------- | ------- | ------ | ---------- |
   | 1     | the Gemini CLI plugin this replaced     | 9        | 4       | 2      | 3          |
   | 2     | this plugin, wrapper and tests included | 8        | 7       | 0      | 1          |

   Round 2 was genuinely good: it found a real bug that broke the Claude second-opinion
   path, and it caught a negative assertion in the test suite that would have let a
   crashing binary pass as green. It also repeated **the same fabrication as round 1** —
   that `AskUserQuestion` does not exist in Claude Code and must become
   `AskFollowupQuestion`. The second time, the material under review _said explicitly that
   this claim was fabricated_, and the reviewer asked for that correction to be deleted.
   `AskUserQuestion` is real and in use.

   Round 1's other inventions: it disputed a line copied verbatim out of the source,
   arguing from what profile _names_ implied rather than from the code; and it "corrected"
   a grep path to a different filename in the same directory, having conflated two files.

   So: reproduce each claim against the code before presenting it as fact, mark which ones
   reproduced, and present the unreproducible ones too — labelled. A confident, well
   formatted, correctly cited finding can still be invented, and being told so does not
   stop it recurring. Suppressing a finding I could not reproduce is still suppressing a
   finding.

5. **A crashed or empty run is a reportable outcome.** Say the run failed, show the exit
   code, the `status`, `denied_actions`, and the stderr text, and let the user decide
   whether to rerun.

   **Antigravity-specific and non-negotiable**: exit 0 and `"status": "SUCCESS"` do _not_
   mean a review happened. A run whose tools were all denied returns exactly that, with an
   empty `response`. Check that `response` is non-empty and that `denied_actions` is not a
   non-empty collection — missing, `null` and `[]` are all successful shapes, and a good
   run really does report `"denied_actions": null`. `agy-review` does this for you; do it
   before reporting anything at all. See `headless-permissions.md`.

## Why

From the incident that produced the `codex` plugin, on 2026-08-16 (CME certificate fixes):
a review returned NEEDS CHANGE on all five proposals plus several new issues — including a
token leak and a CSP blocker that made the planned fix unworkable. All of it was compressed
into a summary and implementation started immediately under an earlier "then fix it"
go-ahead. The user never got to read the findings.

The value of a second opinion is the part I would not have written myself. That part must
reach the user intact, and must reach them _before_ the diff does.

## Shape of a good report

```
## Antigravity findings (gemini-3.8-flash, effort=high)

Raw output: /tmp/agy-review/out.json

<the response, verbatim>

## My assessment

Verified each finding against the code: N correct, N partly correct, N did not reproduce.
<which is which, and why — clearly mine, clearly after>
```

The model in that heading is the one `agy-review` printed on its `model:` line, not
the one you asked for or expected — with no `--model` the newest Flash is resolved at run
time, so the id can change between runs. A run that fell back to the pinned id says so
there, and the report has to say so too.

Then `AskUserQuestion` on which findings to act on. Not before.

## Two reviewers beat one

`agy` serves Gemini, Claude and GPT-OSS models from one binary, so a second opinion costs
one more flag: run `gemini-3.8-flash-high` and `claude-opus-4-6-thinking` over the same
prompt and diff their findings rather than merging them. On security-sensitive code, do
this by default — each reviewer's blind spot tends to be the other's headline finding.
