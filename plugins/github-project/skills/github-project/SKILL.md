---
name: github-project
description: Build and keep a roadmap board in GitHub Projects (v2) from a repo's plans — one issue per planned PR, open decision and unplanned gap, with Status, MVP and phase fields — then sync it as plans change and report what is done, in progress and blocking "ready to run". Use when the user wants project management or a tracking board for a project, asks what is done vs not done or when it will be ready, gives a github.com/orgs/<org>/projects/<n> (or users/<user>/projects/<n>) link, or asks to sync plan docs to a GitHub Project.
---

# GitHub Project roadmap

`gh-roadmap` (on PATH while this plugin is on) makes a GitHub Project match a JSON spec:
`sync SPEC` (dry run), `sync SPEC --apply`, `verify SPEC`, `report OWNER NUMBER --by FIELD`.
It refuses a spec whole before the first write, matches by title or number so re-runs create
nothing, and verifies itself after applying. Spec format: `references/spec-format.md`.

## Build a board

1. **Access.** `gh auth status` must list the `project` scope. If not, the user runs
   `! gh auth refresh -h github.com -s project` (it opens a browser; you cannot do it).
2. **Inventory from evidence, not from the plan's wording.** Merged PRs
   (`gh pr list --state all`), branches and uncommitted work (status `In progress`), every
   planned PR or phase, every open decision, and deferred scope (ADRs, "open questions").
   Then list what "ready to run" needs that **no plan covers** — CI, deployment, real auth,
   a real model or backend instead of a mock, a client — as items labelled `unplanned`.
3. **Ask once** (one AskUserQuestion): the MVP cut (propose one, recommended first), issues
   or draft items (issues, so a PR's `Closes #n` moves the card), and whether to include the
   unplanned gaps.
4. **Read the board** (`gh project field-list`): Status options differ by template
   (`Todo/In Progress/Done` vs `Backlog/Ready/In progress/In review/Done`). Map to what exists.
5. **Write the spec** (English). Each issue body: what it is, a link to its plan section
   (check every anchor exists), what it depends on, and the MVP definition in one line.
6. **Dry run, show the user the summary, then `--apply`.** Quote the `VERIFY OK` line; never
   report success without it.
7. **Views** go in the spec too (`views`: name, layout, filter, visible fields): a board
   filtered to `mvp:MVP` and a table with every field. The API cannot set grouping or sort,
   so tell the user which to set by hand (for example, group the table by phase).
8. **Hand over:** only the PR that finishes an item says `Closes #n`; a PR that merely
   mentions it (a plan or design change) says `Refs #n`. Commit the spec (for example `docs/roadmap.json`)
   so the next session can re-sync.

## Status questions

`gh-roadmap report OWNER NUMBER --by MVP` gives counts per Status, per MVP value, and every
card that is moving. Cross-check with reality before answering: a merged PR whose issue is
still open, a card `In progress` with no branch.

## Rules

- Never `--apply` before the user has seen the dry run.
- The issue title is the identity key. Renaming an issue: rename it on GitHub **and** in the
  spec in the same step, or the next sync creates a duplicate.
- Status is board-owned (`board_owned`): set when a card is first added, then left to the
  project's workflows and people. A linked PR moves a card to `In progress` by itself, and a
  re-sync must not drag it back. `verify --strict` checks it anyway.
- Existing fields' options are never edited by the tool: add missing options in the project
  settings. Field names like `Type` are reserved by GitHub — use `Kind`.

Details and failure modes: `references/gotchas.md`.
