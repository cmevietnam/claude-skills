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

## Relationship to `codex` and `review`

The [`review`](../review) plugin runs adversarial review with multiple **Claude** models
and needs no external CLI. [`codex`](../codex) is one external reviewer; this is another.
Running both on security-sensitive code and diffing their findings is the intended shape.

Measured over two rounds while building this: **round 1, 9 findings — 4 correct, 2 partly,
3 fabricated; round 2 on this plugin itself, 8 findings — 7 correct, 1 fabricated.** Round
2 earned its keep: it found a real bug in the wrapper and a test that could never go red.
It also repeated round 1's invention word for word, in a document that explicitly told it
that claim was false. Hence the rule that every finding is reproduced before it is believed.

## Requires

```bash
curl -fsSL https://antigravity.google/cli/install.sh -o /tmp/agy-install.sh
less /tmp/agy-install.sh      # read it first; it is short
bash /tmp/agy-install.sh
agy --version
```

Google documents this as `curl … | bash`. Don't: that runs network content before anyone
can look at it, and a failed download becomes an empty script `bash` accepts without
complaint. Note the installer appends a PATH line to **six** shell profiles.

Then sign in **from a real terminal** — `agy` opens a TUI and there is no headless
sign-in (`bubbletea: could not open TTY`), so Claude Code's `!` prefix cannot do it.
Headless runs afterwards reuse the cached credentials.

Verified against **agy 1.1.27**; the skill says what was checked and when. `agy`
self-updates in the background, so re-verify after a gap.

## Read

- `skills/antigravity/SKILL.md` — the loop: model, effort, and the hard reporting rule
- `skills/antigravity/references/headless-permissions.md` — the soft-deny trap, with evidence
- `skills/antigravity/references/reporting-findings.md` — the reporting protocol in full
- `skills/antigravity/references/cli-reference.md` — verified flags, JSON shapes, exit codes
- `skills/antigravity/references/review-prompts.md` — review prompts worth reusing
- `skills/antigravity/references/why-not-gemini-cli.md` — the Gemini CLI dead end, recorded
- `skills/antigravity/references/breaking-changes.md` — production breaking-change checklist
