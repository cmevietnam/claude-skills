---
name: codex
description: Use when the user asks to run Codex CLI (codex exec, codex resume, codex fork, codex review) or references OpenAI Codex for code analysis, code review, refactoring, or automated editing. Runs OpenAI's Codex agent non-interactively on gpt-6.1-sol at effort xhigh by default, pinned on every call rather than taken from ~/.codex/config.toml.
---

# Codex

Codex is consulted precisely because its verdict may differ from mine. Everything in
this skill follows from that: the run is the cheap part, and **getting Codex's words to
the user intact, before any diff, is the whole point**.

Verified against Codex CLI **v0.162.1** (2026-10-20). Flags and models move between
releases — after `brew upgrade --cask codex` or `codex update`, re-verify with
`codex exec --help` and re-read `~/.codex/models_cache.json`.

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

- **Model**: always pass `-m gpt-6.1-sol` — OpenAI's latest workhorse, first in the
  `/model` list as of 2026-10-20 — unless the user names another model. Never omit `-m`:
  an omitted `-m` takes `model =` from `~/.codex/config.toml`, which does not follow new
  releases (it said `gpt-5.6-sol` until 2026-10-20) and differs between machines. Use
  `-m gpt-6-astra` (frontier model) or `-m gpt-6-luna` (fast and cheap) only when the
  user asks for them. If a run is rejected for the model, `codex update`: 0.162.1 runs
  `gpt-6.1-sol`; older builds were not tried.
- **Effort**: always pass `-c model_reasoning_effort="xhigh"` unless the user names
  another effort; don't ask. Never omit it: the model's own default is `low`, and
  `model_reasoning_effort` in `~/.codex/config.toml` (`medium` until 2026-10-20) overrides
  that. On the Sol, Terra and Astra lines the ladder is `ultra`, `max`, `xhigh`, `high`,
  `medium`, `low`; the Luna line stops at `max`.
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
  -m gpt-6.1-sol -c model_reasoning_effort="xhigh" -o /tmp/codex-out.md \
  "your prompt" </dev/null 2>/dev/null

# Apply local edits
codex exec --skip-git-repo-check --sandbox workspace-write \
  -m gpt-6.1-sol -c model_reasoning_effort="xhigh" \
  "your prompt" </dev/null 2>/dev/null

# Another directory + a cheaper model, when the user asks for one
codex exec --skip-git-repo-check -C /path/to/repo -m gpt-6-luna \
  -c model_reasoning_effort="xhigh" \
  "your prompt" </dev/null 2>/dev/null
```

## Continuing a session

```bash
codex exec resume --skip-git-repo-check <SESSION_ID> \
  -m gpt-6.1-sol -c model_reasoning_effort="xhigh" -c sandbox_mode="read-only" \
  "follow-up prompt" </dev/null 2>/dev/null
codex exec resume --skip-git-repo-check --last \
  -m gpt-6.1-sol -c model_reasoning_effort="xhigh" -c sandbox_mode="read-only" \
  "follow-up prompt" </dev/null 2>/dev/null
codex exec fork --skip-git-repo-check --last \
  -m gpt-6.1-sol -c model_reasoning_effort="xhigh" -s read-only \
  "branch the session here" </dev/null 2>/dev/null
```

**A resume does not inherit the first run's model or effort.** On 0.162.1 a session
started on `gpt-6.1-sol` at `xhigh` resumed without flags as `gpt-5.6-sol` at `medium`,
the config values at the time. Repeat `-m` and `-c model_reasoning_effort` on every
resume, and pass the sandbox the first run had: `resume` has no `-s`, so use
`-c sandbox_mode="..."`. Without `--skip-git-repo-check`, a resume outside a trusted
directory exits 1 with "Not inside a trusted directory". Sessions are filtered by cwd;
`--all` disables that. `--last` cannot find a run made with `--ephemeral`.

After a run finishes, tell the user they can resume it at any time.

## Reviewing a repository

`codex review` has no `-m`, so the model goes in as `-c model="..."`:

```bash
# staged + unstaged + untracked
codex review --uncommitted -c model="gpt-6.1-sol" -c model_reasoning_effort="xhigh" 2>/dev/null
# against a base branch, with custom instructions
codex review --base main -c model="gpt-6.1-sol" -c model_reasoning_effort="xhigh" \
  "focus on security" 2>/dev/null
# one commit
codex review --commit <SHA> -c model="gpt-6.1-sol" -c model_reasoning_effort="xhigh" 2>/dev/null
```

The same reporting rule applies: the review's findings reach the user before any fix does.

## Models

Snapshot from `~/.codex/models_cache.json` (fetched 2026-10-20 by 0.162.0) — that file
and `/model` in an interactive session are authoritative. The cache only refreshes on a
real run, not from `codex doctor`, so a model can be missing simply because nothing has
run since the upgrade. Prices drift; do not hardcode them.

| Model              | Notes                                                                | Efforts     |
| ------------------ | -------------------------------------------------------------------- | ----------- |
| `gpt-6.1-sol`      | **Skill default** (pinned with `-m`); latest workhorse, 500k context | low → ultra |
| `gpt-6-astra`      | Frontier model for the most demanding work, 272k context             | low → ultra |
| `gpt-6-sol`        | Previous workhorse                                                   | low → ultra |
| `gpt-6-luna`       | Fast and affordable, for easier tasks                                | low → max   |
| `gpt-5.6-sol`      | Older workhorse; the `model =` in `~/.codex/config.toml` until 10-20 | low → ultra |
| `gpt-5.6-terra`    | Older balanced model                                                 | low → ultra |
| `gpt-5.6-luna`     | Older fast model                                                     | low → max   |
| `gpt-oss-120b/20b` | Local, via `--oss` + `--local-provider`                              | low → high  |

Every listed model has an 872k max context. `gpt-6.1-sol` and `gpt-6-astra` ship `low`
as their own default effort, which the skill's `-c model_reasoning_effort="xhigh"`
overrides. `gpt-5.5` and `gpt-5.4-mini` are gone from the list, like plain `gpt-5.4` and
the `gpt-5.x-codex` line — don't reach for them.

**Effort guide**: `ultra` hardest problems, auto-delegates subtasks (Sol, Terra, Astra) ·
`max` maximum depth, no delegation · `xhigh` deep analysis (the skill default) · `high`
refactoring, architecture, security · `medium` everyday work · `low` quick fixes and docs.
Go below `xhigh` only when the user asks for a faster or cheaper run.

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
