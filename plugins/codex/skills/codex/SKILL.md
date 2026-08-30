---
name: codex
description: Use when the user asks to run Codex CLI (codex exec, codex resume, codex fork, codex review) or references OpenAI Codex for code analysis, code review, refactoring, or automated editing. Runs OpenAI's Codex agent non-interactively; the default model comes from ~/.codex/config.toml (currently gpt-5.6-sol).
---

# Codex

Codex is consulted precisely because its verdict may differ from mine. Everything in
this skill follows from that: the run is the cheap part, and **getting Codex's words to
the user intact, before any diff, is the whole point**.

Verified against Codex CLI **v0.149.1** (2026-08-31). Flags move between releases —
after `brew upgrade --cask codex` or `codex update`, re-verify with `codex exec --help`.

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

- **Model**: omit `-m` to take the default from `~/.codex/config.toml` (`gpt-5.6-sol`).
  Pass `-m` only when the user wants a specific or cheaper model.
- **Effort**: ask via `AskUserQuestion`. On `gpt-5.6-*` the ladder is `ultra`, `max`,
  `xhigh`, `high`, `medium`, `low` (Luna stops at `max`; `gpt-5.5`/`5.4` stop at
  `xhigh`). Pass as `-c model_reasoning_effort="<effort>"`. Sol is strong at low effort —
  start lower and raise it, rather than defaulting to the top of the ladder.
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
  -c model_reasoning_effort="medium" -o /tmp/codex-out.md \
  "your prompt" </dev/null 2>/dev/null

# Apply local edits
codex exec --skip-git-repo-check --sandbox workspace-write \
  "your prompt" </dev/null 2>/dev/null

# Another directory + explicit model
codex exec --skip-git-repo-check -C /path/to/repo -m gpt-5.6-luna \
  "your prompt" </dev/null 2>/dev/null
```

## Continuing a session

```bash
codex exec resume --last "follow-up prompt" </dev/null 2>/dev/null
codex exec resume <SESSION_ID> "follow-up prompt" </dev/null 2>/dev/null
codex exec fork --last "branch the session here" </dev/null 2>/dev/null
```

Sessions are filtered by cwd; `--all` disables that. `-m` / `-c` are accepted on resume,
but omit them — the session inherits its model, effort, and sandbox. `--last` cannot find
a run made with `--ephemeral`.

After a run finishes, tell the user they can resume it at any time.

## Reviewing a repository

```bash
codex review --uncommitted 2>/dev/null              # staged + unstaged + untracked
codex review --base main 2>/dev/null                # against a base branch
codex review --commit <SHA> 2>/dev/null             # one commit
codex review --base main "focus on security" 2>/dev/null
```

The same reporting rule applies: the review's findings reach the user before any fix does.

## Models

Snapshot from `~/.codex/models_cache.json` (fetched 2026-08-30) — that file and `/model`
in an interactive session are authoritative. Prices drift; do not hardcode them.

| Model | Notes | Efforts |
|---|---|---|
| `gpt-5.6-sol` | **Default**; latest frontier agentic coding model | low → ultra |
| `gpt-5.6-terra` | Balanced, for everyday work | low → ultra |
| `gpt-5.6-luna` | Fast and affordable | low → max |
| `gpt-5.5` | Previous default | low → xhigh |
| `gpt-5.4`, `gpt-5.4-mini` | Older; mini is the cheap one | low → xhigh |
| `gpt-oss-120b/20b` | Local, via `--oss` + `--local-provider` | low → high |

The `gpt-5.3-codex` / `gpt-5.2-codex` line is gone from the list — don't reach for it.

**Effort guide**: `ultra` hardest problems, auto-delegates subtasks (5.6 only) · `max`
maximum depth, no delegation (5.6 only) · `xhigh` ultra-complex analysis · `high`
refactoring, architecture, security · `medium` everyday work (the config default) ·
`low` quick fixes and docs — and, on Sol, plenty of real work too.

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
