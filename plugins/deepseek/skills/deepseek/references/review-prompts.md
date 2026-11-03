# Review prompts

`deepseek-review` appends its own closing block to every prompt: the answer must end with
`VERDICT-<nonce>: FINDINGS` or `VERDICT-<nonce>: NO FINDINGS`. So do **not** end a prompt with
"if you find nothing, reply with exactly NO FINDINGS". The two instructions would compete, and
a bare `NO FINDINGS` without the nonce line fails the run.

Unlike `agy`, the reviewer may use tools. It has `read`, `glob` and `grep`, fenced to the repo
when `--repo` is given (or to an empty work dir otherwise), plus `todo_write`. Nothing else is
mounted, so there is no "do not call tools" preamble to add. With the material in the prompt and
no `--repo`, a tool call simply finds nothing.

What separates a useful review from a list of platitudes:

- **Demand a trigger.** "For each finding, give the concrete input or state that produces the
  wrong behaviour." A finding that cannot name one is usually not a finding.
- **Forbid the filler explicitly.** Without that you get "consider adding tests".
- **Name the files.** With `--repo`, list the files under review in the prompt and pass each
  as `--expect-read`. The run then fails unless the reviewer actually read them.

## Correctness pass (the default)

```
Review the change below. Report only defects you can point at.
For each finding give:
  - file:line
  - what breaks
  - the concrete input, state, or sequence that triggers it
Do not report style, naming, formatting, or "consider adding tests".
Do not summarise the change back to me. Do not praise it.
```

## Security pass

```
Review the change below for security defects only:
  - injection (SQL, shell, template, path traversal)
  - authentication and authorization gaps, especially checks applied to the wrong path
  - secrets, tokens, or credentials reaching logs, errors, or client responses
  - unsafe deserialization, SSRF, unchecked redirects
  - TOCTOU and race conditions on shared state
For each: file:line, the attack, and what an attacker gets.
Rank by what an attacker actually gains. Ignore anything not exploitable in this codebase.
```

## Repo-reading pass (`--repo`)

```
The change under review is the diff below. The repository is your working directory: read the
files the diff touches, and any caller or callee you need, with the read, glob and grep tools.
Read at least these files in full before answering: <list>.
Report only defects you can point at, each with file:line, what breaks, and the trigger.
```

Pass the same files as `--expect-read`.

## Plan or document review

```
Review the plan below as an adversarial reviewer. Report:
  - steps that cannot work as written, and why
  - security or data-integrity holes
  - checks that would pass even though the thing they guard is broken
  - anything over-engineered for the stated goal
Numbered, with severity (critical/high/medium/low), the section, what breaks, and the trigger.
```
