# Running reviewers

## First: ask

Don't spawn a reviewer without asking. Give a real estimate, not a vague one:

> Review `plugins/foo` (~1500 lines) with two independent reviewers, Opus 5.5 and then
> Sonnet 5.5 at effort high. At `xhigh` the Opus round takes about 30 minutes. Cost
> follows context size times number of turns: the reviewer re-reads the whole context on
> every tool call, so a narrow scope is much cheaper than a short report. Go ahead?

Ask about both **effort** and **scope**. The user usually wants it narrower than you
planned.

## The two reviewers: Opus 5.5 and Sonnet 5.5

The goal is two **different perspectives**, not the same perspective twice. The default
pair is two different models:

| Reviewer | Model, effort    | Agent tool call                                       | `--model` must show | `--effort` must show |
| -------- | ---------------- | ----------------------------------------------------- | ------------------- | -------------------- |
| A        | Opus 5.5         | `subagent_type: "general-purpose"`, `model: "opus"`   | `claude-opus-5-5`   | the session's effort |
| B        | Sonnet 5.5, high | `subagent_type: "review:sonnet-reviewer"`, no `model` | `claude-sonnet-5-5` | `high`               |

- **Reviewer B's effort is pinned by an agent definition**, `agents/sonnet-reviewer.md`
  in this plugin (`model: claude-sonnet-5-5`, `effort: high`). The Agent tool has no
  effort parameter, so a `general-purpose` agent with `model: "sonnet"` runs at whatever
  effort the harness picks: on 2026-10-03 two such Sonnet reviewers ran at `medium`
  while the Opus reviewer beside them ran at `xhigh`. Do not pass `model` to
  `review:sonnet-reviewer`: a per-call `model` overrides the definition's.

- **Fresh agents, never `subagent_type: "fork"`.** A fork inherits your whole
  conversation, so it is not independent, and it always runs on your model, ignoring
  `model`. The "Sonnet" reviewer would silently be a second Opus that already knows your
  reasoning.
- **The same prompt, word for word, for both.** Only the model and effort differ, so a
  difference in findings comes from the model, not from the wording.
- **Confirm the model and effort from the transcript** once each reviewer finishes:

  ```bash
  scripts/agent-health.sh --model  <task-id> claude-sonnet-5-5  # reviewer B
  scripts/agent-health.sh --effort <task-id> high               # reviewer B
  scripts/agent-health.sh --model  <task-id> claude-opus-5-5    # reviewer A
  ```

  `MATCH` (exit 0) is the only pass. `MISMATCH` means the reviewer ran on another model;
  `NONE` means the transcript holds no model id, which is no evidence either way. The
  `opus` and `sonnet` aliases resolve to the current version (checked on 2026-10-03:
  `claude-opus-5-5` and `claude-sonnet-5-5`). If a later run shows another version,
  report the version that ran, not "Sonnet 5.5". `--effort` works the same way on the
  `effort` field each assistant record carries; `MISMATCH  want high, ran at: medium`
  means the agent definition was not used (wrong `subagent_type`, or the plugin was not
  reloaded after an update).

If one of the two cannot run (quota exhausted, model unavailable), tell the user which
one is missing and fall back, strongest first:

| Instead of the missing reviewer       | When                                              |
| ------------------------------------- | ------------------------------------------------- |
| Another model (`fable`)               | The blind spots still genuinely differ            |
| Same model, different effort          | When only one model is available; `max` vs `high` |
| Same model, different prompt emphasis | Weakest; use only when nothing else is left       |

Run them **sequentially**, A then B, not in parallel. In parallel you don't see the cost
of round one before committing to round two; seeing it first lets the user narrow B's
scope or effort. Running B is still the default: its value is the blind spot A has.

Don't show the second reviewer the first one's results. Its whole value is reaching a
conclusion independently.

## Prompt template

The three bold parts are mandatory; leaving them out is why agents run until you have to
nudge them.

```
Review <specific scope> at <commit>. Ignore <what is out of scope>.
Do not modify any file.

<Describe what the system does and its two or three design goals, with the sentence
"evaluate these critically rather than accepting them as given">

<If there was an earlier review round: list what it found and say plainly "do not assume
those fixes are correct — verify them, and look for what they themselves break">

Priorities, in order:
A. <the highest-risk area, usually the newest code>
B. ...

**Stopping rule: after at most N tool calls, stop investigating and write the report
with what you have. For areas you did not reach, write one line; do not keep digging.**

**Write each finding to <file> as soon as you find it; do not save everything for the
final message.**

**Do not run: <commands that wait on a UI prompt — Touch ID, sudo, interactive
confirmation>. They hang forever.**

For each finding: file:line, what breaks, a concrete reproducing input, and **whether it
was actually reproduced or only inferred**. Order by severity. Where something is fine,
say so briefly; don't pad.
```

The "actually reproduced or only inferred" requirement is worth more than it looks: it
separates certain findings from guesses, and tells you which to re-check first.

## While it runs

Don't poll with a `sleep` loop: the harness notifies you when it finishes. It does not
notify you when an agent goes _quiet_; use `scripts/agent-health.sh` when you suspect
that, or `Monitor` with `agent-health.sh --watch <id>` to be told when the state changes.

If you have to nudge: one `SendMessage` asking it to "stop investigating and write the
report now with what you have". Know that this can make it **rewrite the entire report**:
in the run that produced this skill, one nudge made a reviewer run nearly twice as many
requests.

## After the results arrive

1. **Confirm the model and effort** with `scripts/agent-health.sh --model <task-id>
<expected>` and `--effort <task-id> <expected>`. Label each report with the model
   and effort that actually ran.
2. **Reproduce every finding.** Run exactly the input the reviewer gave. Record which
   are right and which are not.
3. **Present them verbatim**, including findings you disagree with, consider out of
   scope, or already knew. The only edits allowed: shortening absolute paths to
   `file:line`, and fixing line breaks. Say that you made them.
4. **Your opinion goes in a separate section**, afterwards, clearly labelled.
5. **Stop and wait for the user to decide.** Even if they said earlier "fix it once the
   review is done": they authorised fixing the problems they knew about, not the ones the
   reviewer has just found.

## When the final report is lost

If a reviewer finishes without emitting anything, don't rerun it from scratch. For a
sub-agent, `SendMessage` asking it to write the report again: the transcript is still
there, so it does not have to investigate again. That is also why "write to a file as
you go" is in the prompt: it turns losing the final message from losing 30 minutes into
an inconvenience.
