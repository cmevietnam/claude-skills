#!/usr/bin/env bash
# Mutation harness for bin/deepseek-review: proves each guard is pinned by its own case of
# test-deepseek-review.sh. The mutants live in fixtures/mutants.py; this entry point checks the
# tree's wrapper is never written (sha256 before and after) and runs them.
#
# usage: mutate-deepseek-review.sh WORK_DIR [--jobs N] [--only ERE] [--phase all|parallel|serial]
#   WORK_DIR   a path that does not exist yet; copies and logs go there
#   DSH_REAL_DIR (env) a real dsh install, needed by the doctor mutants (real=True)
#
# Exit 0 only when every mutant is CAUGHT by its own case (or is a declared equivalent that
# stayed green) and the tree's wrapper is byte-identical at the end.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wrapper="$here/../bin/deepseek-review"
[ $# -ge 1 ] || { echo "usage: $0 WORK_DIR [--jobs N] [--only ERE] [--phase all|parallel|serial]" >&2; exit 2; }
work="$1"; shift
[ ! -e "$work" ] || { echo "FATAL: $work already exists" >&2; exit 2; }
py=/usr/bin/python3
[ -x "$py" ] || py="$(command -v python3)"
before="$(shasum -a 256 "$wrapper" | cut -d' ' -f1)"
rc=0
PYTHONDONTWRITEBYTECODE=1 "$py" "$here/fixtures/mutants.py" --work "$work" "$@" || rc=$?
after="$(shasum -a 256 "$wrapper" | cut -d' ' -f1)"
if [ "$before" != "$after" ]; then
  echo "FAIL: tree wrapper sha256 changed: $before -> $after" >&2
  exit 1
fi
echo "tree wrapper sha256 before and after: $after"
exit "$rc"
