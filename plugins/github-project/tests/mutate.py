"""Sabotage each guard in bin/gh-roadmap and require the test that owns it to go red.

Each mutation is applied to a copy in a temp dir (never to the real file). A mutation whose
target text no longer exists is a FAIL, not a skip: a refactor must not silently retire a proof.

Run: python3 tests/mutate.py
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "bin", "gh-roadmap")
SUITE = os.path.join(HERE, "test_gh_roadmap.py")

# name, old text, new text, test that must fail
MUTATIONS = [
    ("dry run writes", "        if not apply:\n            continue\n", "",
     "DryRun.test_dry_run_reads_only_and_prints_the_plan"),
    ("re-applies every value", "            if k not in board_owned and field_value(existing, k) != v}",
     "            if k not in board_owned}", "Apply.test_second_apply_creates_nothing_and_edits_nothing"),
    ("reverts board-owned Status", "            if k not in board_owned and field_value(existing, k) != v}",
     "            if field_value(existing, k) != v}", "Apply.test_status_moved_on_the_board_is_not_reverted"),
    ("strict ignored", "            if k in spec[\"board_owned\"] and not strict and label not in fresh:",
     "            if k in spec[\"board_owned\"] and label not in fresh:", "Verify.test_strict_checks_board_owned_status"),
    ("fresh items' Status unchecked", "            if k in spec[\"board_owned\"] and not strict and label not in fresh:",
     "            if k in spec[\"board_owned\"] and not strict:", "Apply.test_apply_builds_the_board_and_verifies_it"),
    ("no reserved-name check", "        if name.lower() in RESERVED and name != \"Status\":",
     "        if False:", "Refusals.test_reserved_field_name"),
    ("no board check before writes", "    check_against_board(spec, board)\n", "",
     "Refusals.test_status_value_the_board_does_not_have"),
    ("edits existing field options", "        elif have is not None and not set(opts) <= set(have):",
     "        elif False:", "Refusals.test_existing_field_missing_options_is_not_edited"),
    ("issues not matched by title", "            issues.setdefault(i[\"title\"], i)", "            pass",
     "Apply.test_existing_issue_is_matched_by_title_not_duplicated"),
    ("no retry", "RETRIES = int(os.environ.get(\"GH_ROADMAP_RETRIES\", \"4\"))", "RETRIES = 0",
     "Apply.test_transient_item_add_failure_is_retried"),
    ("empty spec passes", "        problems.append(\"the spec has no items: nothing was verified\")",
     "        pass", "Verify.test_empty_spec_is_not_a_pass"),
    ("verify ignores values", "            if got != v:", "            if False:",
     "Verify.test_drift_on_the_board_is_reported"),
    ("duplicates allowed", "            errors.append(f\"{where}: duplicate of an earlier item\")",
     "            pass", "Refusals.test_duplicate_item"),
    ("view created every run", "            if v[\"name\"] in have:\n                counts[\"view on board\"] += 1",
     "            if False:\n                counts[\"view on board\"] += 1",
     "Views.test_apply_creates_the_view_once_with_fields_and_filter"),
    ("view filter not set", "        if v.get(\"filter\"):\n            q = (",
     "        if False:\n            q = (", "Views.test_apply_creates_the_view_once_with_fields_and_filter"),
    ("view fields unchecked", "            if fname not in will_exist:", "            if False:",
     "Views.test_view_field_that_will_not_exist_is_refused"),
    ("missing view passes verify", "            if got is None:\n                problems.append",
     "            if False:\n                problems.append",
     "Views.test_verify_reports_a_missing_view_and_strict_filter_drift"),
    ("scope error not explained", "        if \"missing required scopes\" in last:",
     "        if False:", "Refusals.test_missing_scope_names_the_fix"),
]


def main():
    with open(SRC) as fh:
        original = fh.read()
    failures = 0
    for name, old, new, test in MUTATIONS:
        if original.count(old) != 1:
            print(f"FAIL  {name}: target text found {original.count(old)} times (expected 1)")
            failures += 1
            continue
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "gh-roadmap")
            with open(path, "w") as fh:
                fh.write(original.replace(old, new))
            env = dict(os.environ, GH_ROADMAP_TOOL=path)
            r = subprocess.run([sys.executable, SUITE, test], capture_output=True, text=True,
                               env=env)
        ran = "Ran 1 test" in r.stderr
        if not ran:
            print(f"FAIL  {name}: {test} did not run\n{r.stderr[-400:]}")
            failures += 1
        elif r.returncode == 0:
            print(f"FAIL  {name}: {test} stayed green with the guard removed")
            failures += 1
        else:
            print(f"ok    {name}: {test} went red")
    print(f"{len(MUTATIONS) - failures}/{len(MUTATIONS)} mutations caught")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
