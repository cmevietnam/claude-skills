"""Tests for bin/gh-roadmap against a fake gh. No network, no GitHub account.

Run: python3 tests/test_gh_roadmap.py
"""
import copy
import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
TOOL = os.environ.get("GH_ROADMAP_TOOL", os.path.join(HERE, "..", "bin", "gh-roadmap"))
FAKE = os.path.join(HERE, "fake_gh.py")
WRITES = {"project field-create", "project item-add", "project item-edit",
          "project item-create", "issue create", "label create", "api graphql-mutation"}

BOARD = {
    "project": "demo",
    "fields": [
        {"id": "F_Title", "name": "Title", "type": "ProjectV2Field"},
        {"id": "F_Status", "name": "Status", "type": "ProjectV2SingleSelectField",
         "options": [{"id": "S_b", "name": "Backlog"}, {"id": "S_r", "name": "Ready"},
                     {"id": "S_p", "name": "In progress"}, {"id": "S_d", "name": "Done"}]},
    ],
    "items": [],
    "issues": [],
    "labels": ["bug"],
}

SPEC = {
    "owner": "o", "number": 1, "repo": "o/r",
    "fields": {"MVP": ["MVP", "Post-MVP"], "Kind": ["Feature", "Decision"]},
    "text_fields": ["Depends on"],
    "labels": {"decision": {"color": "5319e7", "description": "A decision"}},
    "items": [
        {"pr": 4, "fields": {"Status": "Done", "MVP": "MVP", "Kind": "Feature"}},
        {"title": "Build the thing", "body": "b", "fields": {"Status": "In progress",
                                                              "MVP": "MVP", "Kind": "Feature"},
         "text": {"Depends on": "#4"}},
        {"title": "Pick a database", "body": "b", "labels": ["decision"],
         "fields": {"Status": "Ready", "MVP": "MVP", "Kind": "Decision"}},
        {"title": "Someday idea", "draft": True, "fields": {"Status": "Backlog",
                                                             "MVP": "Post-MVP"}},
    ],
}


def label(args):
    if args[:2] == ["api", "graphql"] and any(a.startswith("query=mutation") for a in args):
        return "api graphql-mutation"
    return " ".join(args[:2])


VIEW = {"name": "MVP progress", "layout": "board", "filter": "mvp:MVP",
        "fields": ["Title", "Status", "Kind", "Depends on"]}


class Case(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.state = os.path.join(self.tmp, "state.json")
        self.log = os.path.join(self.tmp, "log.jsonl")
        self.spec_path = os.path.join(self.tmp, "spec.json")
        self.board(BOARD)
        self.spec(SPEC)

    def board(self, b):
        with open(self.state, "w") as fh:
            json.dump(b, fh)

    def spec(self, s):
        with open(self.spec_path, "w") as fh:
            json.dump(s, fh)

    def state_now(self):
        with open(self.state) as fh:
            return json.load(fh)

    def calls(self):
        if not os.path.exists(self.log):
            return []
        with open(self.log) as fh:
            return [label(json.loads(line)) for line in fh]

    def run_tool(self, *args):
        env = dict(os.environ, GH_ROADMAP_GH=FAKE, FAKE_GH_STATE=self.state,
                   FAKE_GH_LOG=self.log, GH_ROADMAP_BACKOFF="0")
        r = subprocess.run([sys.executable, TOOL, *args], capture_output=True, text=True,
                           env=env)
        return r.returncode, r.stdout, r.stderr

    def writes(self):
        return [c for c in self.calls() if c in WRITES]


class DryRun(Case):
    def test_dry_run_reads_only_and_prints_the_plan(self):
        rc, out, err = self.run_tool("sync", self.spec_path)
        self.assertEqual(rc, 0, err)
        self.assertIn("[dry run] create field MVP: ['MVP', 'Post-MVP']", out)
        self.assertIn("[dry run] create issue: issue 'Build the thing'", out)
        self.assertIn("[dry run] create draft: draft 'Someday idea'", out)
        self.assertIn("[dry run] summary: 1 add, 1 create draft, 2 create issue", out)
        self.assertGreater(len(self.calls()), 0, "the fake gh was never called")
        self.assertEqual(self.writes(), [])


class Apply(Case):
    def test_apply_builds_the_board_and_verifies_it(self):
        rc, out, err = self.run_tool("sync", self.spec_path, "--apply")
        self.assertEqual(rc, 0, out + err)
        self.assertIn("VERIFY OK: 4 items, 12 values match", out)
        st = self.state_now()
        self.assertEqual(sorted(f["name"] for f in st["fields"]),
                         ["Depends on", "Kind", "MVP", "Status", "Title"])
        self.assertIn("decision", st["labels"])
        made = {i["title"]: i for i in st["issues"]}
        self.assertEqual(made["Pick a database"]["labels"], ["decision"])
        item = next(i for i in st["items"] if i["title"] == "Build the thing")
        self.assertEqual((item["status"], item["mVP"], item["depends on"]),
                         ("In progress", "MVP", "#4"))

    def test_second_apply_creates_nothing_and_edits_nothing(self):
        self.assertEqual(self.run_tool("sync", self.spec_path, "--apply")[0], 0)
        os.remove(self.log)
        rc, out, err = self.run_tool("sync", self.spec_path, "--apply")
        self.assertEqual(rc, 0, out + err)
        self.assertIn("summary: 4 on board", out)
        self.assertEqual(self.writes(), [])
        self.assertIn("VERIFY OK", out)

    def test_changed_value_is_the_only_edit(self):
        self.assertEqual(self.run_tool("sync", self.spec_path, "--apply")[0], 0)
        spec = copy.deepcopy(SPEC)
        spec["items"][1]["fields"]["MVP"] = "Post-MVP"
        self.spec(spec)
        os.remove(self.log)
        rc, out, err = self.run_tool("sync", self.spec_path, "--apply")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(self.writes(), ["project item-edit"])
        self.assertIn("set {'MVP': 'Post-MVP'}", out)

    def test_status_moved_on_the_board_is_not_reverted(self):
        # A linked PR or a person moves Status after the item exists; the board owns it then.
        self.assertEqual(self.run_tool("sync", self.spec_path, "--apply")[0], 0)
        st = self.state_now()
        next(i for i in st["items"] if i["title"] == "Pick a database")["status"] = "In progress"
        self.board(st)
        os.remove(self.log)
        rc, out, err = self.run_tool("sync", self.spec_path, "--apply")
        self.assertEqual(rc, 0, out + err)
        self.assertEqual(self.writes(), [])
        self.assertIn("VERIFY OK: 4 items, 8 values match (4 board-owned values not "
                      "checked; --strict checks them)", out)
        self.assertEqual(next(i for i in self.state_now()["items"]
                              if i["title"] == "Pick a database")["status"], "In progress")

    def test_existing_issue_is_matched_by_title_not_duplicated(self):
        b = copy.deepcopy(BOARD)
        b["issues"] = [{"title": "Build the thing", "url": "https://github.com/o/r/issues/7",
                        "number": 7}]
        self.board(b)
        rc, out, err = self.run_tool("sync", self.spec_path, "--apply")
        self.assertEqual(rc, 0, out + err)
        self.assertIn("add: issue 'Build the thing'", out)
        self.assertEqual(len(self.state_now()["issues"]), 2)  # 7, plus "Pick a database"

    def test_transient_item_add_failure_is_retried(self):
        b = copy.deepcopy(BOARD)
        b["fail"] = {"project item-add": 2}
        self.board(b)
        rc, out, err = self.run_tool("sync", self.spec_path, "--apply")
        self.assertEqual(rc, 0, out + err)
        self.assertIn("retry 1/4: gh project item-add", err)
        self.assertIn("VERIFY OK", out)

    def test_persistent_failure_stops_with_the_gh_message(self):
        b = copy.deepcopy(BOARD)
        b["fail"] = {"project item-add": 99}
        self.board(b)
        rc, out, err = self.run_tool("sync", self.spec_path, "--apply")
        self.assertEqual(rc, 2)
        self.assertIn("gh project item-add 1 failed after 5 attempts: GraphQL: transient", err)


class Refusals(Case):
    def refused(self, spec=None, board=None, apply=True):
        if spec is not None:
            self.spec(spec)
        if board is not None:
            self.board(board)
        args = ["sync", self.spec_path] + (["--apply"] if apply else [])
        rc, out, err = self.run_tool(*args)
        self.assertEqual(rc, 2, out + err)
        self.assertEqual(self.writes(), [], "a refused spec must not write anything")
        return err

    def test_reserved_field_name(self):
        spec = copy.deepcopy(SPEC)
        spec["fields"]["Type"] = spec["fields"].pop("Kind")
        err = self.refused(spec)
        self.assertIn("field 'Type': the name is reserved by GitHub", err)
        self.assertEqual(self.calls(), [], "spec errors are found before calling gh")

    def test_value_not_in_the_spec_options(self):
        spec = copy.deepcopy(SPEC)
        spec["items"][0]["fields"]["MVP"] = "Maybe"
        self.assertIn("MVP='Maybe' is not one of ['MVP', 'Post-MVP']", self.refused(spec))

    def test_status_value_the_board_does_not_have(self):
        spec = copy.deepcopy(SPEC)
        spec["items"][3]["fields"]["Status"] = "Todo"
        err = self.refused(spec)
        self.assertIn("Status='Todo' is not an option on the board", err)
        self.assertIn("refused before any write", err)

    def test_existing_field_missing_options_is_not_edited(self):
        b = copy.deepcopy(BOARD)
        b["fields"].append({"id": "F_MVP", "name": "MVP", "type": "ProjectV2SingleSelectField",
                            "options": [{"id": "x", "name": "MVP"}]})
        err = self.refused(board=b)
        self.assertIn("field 'MVP' exists without options ['Post-MVP']", err)

    def test_text_value_under_fields(self):
        spec = copy.deepcopy(SPEC)
        spec["items"][1]["fields"]["Depends on"] = "#4"
        self.assertIn("'Depends on' is a text field; put it under 'text'", self.refused(spec))

    def test_duplicate_item(self):
        spec = copy.deepcopy(SPEC)
        spec["items"].append(copy.deepcopy(spec["items"][1]))
        self.assertIn("duplicate of an earlier item", self.refused(spec))

    def test_item_with_both_pr_and_issue(self):
        spec = copy.deepcopy(SPEC)
        spec["items"][0]["issue"] = 5
        self.assertIn("give exactly one of 'pr', 'issue' or 'title'", self.refused(spec))

    def test_missing_scope_names_the_fix(self):
        b = copy.deepcopy(BOARD)
        b["missing_scope"] = True
        err = self.refused(board=b, apply=False)
        self.assertIn("gh auth refresh -h github.com -s project", err)


class Verify(Case):
    def drift(self, field, value):
        self.assertEqual(self.run_tool("sync", self.spec_path, "--apply")[0], 0)
        st = self.state_now()
        next(i for i in st["items"] if i["title"] == "Pick a database")[field] = value
        self.board(st)

    def test_drift_on_the_board_is_reported(self):
        self.drift("mVP", "Post-MVP")
        rc, out, _ = self.run_tool("verify", self.spec_path)
        self.assertEqual(rc, 1)
        self.assertIn("VERIFY FAIL 'Pick a database': MVP is 'Post-MVP', spec says 'MVP'", out)

    def test_strict_checks_board_owned_status(self):
        self.drift("status", "Backlog")
        rc, out, _ = self.run_tool("verify", self.spec_path)
        self.assertEqual(rc, 0, out)
        rc, out, _ = self.run_tool("verify", self.spec_path, "--strict")
        self.assertEqual(rc, 1)
        self.assertIn("VERIFY FAIL 'Pick a database': Status is 'Backlog', spec says 'Ready'",
                      out)

    def test_missing_item_is_reported(self):
        rc, out, _ = self.run_tool("verify", self.spec_path)
        self.assertEqual(rc, 1)
        self.assertIn("VERIFY FAIL pr #4: expected 1 board item, found 0", out)

    def test_empty_spec_is_not_a_pass(self):
        spec = copy.deepcopy(SPEC)
        spec["items"] = []
        self.spec(spec)
        rc, out, _ = self.run_tool("verify", self.spec_path)
        self.assertEqual(rc, 1)
        self.assertIn("nothing was verified", out)


class Views(Case):
    def with_view(self, **change):
        spec = copy.deepcopy(SPEC)
        spec["views"] = [dict(VIEW, **change)]
        self.spec(spec)

    def test_dry_run_plans_the_view_without_writing(self):
        self.with_view()
        rc, out, err = self.run_tool("sync", self.spec_path)
        self.assertEqual(rc, 0, err)
        self.assertIn("[dry run] create view: 'MVP progress' (board, filter 'mvp:MVP')", out)
        self.assertEqual(self.writes(), [])

    def test_apply_creates_the_view_once_with_fields_and_filter(self):
        self.with_view()
        rc, out, err = self.run_tool("sync", self.spec_path, "--apply")
        self.assertEqual(rc, 0, out + err)
        self.assertIn("VERIFY OK: 4 items, 1 views, 13 values match", out)
        views = self.state_now()["views"]
        self.assertEqual(len(views), 1)
        self.assertEqual((views[0]["layout"], views[0]["filter"]), ("BOARD_LAYOUT", "mvp:MVP"))
        self.assertEqual(views[0]["fieldIds"], ["F_Title", "F_Status", "F_Kind", "F_Depends on"])
        os.remove(self.log)
        rc, out, err = self.run_tool("sync", self.spec_path, "--apply")
        self.assertEqual(rc, 0, out + err)
        self.assertIn("view on board: 'MVP progress'", out)
        self.assertEqual(self.writes(), [])

    def test_view_field_that_will_not_exist_is_refused(self):
        self.with_view(fields=["Title", "Owner"])
        rc, _, err = self.run_tool("sync", self.spec_path, "--apply")
        self.assertEqual(rc, 2)
        self.assertIn("view 'MVP progress': field 'Owner' is neither on the board nor in the spec",
                      err)
        self.assertEqual(self.writes(), [])

    def test_unknown_layout_is_refused(self):
        self.with_view(layout="kanban")
        rc, _, err = self.run_tool("sync", self.spec_path, "--apply")
        self.assertEqual(rc, 2)
        self.assertIn("layout must be one of ['board', 'roadmap', 'table']", err)
        self.assertEqual(self.calls(), [])

    def test_verify_reports_a_missing_view_and_strict_filter_drift(self):
        self.with_view()
        self.assertEqual(self.run_tool("sync", self.spec_path, "--apply")[0], 0)
        st = self.state_now()
        st["views"][0]["filter"] = "mvp:Post-MVP"
        self.board(st)
        self.assertEqual(self.run_tool("verify", self.spec_path)[0], 0)
        rc, out, _ = self.run_tool("verify", self.spec_path, "--strict")
        self.assertEqual(rc, 1)
        self.assertIn("view 'MVP progress': filter is 'mvp:Post-MVP', spec says 'mvp:MVP'", out)
        st["views"] = []
        self.board(st)
        rc, out, _ = self.run_tool("verify", self.spec_path)
        self.assertEqual(rc, 1)
        self.assertIn("VERIFY FAIL view 'MVP progress': not on the board", out)


class Report(Case):
    def test_report_counts_and_moving_items(self):
        self.assertEqual(self.run_tool("sync", self.spec_path, "--apply")[0], 0)
        rc, out, err = self.run_tool("report", "o", "1", "--by", "MVP")
        self.assertEqual(rc, 0, err)
        self.assertIn("demo: 4 items", out)
        self.assertIn("by Status: Backlog 1, Ready 1, In progress 1, Done 1", out)
        self.assertIn("MVP=MVP: 3 items, 1 done — Ready 1, In progress 1", out)
        self.assertIn("[In progress] #100 Build the thing", out)
        self.assertNotIn("Someday idea", out.split("moving")[1])

    def test_report_unknown_field(self):
        rc, _, err = self.run_tool("report", "o", "1", "--by", "Nope")
        self.assertEqual(rc, 2)
        self.assertIn("no field 'Nope' on the board", err)


if __name__ == "__main__":
    unittest.main(verbosity=2)
