# Reporting DeepSeek findings

**Every finding must reach the user, and the user must review them before any change is made.**
This is the same protocol as the `codex` and `antigravity` plugins: the rule is about second
opinions, not about which vendor produced them.

## The five rules

1. **Show the complete output, verbatim.** Reproduce every finding, including the ones I
   disagree with, consider out of scope, already knew, or plan to defer. Do not drop, merge,
   soften or re-rank them.
   - Cosmetic edits only: absolute paths shortened to repo-relative `file:line`, and
     whitespace or wrapping. Say when one was made.
   - Tell the user the out dir: `run-N.jsonl` holds the raw stream.
   - If the report is long, publish it as an Artifact. Long is not a licence to summarise.
2. **Separate its words from mine.** Findings first, attributed to DeepSeek with the model and
   effort from the wrapper's `model:` line. My agreement, disagreement or scoping opinion goes
   in a clearly marked section afterwards.
3. **Stop and wait for explicit user review before implementing anything.** No edits, no
   tests, no implementation subagents. This holds even when the user pre-authorised the work
   ("review it and then fix it"): a review that surfaces new concerns invalidates the earlier
   go-ahead.
4. **Verify before believing.** Reproduce each claim against the code, mark which ones
   reproduced, and present the unreproducible ones too, labelled. The sibling reviewers
   showed that a confident, correctly cited finding can be invented, and that being told so
   does not stop it recurring. Measured over five rounds, `agy` fabricated 4 of its findings
   and Codex none.
5. **A failed run is a reportable outcome.** Say the run failed, show the exit code, every
   `FAIL`/`ERROR` line and the out dir, and let the user decide whether to rerun. A run the
   wrapper refused must not be "rescued" by reading `run-N.jsonl` yourself and reporting what
   is in it as a review.

## Measured so far

| Round | Target | Findings | Correct | Partly | Fabricated |
| ----- | ------ | -------- | ------- | ------ | ---------- |
|       |        |          |         |        |            |

No rounds yet. Add one row per review round, so this reviewer's error rate rests on data.

## Shape of a good report

```
## DeepSeek findings (deepseek-flash, effort max)

Out dir: /var/folders/…/deepseek-review-xxxx (run-1.jsonl, status-1.json)

<the answer, verbatim, including its VERDICT line>

## My assessment

Verified each finding against the code: N correct, N partly correct, N did not reproduce.
<which is which, and why — clearly mine, clearly after>
```

Then `AskUserQuestion` on which findings to act on. Not before.

## Three reviewers, used together

DeepSeek, Codex and Antigravity come from different training runs. On security-sensitive code,
run two of them over the same material and diff their findings rather than merging them. Each
reviewer's blind spot tends to be another's headline finding.
