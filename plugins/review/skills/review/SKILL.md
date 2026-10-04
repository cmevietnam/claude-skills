---
name: review
description: Run adversarial review with two independent Claude reviewers, Opus 5.5 and Sonnet 5.5 at effort high, reproduce every finding before trusting it, and turn the reviewer's attack inputs into test cases. Use when code that matters needs a hard look (security, secret handling, parsers, guardrails), when a reviewer has just returned results, or when a sub-agent has gone quiet and you need to know whether it is still alive.
---

# Adversarial review

A process for having another model check code where one mistake is expensive: secret
handling, parsers, guardrails, anything that can silently do the wrong thing.

## Hard rule: never start a reviewer on your own

One `xhigh` review round over ~1500 lines takes about 30 minutes and a noticeable share
of quota. **Always ask before spawning**, and ask about both effort and scope. Never
launch a reviewer just because the code looks like it deserves one.

When you ask, give a real estimate: time, the two reviewers (Opus 5.5, then Sonnet 5.5 at
effort high),
and the fact that quota is spent by _context size times number of turns_, not by the
length of the report.

## The loop

1. **Agree the scope with the user.** Narrower than you think. Three 8-minute agents
   return results sooner and bound the damage better than one 28-minute agent.
2. **Run two independent reviewers: Opus 5.5, then Sonnet 5.5 at effort high.** Two
   fresh agents given the same prompt word for word: `subagent_type: "general-purpose"`
   with `model: "opus"`, then `subagent_type: "review:sonnet-reviewer"` with **no**
   `model` parameter (the agent definition pins `claude-sonnet-5-5` and `effort: high`;
   the Agent tool has no effort parameter, and a per-call `model` would override the
   pinned one). No shared context, and neither sees the other's results. Never a
   `fork`: it inherits your conversation and ignores both. See
   `references/running-reviewers.md`.
3. **Confirm each reviewer ran on its model and effort** before you cite it as that:
   `scripts/agent-health.sh --model <task-id> claude-sonnet-5-5` and
   `scripts/agent-health.sh --effort <task-id> high` must both print `MATCH`
   (`claude-opus-5-5` for the Opus reviewer). A reviewer on the wrong model or effort
   still returns a normal-looking report.
4. **Reproduce every finding before trusting it.** This step is never skipped. A
   confident reviewer can still be wrong.
5. **Present the findings verbatim**, and only then your assessment, in a separate
   section. Compressing the reviewer's verdict into your own summary destroys the reason
   for asking.
6. **The user decides what to fix.** Even if they said "review and then fix it": a review
   that surfaces new problems is no longer covered by the earlier permission.
7. **Write tests from the attack inputs themselves**, watch them fail, then fix. See
   `references/findings-to-tests.md`.
8. **Review again** after substantial fixes. Every round here found something the
   previous round missed.

## Why two reviewers

Not for more certainty. Because **one reviewer's blind spot is often the other's
headline finding**. In the run that produced this skill, one reviewer found that the
environment variable `GREP_OPTIONS=-h` made a scanner print credentials to stdout, while
the other concluded that the same path "cannot emit content". The other found that a
build command locked its own verification mechanism on its second run, which the first
missed.

The default pair is Opus 5.5 and Sonnet 5.5 because they are two different models, so
their blind spots differ. When the code was written in an Opus session, the Sonnet
reviewer is also the only one that does not share the author's model.

If only one can be run, tell the user plainly which one ran and that it is one
perspective, not a verdict.

## What not to do

- **Don't trust an unreproduced finding.** Run it again. Record which findings reproduced
  and which did not; in the run above, one finding about a Unicode character did not
  reproduce.
- **Don't compress a reviewer's report** into your own summary and start fixing.
- **Don't report the token count an agent returns** as its cost: that is the context
  size of its final turn, not total consumption. It is off by two orders of magnitude.
- **Don't `Read` a local agent's `.output` file**: it is the full JSONL transcript, and
  reading it floods the context. Use `scripts/agent-health.sh`.

## When a sub-agent goes quiet

Silence means one of three things, and they need opposite responses. Don't wait longer;
diagnose:

```bash
scripts/agent-health.sh <task-id>
```

| Result     | Meaning                                                        | What to do                                                                      |
| ---------- | -------------------------------------------------------------- | ------------------------------------------------------------------------------- |
| `WORKING`  | The file is still growing                                      | Wait                                                                            |
| `STALLED?` | Unchanged for a few minutes, a claude process is still running | `SendMessage` a nudge; it has usually finished and is stuck on its last message |
| `DEAD`     | No process left                                                | `TaskStop`, then rerun                                                          |
| `DONE`     | The output has an exit line                                    | Read the result; don't nudge                                                    |
| `IDLE`     | Silent for a very long time (default >30 minutes)              | Almost certainly finished: check the agent's result before nudging              |

The `?` in `STALLED?` is deliberate: a task id cannot be mapped to a pid, so "a claude
process is still running" only says _something_ is running, not that this task is alive.
Past the `IDLE` threshold that signal means nothing and the script stops relying on it.

The harness notifies you when a task **finishes**, so don't poll with a `sleep` loop. It
does **not** notify you when a task goes _quiet_. That gap is covered by a `Monitor` that
emits an event when the transcript stops growing.

## Writing the reviewer prompt

Every prompt needs three things, or it runs until you have to nudge it:

- **A stopping rule**: "after at most N tool calls, stop and report what you have; for
  areas you did not reach, write one line".
- **Write findings to a file as you go**, not all in the final message. Losing one
  message must not lose 30 minutes of work.
- **A list of commands it must not run**, with the reason: anything that waits on a UI
  prompt (Touch ID, sudo, an interactive confirmation) hangs forever.

The full template is in `references/running-reviewers.md`.
