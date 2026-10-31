# antigravity

Runs Google's Antigravity CLI (`agy`) headless as a second opinion — and, more importantly,
governs what happens to what it says, and refuses to believe it succeeded just because it
said so.

## The point of the plugin

Antigravity is worth consulting only because its verdict may differ from mine. So the rule
that matters is not how to build the command line; it is:

**Present every finding verbatim, attributed, before touching any code — then stop and
wait.**

That holds even when the user already said "review it and then fix it". A review that
surfaces new concerns invalidates the earlier go-ahead.

## The trap this plugin exists to close

`agy` returns **exit 0 and `"status": "SUCCESS"` with an empty `response`** when every tool
it wanted was auto-denied — which is the default in headless mode, since there is no human
to approve anything. A review that read nothing is indistinguishable from a clean one
unless you look at `denied_actions` and at `response` being empty.

`jq -r '.response // "failed"'` does not save you: on a zero-byte file `jq` prints nothing
and exits 0, so the fallback never fires. The skill ships a Python check that treats empty
output, a populated `error`, and any `denied_actions` as hard failures.

Two more, both verified:

- **`-p` does not read stdin.** Piping a diff in reviews nothing and reports success.
- **`agy` does not run tools in your shell's working directory** — a relative path resolved
  under `~/.gemini/antigravity-cli`. Use absolute paths or `--add-dir`.

## Why not Gemini CLI

Google closed `gemini-cli` to personal Google accounts: sign-in succeeds, then every run
fails with `IneligibleTierError … Gemini Code Assist for individuals … free-tier`, and the
error itself points at Antigravity. Verified across four attempts including a preview
build; a consumer Gemini Pro subscription does not change it. Full record in
`skills/antigravity/references/why-not-gemini-cli.md`.

`agy` is also the better tool for this job: it has a real effort ladder
(`--effort low|medium|high`) and serves Claude and GPT-OSS models next to Gemini, so a
two-reviewer diff is one flag.

## The default model: `gemini-4-argon`, effort high

With no `--model`, `agy-review` reviews with `gemini-4-argon` at `--effort high`. The
default is pinned in `bin/agy-review` (`DEFAULT_MODEL`). A newer model is adopted by
editing that line, never automatically. `--model <id>` picks a different reviewer.

`agy` offers Argon to Google AI Ultra and eligible Gemini Enterprise accounts only. On any
other account the default fails with `agy`'s `invalid model selection`; pass
`--model gemini-3.8-flash`, the previous default, to review there.

`gemini-3.1-pro` is banned. `--model gemini-3.1-pro[-high|-low]` exits 2 before `agy`
runs, and no guidance in this plugin suggests it. For a harder review or a second opinion,
use a Claude id such as `claude-opus-5-5`, which `agy-review` also runs at `--effort high`.

## A run that overruns the output budget is not thrown away

`agy` reports `exceeded the output token limit` **after** the model has run, so the
attempt is already paid for — and thinking tokens dominate that budget (a successful
92 KB review spent 54977 of its 55850 output tokens thinking). `agy --help` has no flag
that raises it: only `--model` and `--effort` move it.

So `agy-review` steps the effort one rung down and runs again (high → medium → low),
keeps every attempt's raw report, and prints which effort actually produced the review —
findings are attributed to that, not to the effort you asked for.

To keep the effort instead, shrink the input: the budget is spent per run, so half the
diff is half the thinking. `--no-retry` turns the ladder off, and
`skills/antigravity/references/review-prompts.md` carries the split-and-merge recipe
along with what it costs (cross-file findings are the price).

## Letting the reviewer read the repo, for one run

`agy-review --repo DIR` lets the model read the files under `DIR` itself instead of
receiving everything in the prompt. `agy` can only be granted that through an allow-rule
in its **global** `settings.json`, so the wrapper adds `read_file(DIR)` for the run and
takes it out afterwards (on success, failure, Ctrl-C, SIGTERM and SIGHUP). Overlapping
runs share the allow-list: each takes out only its own rule, and the last one out
restores the original bytes. A run killed with SIGKILL is cleaned up by the next one, or
by `agy-review --restore`. It refuses to start when the user already has allow-rules, or
when `DIR` overlaps `~/.gemini`, `~/.ssh`, `~/.gnupg` or `~/.aws`, and never overwrites a
`settings.json` someone else changed. Every file under `DIR` is readable, untracked ones
included; while runs last, other `agy` sessions share their rules. Details and evidence
in the skill.

## Relationship to `codex` and `review`

The [`review`](../review) plugin runs adversarial review with multiple **Claude** models
and needs no external CLI. [`codex`](../codex) is one external reviewer; this is another.
Running both on security-sensitive code and diffing their findings is the intended shape.

Measured over five review rounds while building this — `agy` and Codex over the same
material: **52 findings, 46 correct, 2 partly, 4 fabricated.** Every fabrication came from
`agy`; Codex produced none in four rounds. They also barely overlap — in round 4 they
agreed on 2 findings out of 21, and `agy` caught four test-harness defects Codex missed
while Codex caught every security issue `agy` missed.

One `agy` invention recurred in three separate rounds, twice in documents that named it as
fabricated and asked for the correction to be deleted. Hence the rule that every finding is
reproduced before it is believed.

## Requires

```bash
set -euo pipefail
d="$(mktemp -d)"                                                   # private, unguessable
curl -fsSL --proto '=https' https://antigravity.google/cli/install.sh -o "$d/install.sh" \
  && less "$d/install.sh" \
  && bash "$d/install.sh"                # each step gated on the one before
agy --version
```

Google documents this as `curl … | bash`. Don't: that runs network content before anyone
can look at it, and a failed download becomes an empty script `bash` accepts without
complaint. Use `mktemp -d` rather than a fixed `/tmp/install.sh` — a predictable name lets
another local user pre-create it, or swap it between the read and the run.

Note the installer appends a PATH line to **six** shell profiles.

Then sign in **from a real terminal** — `agy` opens a TUI and there is no headless
sign-in (`bubbletea: could not open TTY`), so Claude Code's `!` prefix cannot do it.
Headless runs afterwards reuse the cached credentials.

Verified against **agy 1.1.27**, with the default model re-checked on agy 1.3.4, `--repo`
on agy 1.3.5, and both again on agy 1.4.10; the skill says what was checked and when.
`agy` self-updates in the background, so re-verify after a gap.

## Read

- `skills/antigravity/SKILL.md` — the loop: model, effort, and the hard reporting rule
- `skills/antigravity/references/headless-permissions.md` — the soft-deny trap, with evidence
- `skills/antigravity/references/reporting-findings.md` — the reporting protocol in full
- `skills/antigravity/references/cli-reference.md` — verified flags, JSON shapes, exit codes
- `skills/antigravity/references/review-prompts.md` — review prompts worth reusing
- `skills/antigravity/references/why-not-gemini-cli.md` — the Gemini CLI dead end, recorded
- `skills/antigravity/references/breaking-changes.md` — production breaking-change checklist
