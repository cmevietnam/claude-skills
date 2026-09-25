# review

A process for reviewing code with several independent Claude models, for things where
one mistake is expensive: secret handling, parsers, guardrails.

## It never runs anything on its own

This skill **asks before every** reviewer run, with an estimate of time and cost. It
does not spawn agents just because the code looks worth reviewing. One `xhigh` round over
~1500 lines takes about 30 minutes.

Claude models only: no dependency on an external CLI.

## Why two reviewers

Not for more certainty, but because **one reviewer's blind spot is often the other's
headline finding**. In the run that produced this plugin, two independent models
reviewed the same code: one found an environment variable that made a scanner print
credentials to stdout, while the other concluded that the same path could not emit
content. The other found a build command that locked its own verification mechanism on
its second run, which the first missed.

## Usage

```bash
# diagnose a quiet sub-agent
scripts/agent-health.sh <task-id>
scripts/agent-health.sh --list

# watch continuously, for use with Monitor
scripts/agent-health.sh --watch <task-id>
```

`agent-health.sh` classifies a task as `WORKING` / `STALLED` / `DEAD` and says what to
do. It **never prints transcript content**: for a local agent the `.output` file is a
symlink to the full JSONL transcript, and reading it floods the context. The script
prints only the size, the number of records and the type of the last record. A test
asserts that property.

## Tests

```bash
bash scripts/test-agent-health.sh
```

No agents and no network needed.

## Further reading

- `skills/review/SKILL.md`: the review loop and what not to do
- `skills/review/references/running-reviewers.md`: prompt template, choosing reviewers,
  what to do when one hangs
- `skills/review/references/findings-to-tests.md`: turning attack inputs into tests
