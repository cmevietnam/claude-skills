# github-project

Turn a repo's plans into a roadmap board in GitHub Projects (v2), and keep it honest: one
issue per planned PR, open decision and unplanned gap, with Status, MVP and phase fields, plus
the views to read it by. Answers "what is done, what is not, and when is it ready to run".

## What it does

- **`skills/github-project`**: how to build the board from evidence (merged PRs, branches,
  plan sections, open decisions, and the gaps no plan covers), what to ask the user (the MVP
  cut), and how to report status afterwards.
- **`bin/gh-roadmap`**, on the Bash tool's PATH while the plugin is on:

```bash
gh-roadmap sync roadmap.json            # dry run: read calls only, prints the plan
gh-roadmap sync roadmap.json --apply    # create fields, labels, issues, items, views; then verify
gh-roadmap verify roadmap.json          # every item on the board with the spec's values
gh-roadmap report my-org 2 --by MVP     # counts per Status and per MVP value, moving cards
```

The spec format is in `skills/github-project/references/spec-format.md`.

## Guarantees

- **Nothing is written before everything is checked.** Reserved field names (`Type`), values
  that are not options, existing fields missing an option, duplicate items, unknown view
  fields: the spec is refused whole, with every problem listed.
- **Re-runs create nothing.** Issues and drafts are matched by exact title, PRs and existing
  issues by number, views by name; only field values that differ are written.
- **Status belongs to the board after creation.** A linked PR moves a card to In progress by
  itself; a re-sync does not drag it back (`board_owned`, `verify --strict` to check it).
- **Success is a positive line**: `VERIFY OK: <n> items, <v> views, <m> values match`. An
  empty spec fails verification.
- Existing fields' options are never edited, and nothing is ever deleted.

## Requirements

`gh` with the `project` scope (`gh auth refresh -h github.com -s project`), Python 3.9+.

## Tests

```bash
python3 tests/test_gh_roadmap.py   # 27 tests against a fake gh: no network, no account
python3 tests/mutate.py            # 18 sabotaged guards; each must turn its own test red
```

`mutate.py` applies each mutation to a temp copy, never to `bin/gh-roadmap`, and counts a
mutation whose target text has disappeared as a failure.
