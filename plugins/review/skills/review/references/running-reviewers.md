# Running reviewers

## First: ask

Don't spawn a reviewer without asking. Give a real estimate, not a vague one:

> Review `plugins/foo` (~1500 lines) with two independent models. At `xhigh` that takes
> about 30 minutes each. Cost follows context size times number of turns: the reviewer
> re-reads the whole context on every tool call, so a narrow scope is much cheaper than
> a short report. Go ahead?

Ask about both **effort** and **scope**. The user usually wants it narrower than you
planned.

## Choosing two reviewers

The goal is two **different perspectives**, not the same perspective twice:

| How to split                          | When                                              |
| ------------------------------------- | ------------------------------------------------- |
| Different models (`fable` vs default) | Best: the blind spots genuinely differ            |
| Same model, different effort          | When only one model is available; `max` vs `high` |
| Same model, different prompt emphasis | Weakest; use only when nothing else is left       |

Run them **sequentially**, not in parallel. In parallel you don't see the cost of round
one before starting round two, and if round one was enough, round two is waste.

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

1. **Reproduce every finding.** Run exactly the input the reviewer gave. Record which
   are right and which are not.
2. **Present them verbatim**, including findings you disagree with, consider out of
   scope, or already knew. The only edits allowed: shortening absolute paths to
   `file:line`, and fixing line breaks. Say that you made them.
3. **Your opinion goes in a separate section**, afterwards, clearly labelled.
4. **Stop and wait for the user to decide.** Even if they said earlier "fix it once the
   review is done": they authorised fixing the problems they knew about, not the ones the
   reviewer has just found.

## When the final report is lost

If a reviewer finishes without emitting anything, don't rerun it from scratch. For a
sub-agent, `SendMessage` asking it to write the report again: the transcript is still
there, so it does not have to investigate again. That is also why "write to a file as
you go" is in the prompt: it turns losing the final message from losing 30 minutes into
an inconvenience.
