# codex

Runs OpenAI's Codex CLI non-interactively as a second opinion — and, more importantly,
governs what happens to what it says.

## The point of the plugin

Codex is worth consulting only because its verdict may differ from mine. So the rule that
matters is not how to build the command line; it is:

**Present every finding verbatim, attributed to Codex, before touching any code — then
stop and wait.**

That holds even when the user already said "review it and then fix it". A review that
surfaces new concerns invalidates the earlier go-ahead: the user authorised fixing the
problems they knew about, not the ones Codex just found.

The skill came out of a real failure. On 2026-08-16 a Codex review returned NEEDS CHANGE
on all five proposals plus a token leak and a CSP blocker that made the planned fix
unworkable. All of it was compressed into a summary and implementation started right away.
The user never got to read the findings.

## Relationship to `review`

The [`review`](../review) plugin runs adversarial review with multiple **Claude** models
and depends on no external CLI. This plugin is the other half: one external reviewer, with
a different training run and different blind spots. Using both on security-sensitive code
is the intended shape — each reviewer's blind spot tends to be another's headline finding.

## Requires

Codex CLI on `PATH` (`brew install --cask codex`), authenticated via `codex login`.
Verified against **0.149.1**; the skill says which flags were checked and when.

```bash
codex --version
codex doctor
```

## Read

- `skills/codex/SKILL.md` — the loop: model, effort, sandbox, and the hard reporting rule
- `skills/codex/references/reporting-findings.md` — the reporting protocol in full
- `skills/codex/references/cli-reference.md` — verified flags, auth, failure modes
- `skills/codex/references/breaking-changes.md` — production breaking-change checklist
