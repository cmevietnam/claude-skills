---
name: codex
description: Run, resume, or fork Codex CLI sessions non-interactively for code analysis, review, refactoring, or editing. Defaults to GPT-6.2 Sol at xhigh reasoning effort.
---

# Codex

Codex is consulted precisely because its verdict may differ from mine. Everything in
this skill follows from that: the run is the cheap part, and **getting Codex's words to
the user intact, before any diff, is the whole point**.

The default model and effort were tested on Codex CLI **0.171.0** (2026-11-22).

## Hard rule: present, then stop

1. **Show the complete output, verbatim** — every finding, including the ones I disagree
   with, consider out of scope, already knew, or plan to defer. Only cosmetic edits are
   allowed (absolute path → repo-relative `file:line`, whitespace), and I say when I made
   one.
2. **Separate Codex's words from mine.** Findings first, attributed to Codex. My
   agreement, disagreement, or scoping opinion goes in a clearly marked section after.
3. **Stop and wait for explicit review before implementing anything** — no edits, no
   tests, no implementation subagents, no rerun with `--sandbox workspace-write`. This
   holds even under a prior "review it and then fix it": the user authorised fixing the
   problems they knew about, not the ones Codex just found.
4. **Report the verdict faithfully.** If Codex says a proposal is wrong, lead with that
   in its terms. Never claim "no concerns" without quoting Codex saying so.
5. **A crashed or empty run is a reportable outcome**, not a gap to fill with my own
   analysis.

Always pass `-o <file>` so the unedited text survives, and tell the user the path. If the
report is long, publish it as an Artifact — length is not a licence to summarise.

Full protocol and the incident behind it: `references/reporting-findings.md`.

## Running a task

- Pass `-m gpt-6.2-sol` and `-c 'model_reasoning_effort="xhigh"'` on every run,
  including resumes, forks, and reviews. These flags override `~/.codex/config.toml`.
  When the user specifies a model or effort, use that value for the corresponding flag.
  For reviews, also set `review_model` to the selected model.
- **Check the banner**: stderr opens with `model:`, `sandbox:` and `reasoning effort:`
  lines. When a run fails or an answer looks off, rerun with `2>&1` and report those
  three lines as they were.
- **Sandbox**: `read-only` by default; `workspace-write` to let it edit;
  `danger-full-access` only when network or broad access is genuinely required, and only
  after asking.
- `codex exec` is non-interactive, so the approval policy is already `never`.
  **`--full-auto` no longer exists** — `--sandbox workspace-write` is the apply-edits mode.
- Always `--skip-git-repo-check`. Use `-C <DIR>` for another directory.
- **Append `</dev/null`** when the prompt is an argument, or exec reads stdin as an extra
  `<stdin>` block.
- Final message → stdout; banner, reasoning, and errors → stderr. Default to
  `2>/dev/null`; on a non-zero exit, rerun with `2>&1` to see the error.

```bash
# Read-only review or analysis (safe default)
codex exec --skip-git-repo-check --sandbox read-only \
  -m gpt-6.2-sol -c 'model_reasoning_effort="xhigh"' -o /tmp/codex-out.md \
  "your prompt" </dev/null 2>/dev/null

# Apply local edits
codex exec --skip-git-repo-check --sandbox workspace-write \
  -m gpt-6.2-sol -c 'model_reasoning_effort="xhigh"' -o /tmp/codex-out.md \
  "your prompt" </dev/null 2>/dev/null

# Another directory + a cheaper model, when the user asks for one
codex exec --skip-git-repo-check --sandbox read-only -C /path/to/repo -m gpt-6-luna \
  -c 'model_reasoning_effort="xhigh"' -o /tmp/codex-out.md \
  "your prompt" </dev/null 2>/dev/null
```

## Continuing a session

```bash
codex exec resume --skip-git-repo-check \
  -m gpt-6.2-sol -c 'model_reasoning_effort="xhigh"' -c 'sandbox_mode="read-only"' \
  -o /tmp/codex-resume.md "$session_id" \
  "follow-up prompt" </dev/null 2>/dev/null
codex exec resume --skip-git-repo-check --last \
  -m gpt-6.2-sol -c 'model_reasoning_effort="xhigh"' -c 'sandbox_mode="read-only"' \
  -o /tmp/codex-resume.md \
  "follow-up prompt" </dev/null 2>/dev/null
codex exec fork --skip-git-repo-check \
  -m gpt-6.2-sol -c 'model_reasoning_effort="xhigh"' -c 'sandbox_mode="read-only"' \
  -o /tmp/codex-fork.md "$session_id" \
  "branch the session here" </dev/null 2>/dev/null
```

Set `session_id` to the ID from a saved run's banner. `resume --last` selects the
latest saved session in the current directory. Add `--all` to search across directories.
For resumes and forks, pass the original sandbox via `sandbox_mode`.

After a run finishes, tell the user they can resume it at any time.

## Reviewing a repository

Use `codex exec review` to pin the model and save the final output. Choose
`--uncommitted`, `--base <branch>`, `--commit <sha>`, or a custom prompt that names the
review scope.

```bash
# staged + unstaged + untracked
codex exec review --skip-git-repo-check --uncommitted \
  -m gpt-6.2-sol -c 'review_model="gpt-6.2-sol"' -c 'model_reasoning_effort="xhigh"' \
  -c 'sandbox_mode="read-only"' -o /tmp/codex-review.md </dev/null 2>/dev/null

# against a base branch, with custom instructions
codex exec review --skip-git-repo-check \
  -m gpt-6.2-sol -c 'review_model="gpt-6.2-sol"' -c 'model_reasoning_effort="xhigh"' \
  -c 'sandbox_mode="read-only"' -o /tmp/codex-review.md \
  "Review the diff against main and focus on security." </dev/null 2>/dev/null
```

The same reporting rule applies: the review's findings reach the user before any fix does.

## Model availability

Use `/model` in an interactive session or inspect `~/.codex/models_cache.json` to check
whether a user-requested model is available and what reasoning efforts it supports.

## Production changes

When Codex analyses or applies anything headed for production, append the breaking-change
checklist from `references/breaking-changes.md` to the prompt. The short version:
tightening validation on a READ or LOGIN path locks out existing users; tighten on
WRITE/CREATE paths only, unless the existing data is migrated first.

## Following up

Present the findings in full first, then use `AskUserQuestion` for next steps. The
follow-up question never stands in for showing the findings. Restate the model, effort,
and sandbox mode when proposing anything further.

## More

- `references/reporting-findings.md` — the reporting protocol in full, and why it exists
- `references/cli-reference.md` — verified flag inventory, auth, failure modes
- `references/breaking-changes.md` — the production breaking-change checklist
