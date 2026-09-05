#!/bin/bash
# Tests for bin/agy-review.
#
# Every case asserts a SPECIFIC string that only appears when the check actually ran.
# Silence is never a pass: an empty capture fails the case. The run-path cases drive a
# stub `agy` so they exercise argument assembly and exit-code propagation without a
# network call or an API bill.
#
# Run: bash plugins/antigravity/scripts/test-agy-review.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HERE/../bin/agy-review"

# A failed mktemp would leave TMP empty, scatter fixtures at / and make `rm -rf "$TMP"`
# a very bad line. Refuse to run rather than continue into that.
TMP="$(mktemp -d)" || { echo "FATAL: mktemp -d failed"; exit 1; }
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
  echo "FATAL: mktemp -d produced no usable directory (got '${TMP}')"
  exit 1
fi
trap 'rm -rf "$TMP"' EXIT

# STUB_ARGV is fixed to a path inside TMP before any test runs, and is never taken from
# the caller's environment — run_bin deletes this file, and an inherited value would
# make the suite delete something of the caller's on its very first case.
STUB_ARGV="$TMP/argv.bin"
export STUB_ARGV

pass=0
fail=0

note_pass() { echo "ok    $1"; pass=$((pass + 1)); }
note_fail() { echo "FAIL  $1"; fail=$((fail + 1)); }

# run_bin -- runs $BIN with the given args. Streams are captured SEPARATELY: a wrapper
# that printed the review to stderr must not be able to satisfy a stdout assertion.
run_bin() {
  # Drop any previous argv capture so a stale one cannot satisfy this run's assertions.
  case "$STUB_ARGV" in
    "$TMP"/*) rm -f "$STUB_ARGV" ;;
    *) echo "FATAL: refusing to delete $STUB_ARGV, outside $TMP"; exit 1 ;;
  esac
  python3 "$BIN" "$@" >"$TMP/.stdout" 2>"$TMP/.stderr"
  RC=$?
  STDOUT="$(cat "$TMP/.stdout")"
  STDERR="$(cat "$TMP/.stderr")"
  OUT="$STDOUT$STDERR"
}

# expect_fail NAME EXPECTED_EXIT EXPECTED_SUBSTRING -- args...
# The exit code is part of the contract: 1 = run failed/incomplete, 2 = usage/setup error.
expect_fail() {
  local name="$1" want_rc="$2" want="$3"; shift 3
  run_bin "$@"
  if [ -z "$STDERR" ]; then
    note_fail "$name: stderr empty — the check produced no diagnosis"
  elif [ -n "$STDOUT" ]; then
    # A failure must print nothing on stdout: partial review text there would be
    # indistinguishable from a real review to anything consuming this tool.
    note_fail "$name: stdout was not empty on failure — ${STDOUT:0:120}"
  elif printf '%s' "$STDERR" | grep -q 'Traceback (most recent call last)'; then
    note_fail "$name: died with a traceback instead of a clean diagnosis"
  elif [ "$RC" -eq 0 ]; then
    note_fail "$name: exited 0, should have failed"
  elif [ "$RC" -ne "$want_rc" ]; then
    note_fail "$name: exit $RC, expected $want_rc — got: ${STDERR:0:120}"
  elif ! printf '%s' "$STDERR" | grep -q -- "$want"; then
    note_fail "$name: exit $RC but message lacked '$want' — got: ${STDERR:0:160}"
  else
    note_pass "$name"
  fi
}

# The stub records argv NUL-delimited, so an argument containing newlines (every real
# review prompt) keeps its boundaries. Line-based matching cannot do that, and cannot
# check ordering or the absence of an extra flag either.
#
# An argv assertion is only meaningful if the capture exists. Without this guard, a
# missing capture makes every match fail, which argv_lacks would read as "absent" — the
# same silence-passes bug this suite exists to prevent.
argv_capture_ok() {
  local name="$1"
  if [ ! -s "$STUB_ARGV" ]; then
    note_fail "$name: no argv capture at $STUB_ARGV — the stub never ran"
    return 1
  fi
  return 0
}

# argv_equals NAME EXPECTED... -- the COMPLETE argument vector, in order.
# This is the strong assertion: it catches a missing prompt, a scrambled flag/value
# pair, a stripped trailing newline, and an extra flag such as
# --dangerously-skip-permissions, none of which membership checks can see.
argv_equals() {
  local name="$1"; shift
  argv_capture_ok "$name" || return
  if ARGV_FILE="$STUB_ARGV" python3 - "$@" <<'PY'
import os, sys
want = sys.argv[1:]
got = open(os.environ["ARGV_FILE"], "rb").read().split(b"\0")
if got and got[-1] == b"":
    got.pop()
got = [a.decode("utf-8", "surrogateescape") for a in got]
if got == want:
    raise SystemExit(0)
print(f"  argv mismatch\n    want ({len(want)}): {want!r}\n    got  ({len(got)}): {got!r}",
      file=sys.stderr)
raise SystemExit(1)
PY
  then
    note_pass "$name"
  else
    note_fail "$name: argv did not match exactly"
  fi
}

# argv_has NAME EXPECTED... -- every string must appear as its own argv entry
argv_has() {
  local name="$1"; shift
  argv_capture_ok "$name" || return
  local missing=""
  for want in "$@"; do
    ARGV_FILE="$STUB_ARGV" python3 -c '
import os, sys
got = open(os.environ["ARGV_FILE"], "rb").read().split(b"\0")
sys.exit(0 if sys.argv[1].encode() in got else 1)' "$want" || missing="$missing $want"
  done
  if [ -n "$missing" ]; then
    note_fail "$name: argv missing:$missing"
  else
    note_pass "$name"
  fi
}

# argv_lacks NAME UNEXPECTED...
argv_lacks() {
  local name="$1"; shift
  argv_capture_ok "$name" || return
  local present=""
  for bad in "$@"; do
    ARGV_FILE="$STUB_ARGV" python3 -c '
import os, sys
got = open(os.environ["ARGV_FILE"], "rb").read().split(b"\0")
sys.exit(0 if sys.argv[1].encode() in got else 1)' "$bad" && present="$present $bad"
  done
  if [ -n "$present" ]; then
    note_fail "$name: argv unexpectedly contained:$present"
  else
    note_pass "$name"
  fi
}

# expect_pass NAME EXPECTED_EXACT_STDOUT -- args...
# The review must arrive on STDOUT, complete and byte-for-byte. A substring match would
# accept a truncated review, and a merged capture would accept one printed to stderr.
expect_pass() {
  local name="$1" want="$2"; shift 2
  run_bin "$@"
  if [ -z "$STDOUT" ]; then
    note_fail "$name: stdout empty — nothing was printed as the review"
  elif [ "$RC" -ne 0 ]; then
    note_fail "$name: exit $RC, should have passed — ${OUT:0:160}"
  elif [ "$STDOUT" != "$want" ]; then
    note_fail "$name: stdout differed
      want: $(printf '%q' "$want")
      got:  $(printf '%q' "$STDOUT")"
  else
    note_pass "$name"
  fi
}

# --- envelope fixtures, each one a failure shape observed from a real agy run ---------

: > "$TMP/zero-byte.json"
printf '%s' 'not json at all' > "$TMP/garbage.json"
printf '%s' 'null' > "$TMP/json-null.json"
printf '%s' '[1,2,3]' > "$TMP/json-array.json"

cat > "$TMP/denied.json" <<'EOF'
{"conversation_id":"x","status":"SUCCESS","response":"",
 "denied_actions":[{"action":"command","display_name":"RunCommand"}]}
EOF

cat > "$TMP/empty-response.json" <<'EOF'
{"conversation_id":"x","status":"SUCCESS","response":"","num_turns":1}
EOF

cat > "$TMP/whitespace-response.json" <<'EOF'
{"conversation_id":"x","status":"SUCCESS","response":"   \n  \n","num_turns":1}
EOF

cat > "$TMP/null-response.json" <<'EOF'
{"conversation_id":"x","status":"SUCCESS","response":null}
EOF

cat > "$TMP/error-status.json" <<'EOF'
{"conversation_id":"","status":"ERROR","response":"",
 "error":"invalid model selection (--model \"nope\"): model nope is not recognized"}
EOF

cat > "$TMP/token-limit.json" <<'EOF'
{"conversation_id":"x","status":"ERROR","response":"",
 "error":"Your previous response was cut off because it exceeded the output token limit."}
EOF

# The positive fixtures carry the FULL envelope agy really emits, so a test can never
# pass by accident on a shape agy would never produce.
cat > "$TMP/good.json" <<'EOF'
{"conversation_id":"8849d232-d82b-454f-b31e-fe23d47b3d6b","status":"SUCCESS",
 "response":"### Finding 1\nSomething is wrong at foo.py:12\n",
 "duration_seconds":2.62,"num_turns":1,
 "usage":{"input_tokens":13282,"output_tokens":2,"thinking_tokens":0,
          "cache_read_tokens":0,"total_tokens":13284}}
EOF
GOOD_STDOUT='### Finding 1
Something is wrong at foo.py:12'

cat > "$TMP/good-no-findings.json" <<'EOF'
{"conversation_id":"8849d232-d82b-454f-b31e-fe23d47b3d6b","status":"SUCCESS",
 "response":"NO FINDINGS\n","duration_seconds":1.01,"num_turns":1,
 "usage":{"input_tokens":5141,"output_tokens":1,"thinking_tokens":0,
          "cache_read_tokens":8128,"total_tokens":5142}}
EOF

cat > "$TMP/bool-response.json" <<'EOF'
{"conversation_id":"x","status":"SUCCESS","response":true}
EOF

# A mistyped `usage` must be refused, not crash after a good review has been produced.
cat > "$TMP/usage-string.json" <<'EOF'
{"conversation_id":"x","status":"SUCCESS","response":"NO FINDINGS\n","usage":"bad"}
EOF

# Non-ASCII must survive a C locale: agy writes UTF-8 regardless of the environment.
cat > "$TMP/utf8.json" <<'EOF'
{"conversation_id":"x","status":"SUCCESS","response":"Finding 1 — cấu hình → hỏng\n",
 "duration_seconds":1.0,"num_turns":1,"usage":{"total_tokens":10}}
EOF

# Both shapes a real successful run produces for denied_actions.
cat > "$TMP/denied-null.json" <<'EOF'
{"conversation_id":"x","status":"SUCCESS","response":"NO FINDINGS\n","denied_actions":null}
EOF
cat > "$TMP/denied-empty.json" <<'EOF'
{"conversation_id":"x","status":"SUCCESS","response":"NO FINDINGS\n","denied_actions":[]}
EOF

# Leading whitespace is content — a markdown code block starts with it. The wrapper must
# not "tidy" the reviewer's words; that is the rule the whole plugin exists to enforce.
cat > "$TMP/indented.json" <<'EOF'
{"conversation_id":"x","status":"SUCCESS","response":"    indented finding\n"}
EOF

# Pathologically nested JSON must produce a diagnosis, not a RecursionError traceback.
python3 -c '
import sys
n = 20000
open(sys.argv[1], "w").write("[" * n + "]" * n)' "$TMP/deep.json"

# --- --check cases -------------------------------------------------------------------

expect_fail "zero-byte output file"    1 "empty output file"       --check "$TMP/zero-byte.json"
expect_fail "non-JSON output"          1 "not JSON"                --check "$TMP/garbage.json"
expect_fail "JSON null, not an object" 1 "not a JSON object"       --check "$TMP/json-null.json"
expect_fail "JSON array, not object"   1 "not a JSON object"       --check "$TMP/json-array.json"
expect_fail "non-string response"      1 "not a string"            --check "$TMP/bool-response.json"
expect_fail "tools auto-denied"        1 "auto-denied"             --check "$TMP/denied.json"
expect_fail "empty response"           1 "empty response"          --check "$TMP/empty-response.json"
expect_fail "whitespace-only response" 1 "empty response"          --check "$TMP/whitespace-response.json"
expect_fail "null response"            1 "empty response"          --check "$TMP/null-response.json"
expect_fail "status=ERROR"             1 "invalid model selection" --check "$TMP/error-status.json"
expect_fail "output token limit"       1 "output token limit"      --check "$TMP/token-limit.json"
expect_fail "missing file"             1 "cannot read"             --check "$TMP/nope.json"
# `usage` is cosmetic: a wrong type must neither crash nor discard a complete review.
expect_pass "mistyped usage still yields the review" "NO FINDINGS" \
  --check "$TMP/usage-string.json"
if printf '%s' "$STDERR" | grep -q "usage. is str, not an object"; then
  note_pass "mistyped usage warns on stderr"
else
  note_fail "mistyped usage did not warn — got: ${STDERR:0:120}"
fi

# --check is about an existing envelope; run options alongside it mean a mistyped command
expect_fail "--check with a prompt file"  2 "takes no run options" \
  --check "$TMP/good.json" "$TMP/prompt.txt"
expect_fail "--check with --out"          2 "takes no run options" \
  --check "$TMP/good.json" --out "$TMP/somewhere"

expect_fail "deeply nested JSON"       1 "nested too deeply"       --check "$TMP/deep.json"

expect_pass "real review"              "$GOOD_STDOUT"            --check "$TMP/good.json"
expect_pass "NO FINDINGS is a result"  "NO FINDINGS"             --check "$TMP/good-no-findings.json"
expect_pass "non-ASCII response"       "Finding 1 — cấu hình → hỏng" --check "$TMP/utf8.json"
expect_pass "denied_actions null is a success shape"  "NO FINDINGS" --check "$TMP/denied-null.json"
expect_pass "denied_actions [] is a success shape"    "NO FINDINGS" --check "$TMP/denied-empty.json"
expect_pass "leading whitespace is preserved verbatim" "    indented finding" \
  --check "$TMP/indented.json"

# The response must survive an ASCII locale — agy's output is UTF-8 either way.
LC_ALL=C PYTHONUTF8=0 expect_pass "non-ASCII response under LC_ALL=C" \
  "Finding 1 — cấu hình → hỏng" --check "$TMP/utf8.json"

# --- run-path cases, driven by a stub agy --------------------------------------------

STUB="$TMP/stub-agy"
cat > "$STUB" <<'EOF'
#!/bin/bash
# Records its argv NUL-delimited so arguments containing newlines keep their boundaries,
# then emits whatever the fixture files dictate.
printf '%s\0' "$@" > "$STUB_ARGV"
cat "$STUB_STDOUT"
[ -n "${STUB_STDERR:-}" ] && cat "$STUB_STDERR" >&2
exit "${STUB_RC:-0}"
EOF
chmod +x "$STUB"

export STUB_STDOUT="$TMP/good.json"
export STUB_RC=0

# A realistic prompt: several lines, a blank line, and a trailing newline. The
# single-line prompt that used to be here made the -p assertions pass for the wrong
# reason — line-based matching cannot survive an embedded newline.
printf 'Review the diff below.\n\n--- a/foo.py\n+++ b/foo.py\n@@ -1 +1 @@\n-old\n+new\n' \
  > "$TMP/prompt.txt"
: > "$TMP/empty-prompt.txt"

printf 'review\0this' > "$TMP/nul-prompt.txt"

expect_fail "missing prompt file"  2 "prompt file not found" "$TMP/no-such-prompt.txt"
expect_fail "empty prompt file"    2 "prompt file is empty"  "$TMP/empty-prompt.txt"
expect_fail "no prompt file given" 2 "usage:"                --model gemini-3.8-flash
expect_fail "bad --agy path"       2 "not found or not executable" \
  --agy "$TMP/nope-binary" "$TMP/prompt.txt"

# a NUL cannot cross exec(); rejecting it here beats a ValueError from inside subprocess
expect_fail "NUL byte in prompt"   2 "NUL byte" \
  --agy "$STUB" --out "$TMP/run-nul" "$TMP/nul-prompt.txt"

# --out must not be silently turned into, or clobber, something that already exists
expect_fail "--out is an existing file" 2 "cannot use output directory" \
  --agy "$STUB" --out "$TMP/prompt.txt" "$TMP/prompt.txt"

mkdir -p "$TMP/run-collide"
: > "$TMP/run-collide/out.json"
expect_fail "--out already holds a report" 2 "already exists" \
  --agy "$STUB" --out "$TMP/run-collide" "$TMP/prompt.txt"

expect_pass "run path prints review" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run1" "$TMP/prompt.txt"

# The whole invocation contract, in order and with nothing extra. `agy -p` does not read
# stdin, so the prompt must arrive as the argument right after -p, with its trailing
# newline intact — and no surprise flag such as --dangerously-skip-permissions may appear.
# `$(cat)` would strip the trailing newline, so read the file in a way that keeps it.
PROMPT_ARG="$(cat "$TMP/prompt.txt"; printf x)"; PROMPT_ARG="${PROMPT_ARG%x}"
argv_equals "full argv: -p, the exact prompt, and nothing unexpected" \
  "-p" "$PROMPT_ARG" \
  "--model" "gemini-3.8-flash" \
  "--disable-slash-commands" \
  "--output-format" "json" \
  "--print-timeout" "9m" \
  "--effort" "high"

# a suffixed id must NOT get --effort (agy: "conflicts with --effort=high"),
# but the model itself must still be forwarded
expect_pass "suffixed model runs" "$GOOD_STDOUT" \
  --agy "$STUB" --model gemini-3.8-flash-high --out "$TMP/run2" "$TMP/prompt.txt"
argv_has   "suffixed id still forwards --model" "--model" "gemini-3.8-flash-high"
argv_lacks "--effort suppressed for gemini-3.8-flash-high" "--effort"

# a Claude id must NOT get --effort (agy: "--effort is not supported for model ...")
expect_pass "claude model runs" "$GOOD_STDOUT" \
  --agy "$STUB" --model claude-opus-4-6-thinking --out "$TMP/run3" "$TMP/prompt.txt"
argv_has   "claude id still forwards --model" "--model" "claude-opus-4-6-thinking"
argv_lacks "--effort suppressed for claude-opus-4-6-thinking" "--effort"

# an explicit --effort is passed through even for a model that will reject it,
# so agy's own error surfaces instead of being silently dropped
expect_pass "explicit --effort passed through" "$GOOD_STDOUT" \
  --agy "$STUB" --model claude-sonnet-4-6 --effort low --out "$TMP/run4" "$TMP/prompt.txt"
argv_has "explicit --effort low reaches agy" "--model" "claude-sonnet-4-6" "--effort" "low"

# ...and when agy rejects that combination, the error reaches the user rather than
# being swallowed. This is the behaviour the pass-through exists for.
cat > "$TMP/effort-rejected.json" <<'EOF'
{"conversation_id":"","status":"ERROR","response":"",
 "error":"invalid model selection (--model \"claude-sonnet-4-6\" --effort \"low\"): --effort is not supported for model \"claude-sonnet-4-6\""}
EOF
STUB_RC=1 STUB_STDOUT="$TMP/effort-rejected.json" \
  expect_fail "rejected --effort surfaces agy's error" 1 "not supported for model" \
  --agy "$STUB" --model claude-sonnet-4-6 --effort low --out "$TMP/run4b" "$TMP/prompt.txt"

# a bare binary name for --agy is resolved through PATH, not treated as ./agy
PATH="$TMP:$PATH" expect_pass "bare --agy name resolves via PATH" "$GOOD_STDOUT" \
  --agy "stub-agy" --out "$TMP/run8" "$TMP/prompt.txt"

# exit-code propagation: a non-zero agy exit must be reported with its code,
# not masked by an envelope complaint
STUB_RC=3 STUB_STDOUT="$TMP/zero-byte.json" \
  expect_fail "non-zero agy exit is reported" 1 "agy exited 3" \
  --agy "$STUB" --out "$TMP/run5" "$TMP/prompt.txt"

STUB_RC=1 STUB_STDOUT="$TMP/error-status.json" \
  expect_fail "non-zero exit surfaces the envelope error" 1 "invalid model selection" \
  --agy "$STUB" --out "$TMP/run6" "$TMP/prompt.txt"

STUB_RC=0 STUB_STDOUT="$TMP/denied.json" \
  expect_fail "denied tools fail even on exit 0" 1 "auto-denied" \
  --agy "$STUB" --out "$TMP/run7" "$TMP/prompt.txt"

# --- the default output location, which no --out run can exercise --------------------
# Replacing the private mkdtemp with a predictable shared path must not stay green.
expect_pass "run with no --out" "$GOOD_STDOUT" --agy "$STUB" "$TMP/prompt.txt"
DEFAULT_OUT="$(printf '%s' "$STDERR" | sed -n 's/^raw output: \(.*\)\/out\.json$/\1/p')"
if [ -z "$DEFAULT_OUT" ] || [ ! -d "$DEFAULT_OUT" ]; then
  note_fail "default --out: could not find the reported directory in stderr"
else
  dmode="$(stat -f '%Lp' "$DEFAULT_OUT" 2>/dev/null || stat -c '%a' "$DEFAULT_OUT")"
  fmode="$(stat -f '%Lp' "$DEFAULT_OUT/out.json" 2>/dev/null || stat -c '%a' "$DEFAULT_OUT/out.json")"
  if [ "$dmode" = "700" ]; then
    note_pass "default output directory is 0700"
  else
    note_fail "default output directory is $dmode, expected 700"
  fi
  if [ "$fmode" = "600" ]; then
    note_pass "report files are 0600"
  else
    note_fail "report files are $fmode, expected 600"
  fi
  case "$DEFAULT_OUT" in
    */agy-review-*) note_pass "default output directory is a fresh mkdtemp" ;;
    *) note_fail "default output directory is not a mkdtemp path: $DEFAULT_OUT" ;;
  esac
  rm -rf "$DEFAULT_OUT"
fi

# a world-readable --out must still produce 0600 files, and must say so
mkdir -p "$TMP/public-out"
chmod 0755 "$TMP/public-out"
expect_pass "public --out still writes 0600 files" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/public-out" "$TMP/prompt.txt"
pfmode="$(stat -f '%Lp' "$TMP/public-out/out.json" 2>/dev/null || stat -c '%a' "$TMP/public-out/out.json")"
if [ "$pfmode" = "600" ]; then
  note_pass "report file in a public directory is still 0600"
else
  note_fail "report file in a public directory is $pfmode, expected 600"
fi
if printf '%s' "$STDERR" | grep -q "other local users can list it"; then
  note_pass "public --out is warned about"
else
  note_fail "public --out produced no warning"
fi

# --- meta-tests: prove each helper can actually go red -------------------------------
# Without these, a crashing binary or a mis-wired assertion would make cases pass by
# accident — which is exactly the defect this suite exists to catch in agy itself.

# meta_expect_red DESCRIPTION -- <a deliberately wrong assertion>
meta_expect_red() {
  local what="$1"; shift
  local before_fail=$fail before_pass=$pass
  "$@" >/dev/null 2>&1
  if [ "$fail" -eq $((before_fail + 1)) ]; then
    fail=$before_fail          # the deliberate failure is the expected result
    note_pass "meta: $what"
  else
    # The inner assertion wrongly passed, so it incremented $pass; undo that or the
    # summary counts a broken test as a good one.
    pass=$before_pass
    note_fail "meta: $what — the harness did NOT detect it; every result is suspect"
  fi
}

# Seed a known argv capture so the content meta-tests exercise the MATCHING logic.
# Without this they run against a capture that run_bin has just deleted, and fail at
# argv_capture_ok instead — proving the guard works, but never the matching.
seed_argv() {
  printf '%s\0' "--model" "gemini-3.8-flash" "-p" "hello" > "$STUB_ARGV"
}

meta_expect_red "expect_pass rejects a denied envelope" \
  expect_pass "META" "$GOOD_STDOUT" --check "$TMP/denied.json"

meta_expect_red "expect_fail rejects the wrong exit code" \
  expect_fail "META" 99 "empty output file" --check "$TMP/zero-byte.json"

meta_expect_red "expect_fail rejects the wrong message" \
  expect_fail "META" 1 "this string never appears" --check "$TMP/zero-byte.json"

seed_argv
meta_expect_red "argv_has notices a missing argument" \
  argv_has "META" "--this-flag-was-never-passed"

seed_argv
meta_expect_red "argv_lacks notices an argument that is present" \
  argv_lacks "META" "--model"

seed_argv
meta_expect_red "argv_equals notices a wrong argument vector" \
  argv_equals "META" "--model" "gemini-3.8-flash"

seed_argv
meta_expect_red "argv_equals notices a reordered vector" \
  argv_equals "META" "gemini-3.8-flash" "--model" "-p" "hello"

# The subtle one: with no capture at all, every match fails, which a naive argv_lacks
# would read as "the argument is absent" and pass. It must fail instead.
STUB_ARGV="$TMP/no-such-argv.txt" meta_expect_red \
  "argv_lacks fails when the capture is missing" \
  argv_lacks "META" "--model"
STUB_ARGV="$TMP/no-such-argv.txt" meta_expect_red \
  "argv_has fails when the capture is missing" \
  argv_has "META" "--model"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
