# Spec format

One JSON file describes the board. `gh-roadmap sync` creates what is missing and sets field
values; nothing in the spec is ever deleted from the board.

```json
{
  "owner": "my-org",
  "number": 2,
  "repo": "my-org/my-repo",
  "fields": {
    "MVP": ["MVP", "Post-MVP", "TBD"],
    "Phase": ["M1", "M2", "Unplanned"],
    "Kind": ["Feature", "Docs", "Decision", "Milestone", "Infra"]
  },
  "text_fields": ["Depends on"],
  "labels": {
    "decision": {
      "color": "5319e7",
      "description": "A decision that blocks planned work"
    },
    "unplanned": {
      "color": "fbca04",
      "description": "Not covered by any plan yet"
    }
  },
  "board_owned": ["Status"],
  "views": [
    {
      "name": "MVP progress",
      "layout": "board",
      "filter": "mvp:MVP",
      "fields": ["Title", "Status", "Phase", "Linked pull requests"]
    },
    {
      "name": "Roadmap table",
      "layout": "table",
      "fields": ["Title", "Status", "MVP", "Phase", "Kind", "Depends on"]
    }
  ],
  "items": [
    {
      "pr": 4,
      "fields": {
        "Status": "Done",
        "Phase": "M1",
        "MVP": "MVP",
        "Kind": "Feature"
      }
    },
    {
      "title": "M2-1: Knowledge schema",
      "body": "What it is, a link to the plan section, what it depends on.",
      "fields": {
        "Status": "In progress",
        "Phase": "M2",
        "MVP": "MVP",
        "Kind": "Feature"
      },
      "text": { "Depends on": "M2-0 (#6)" }
    },
    {
      "title": "D1: Object storage for artefacts",
      "body": "Decision needed before M2-4. Default proposed: ...",
      "labels": ["decision"],
      "fields": { "Status": "Ready", "MVP": "MVP", "Kind": "Decision" }
    },
    { "issue": 12, "fields": { "MVP": "Post-MVP" } },
    {
      "title": "Someday: admin UI",
      "draft": true,
      "fields": { "Status": "Backlog" }
    }
  ]
}
```

## Keys

| Key           | Meaning                                                                                  |
| ------------- | ---------------------------------------------------------------------------------------- |
| `owner`       | Org or user that owns the project (`orgs/<owner>/projects/<number>`)                     |
| `number`      | Project number from its URL                                                              |
| `repo`        | `owner/name` for issues and PRs; required unless every item is a draft                   |
| `fields`      | Single-select fields and their options; created if missing, never edited if present      |
| `text_fields` | Text fields; created if missing                                                          |
| `labels`      | Repo labels created if missing; an item's `labels` apply only to issues the spec creates |
| `board_owned` | Fields set only when a card is first added (default `["Status"]`)                        |
| `views`       | Views created when no view has that name; `layout` is `board`, `table` or `roadmap`      |

## Items: exactly one identity each

| Item                            | Identity                             | What sync does                                        |
| ------------------------------- | ------------------------------------ | ----------------------------------------------------- |
| `{"pr": 4}`                     | PR number                            | Adds the PR to the board                              |
| `{"issue": 12}`                 | Issue number                         | Adds an existing issue                                |
| `{"title": "…"}`                | Exact title among the repo's issues  | Creates the issue if no issue has that title, adds it |
| `{"title": "…", "draft": true}` | Exact title among the board's drafts | Creates a draft item if none has that title           |

`fields` take values from the spec's `fields` or, for fields already on the board (such as
`Status`), from the board's options. `text` takes text fields. `body` and `labels` are used
only when the issue is created; later edits to them in the spec do nothing.

## Checks before any write

The whole spec is refused, with every problem listed, when: a field name is reserved
(`Type`, `Status` as a new field, `Labels`, …); a value is not an option; an existing field
lacks an option the spec needs; a text value sits under `fields`; an item is a duplicate or
has two identities; `repo` is missing. Then the board is read and checked the same way before
the first write.
