# Gotchas (each one was hit on a real board)

## Access

- `gh project …` needs the `project` scope (`read:project` only reads). The error names it:
  `your authentication token is missing required scopes [read:project]`. Only the user can
  grant it: `gh auth refresh -h github.com -s project`, which opens a browser.
- After the refresh, if `gh` is suddenly "command not found", look for a running
  `brew upgrade gh` (`ps -eo etime,command | grep 'brew.rb upgrade'`): the old binary is
  unlinked before the new one is linked. Wait for the process to exit; do not reinstall.

## Fields

- **`Type` is reserved** (issue types): `field-create` fails with "Name cannot have a reserved
  value". So are the built-ins (`Title`, `Status`, `Labels`, `Milestone`, `Repository`,
  `Reviewers`, `Parent issue`, …). `gh-roadmap` refuses these names before calling GitHub.
- **Status options depend on the template** the project was created from. Read them first
  and map your states onto them; never assume `Todo`.
- **`gh-roadmap` never edits an existing single-select field's options.** The API call that
  does (`updateProjectV2Field`) takes the whole option list, so a script that rebuilds it
  risks the values cards already hold. Not tested here, so not taken: add missing options in
  the project settings, then re-run.
- `gh project item-list --format json` keys a field's value by its name with the first
  character lower-cased: `MVP` → `mVP`, `Depends on` → `depends on`. Code that looks up
  `"MVP"` finds nothing and reports every card as unset.

## Items

- `gh project item-add` right after `gh issue create` failed once on a real run and succeeded
  when repeated by hand seconds later, most likely while the new issue propagated. `gh-roadmap` retries with backoff; a hand-written loop must too.
- The project's built-in workflows move cards by themselves. Observed: opening a PR whose body
  says `Closes #n` moved issue `#n` from `Backlog` to `In progress`; the default "Item closed"
  workflow sets `Done` when the issue closes on merge. A spec that re-asserts Status on every sync fights them; hence `board_owned`.
- **`Closes #n` closes `#n` when the PR merges, whatever the PR is about.** A plan PR that
  added a new work item and said `Closes #<that item>` closed an unbuilt feature on merge,
  and the "Item closed" workflow moved its card to `Done`. Only the PR that finishes the
  work says `Closes` (or `Fixes`, `Resolves`); a PR that only mentions an item (plan,
  design, a partial step) says `Refs #n`. Before merging, read the PR body's closing
  keywords and check each named issue is really done. If one slips through: reopen the
  issue with a comment saying why, and set its Status back by hand (reopening does not).
- The issue title is the only link between a spec item and its issue. Rename both together.
- `body` and `labels` apply at creation only. To change an issue's text later, use
  `gh issue edit`.

## Views

- GraphQL has `createProjectV2View` and `updateProjectV2View` (`gh` has no command for them):
  name, layout (`BOARD_LAYOUT`, `TABLE_LAYOUT`, `ROADMAP_LAYOUT`), `filter` (update only) and
  `configuration.visibleFieldIds`. Grouping and sort are read-only in the API, so they are set
  by hand. A new board view groups its columns by Status by itself.
- The visible fields came back in a different order than they were sent ("Linked pull
  requests" moved up). Do not promise column order.
- A filter on a custom field uses its lower-cased name: `mvp:MVP`. The API stores any string,
  so open the view once and check the card count before telling the user it filters.
- Earlier advice in this skill said views had no API. Introspection proved otherwise:
  `gh api graphql -f query='{__schema{mutationType{fields{name}}}}'` lists what exists today.

## Reporting

- Silence is not progress: report from the board, then cross-check against git (merged PRs
  whose issue is still open, `In progress` cards with no branch or PR).
- `verify` fails on an empty spec and prints how many values it checked. Quote that line;
  "no errors" is not evidence.
