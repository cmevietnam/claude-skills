# deepseek

Runs DeepSeek V4.1-Flash (`deepseek-flash`, effort `max`) as a second-opinion reviewer through
DeepSeek Harness (`dsh`). The run happens inside a fence the reviewer cannot read out of. The
plugin refuses to call a run a review unless the run proves it, and it governs what happens to
the findings.

## The point of the plugin

DeepSeek is worth consulting only because its verdict may differ from mine. So the rule that
matters is not how to build the command line; it is:

**Present every finding verbatim, attributed, before touching any code — then stop and wait.**

## Why a wrapper, and why a fence

dsh is a general coding agent, and its defaults are wrong for an unattended reviewer reading
material someone else wrote:

- its file tool reads any absolute path; the sandbox modes only confine writes;
- it mounts a shell, subagents, a code runner, MCP, and a `web_fetch` that reaches private
  networks without asking;
- it uploads the whole Session log to DeepSeek with every request, by default;
- it loads the repo's `.env` and `AGENTS.md`/`CLAUDE.md`.

`deepseek-review` runs a pinned dsh with an overlay that leaves the reviewer `read`, `glob`,
`grep` and `todo_write`, with uploads and telemetry off. It runs dsh under a **macOS Seatbelt
read allowlist**, so the kernel, not dsh, decides what can be read: the repo, dsh itself and the
runtime. `.env`-like files (`.env`, `.envrc`, `prod.env`, anything under `.env.d/`, …) and
all writes are denied. Each default, the change made to it and how it is enforced is in
`skills/deepseek/references/safety-model.md`.

## A run is a review only if it proves it

A clean exit and a non-empty answer are not enough. The wrapper fails a run on any of these:

- dsh exited non-zero or was cancelled;
- the stream is malformed;
- the last turn did not end `completed` (`max-tokens` and refusals fail);
- the answer does not end with the per-run nonce `VERDICT-<nonce>:` line;
- with `--repo`, no file in the repo was actually read;
- an `--expect-read` file was not read;
- dsh composed fewer rows than the overlay names.

## Where the material goes

To DeepSeek's API in the PRC. Their privacy policy lists training as a purpose, and no API
retention period is published. The skill says so before every run.

## Requires

```bash
claude plugin install deepseek@hieuvo-skills
```

- macOS (for `sandbox-exec`) and Node.js.
- `deepseek-review --install`: installs the pinned dsh `0.2.1-rc.5` from the committed lockfile
  with `npm ci --ignore-scripts`, into `~/.local/share/deepseek-review/` (~850 MB).
- A DeepSeek API key in 1Password, used through the
  [`onepassword`](../onepassword) plugin:
  `opgate exec DEEPSEEK_API_KEY=op://Dev/deepseek/DEEPSEEK_API_KEY -- deepseek-review …`.

## Relationship to `codex`, `antigravity` and `review`

[`codex`](../codex) and [`antigravity`](../antigravity) are the other two external reviewers.
[`review`](../review) runs independent Claude reviewers. On security-sensitive code, run two of
them over the same material and diff the findings.

## Read

- `skills/deepseek/SKILL.md` — the loop: model, effort, the hard reporting rule
- `skills/deepseek/references/safety-model.md` — dsh's defaults, the overlay, the fence, the gaps
- `skills/deepseek/references/cli-reference.md` — flags, codes, observed rc.5 behaviour, API, pricing
- `skills/deepseek/references/reporting-findings.md` — the reporting protocol
- `skills/deepseek/references/review-prompts.md` — prompts worth reusing
- `skills/deepseek/references/breaking-changes.md` — production breaking-change checklist
