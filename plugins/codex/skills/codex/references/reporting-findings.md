# Reporting Codex findings

**Every finding Codex reports must be surfaced to the user, and the user must review them
before any change is made.**

## The five rules

1. **Show the complete output, verbatim.** Reproduce every finding — including the ones I
   disagree with, consider out of scope, already knew, or plan to defer. Do not drop,
   merge, soften, or re-rank them. The only permitted edits are cosmetic: shortening
   absolute paths to repo-relative `file:line`, and fixing whitespace or wrapping. Say
   explicitly when such an edit was made.
   - Always write the raw output to a file with `-o <file>` so the unedited text survives,
     and tell the user where it is.
   - If the report is long, publish it as an Artifact and hand over the link. Long is not
     a licence to summarise.

2. **Separate Codex's words from mine.** Present the findings first, attributed to Codex.
   Any agreement, disagreement, or scoping opinion of mine goes in a clearly marked
   section afterwards. Never blend the two into one voice.

3. **Stop and wait for explicit user review before implementing anything.** After
   presenting the findings, do not edit production code, write tests, spawn implementation
   subagents, or rerun Codex with `--sandbox workspace-write`. Wait for the user to say
   which findings to act on.

   This holds even when the user pre-authorised the work ("review it and then fix it"). A
   review that surfaces new concerns invalidates the earlier go-ahead, because the user
   authorised fixing the problems they knew about, not the ones Codex just found. Present,
   then ask.

4. **Report the verdict faithfully.** If Codex says a proposal is wrong or needs change,
   lead with that, in its terms. Never report "no concerns" unless Codex's output
   genuinely contains none — and quote it saying so.

5. **A crashed or empty run is a reportable outcome**, not something to paper over with my
   own analysis. Say the run failed, show the error, and let the user decide whether to
   rerun.

## Why

On 2026-08-16 (CME certificate fixes) a Codex review returned NEEDS CHANGE on all five
proposals plus several new issues — including a token leak and a CSP blocker that made the
planned fix unworkable, and a logging leak of a public bearer capability. Those were
compressed into my own summary and implementation started immediately under an earlier
"then fix it" go-ahead. The user could not review the actual findings before work began.

The value of a second opinion is the part I would not have written myself. That part must
reach the user intact, and must reach them *before* the diff does.

## Shape of a good report

```
## Codex findings (gpt-6-astra, effort=high, sandbox=read-only)

Raw output: /tmp/codex-review.md

<Codex's text, verbatim>

## My assessment

<agreement, disagreement, scoping — clearly mine, clearly after>
```

Then `AskUserQuestion` on which findings to act on. Not before.
