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

# One line per `agy models` call the stub answers, so a test can prove the pinned default
# never asks for the listing — which no argv assertion can show.
STUB_MODELS_CALLS="$TMP/models-calls.txt"
export STUB_MODELS_CALLS
: > "$STUB_MODELS_CALLS"

# One line per review call, so a retry ladder can be counted. The stub also writes
# "$STUB_ARGV.<n>" per attempt, which is what ARGV_FILE_OVERRIDE points the argv
# assertions at when a case cares about an attempt other than the last.
STUB_CALLS="$TMP/review-calls.txt"
export STUB_CALLS
: > "$STUB_CALLS"

pass=0
fail=0

note_pass() { echo "ok    $1"; pass=$((pass + 1)); }
note_fail() { echo "FAIL  $1"; fail=$((fail + 1)); }

# run_bin -- runs $BIN with the given args. Streams are captured SEPARATELY: a wrapper
# that printed the review to stderr must not be able to satisfy a stdout assertion.
run_bin() {
  # Drop any previous argv capture so a stale one cannot satisfy this run's assertions.
  case "$STUB_ARGV" in
    "$TMP"/*) rm -f "$STUB_ARGV" "$STUB_ARGV".[0-9] ;;
    *) echo "FATAL: refusing to delete $STUB_ARGV, outside $TMP"; exit 1 ;;
  esac
  python3 "$BIN" "$@" >"$TMP/.stdout" 2>"$TMP/.stderr"
  RC=$?
  # `$(cat f)` strips ALL trailing newlines, which would hide exactly the kind of
  # trailing-newline corruption these tests exist to catch. The `printf x` trick keeps
  # the bytes intact.
  STDOUT="$(cat "$TMP/.stdout"; printf x)"; STDOUT="${STDOUT%x}"
  STDERR="$(cat "$TMP/.stderr"; printf x)"; STDERR="${STDERR%x}"
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
# Which capture the argv assertions read: the last review call by default, or one
# attempt of a retry ladder when ARGV_FILE_OVERRIDE names it.
argv_file() { printf '%s' "${ARGV_FILE_OVERRIDE:-$STUB_ARGV}"; }

argv_capture_ok() {
  local name="$1"
  if [ ! -s "$(argv_file)" ]; then
    note_fail "$name: no argv capture at $(argv_file) — the stub never ran that far"
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
  if ARGV_FILE="$(argv_file)" python3 - "$@" <<'PY'
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
    ARGV_FILE="$(argv_file)" python3 -c '
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
    ARGV_FILE="$(argv_file)" python3 -c '
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

# expect_stderr NAME PATTERN -- the last run's stderr must contain PATTERN.
# For diagnostics that accompany a SUCCESSFUL run (a fallback warning, the model line),
# which expect_pass deliberately ignores because it only looks at stdout.
expect_stderr() {
  local name="$1" want="$2"
  if [ -z "$STDERR" ]; then
    note_fail "$name: stderr empty — the wrapper said nothing"
  elif printf '%s' "$STDERR" | grep -q -- "$want"; then
    note_pass "$name"
  else
    note_fail "$name: stderr lacked '$want' — got: ${STDERR:0:200}"
  fi
}

# expect_stderr_absent NAME PATTERN -- the last run's stderr must NOT contain PATTERN.
# Only ever used where a companion case proves the same message CAN appear, since an
# absence on its own cannot tell a working check from one that never ran.
expect_stderr_absent() {
  local name="$1" unwanted="$2"
  if printf '%s' "$STDERR" | grep -q -- "$unwanted"; then
    note_fail "$name: stderr unexpectedly contained '$unwanted'"
  else
    note_pass "$name"
  fi
}

# expect_calls NAME COUNT -- how many review calls the stub answered.
# Reset the counter with `: > "$STUB_CALLS"` before the run being measured.
expect_calls() {
  local name="$1" want="$2" got=0
  if [ -f "$STUB_CALLS" ]; then
    got="$(wc -l < "$STUB_CALLS" | tr -d ' ')"
  fi
  if [ "$got" = "$want" ]; then
    note_pass "$name"
  else
    note_fail "$name: agy ran $got times, expected $want"
  fi
}

# expect_models_calls NAME COUNT -- how many times the stub answered `agy models`.
# Reset the counter with `: > "$STUB_MODELS_CALLS"` before the run being measured.
expect_models_calls() {
  local name="$1" want="$2" got=0
  if [ -f "$STUB_MODELS_CALLS" ]; then
    got="$(wc -l < "$STUB_MODELS_CALLS" | tr -d ' ')"
  fi
  if [ "$got" = "$want" ]; then
    note_pass "$name"
  else
    note_fail "$name: \`agy models\` ran $got times, expected $want"
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
# Byte-exact expected stdout, trailing newline included — the wrapper must not add,
# drop, or normalise one.
GOOD_STDOUT="$(printf '### Finding 1\nSomething is wrong at foo.py:12\n'; printf x)"
GOOD_STDOUT="${GOOD_STDOUT%x}"
# NOT $(printf '\n') — command substitution strips the very newline we need.
NL=$'\n'

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
{"conversation_id":"x","status":"SUCCESS","response":"Finding 1 — café → ошибка → 設定\n",
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
expect_pass "mistyped usage still yields the review" "NO FINDINGS$NL" \
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
expect_pass "NO FINDINGS is a result"  "NO FINDINGS$NL"          --check "$TMP/good-no-findings.json"
expect_pass "non-ASCII response"       "Finding 1 — café → ошибка → 設定$NL" --check "$TMP/utf8.json"
expect_pass "denied_actions null is a success shape"  "NO FINDINGS$NL" --check "$TMP/denied-null.json"
expect_pass "denied_actions [] is a success shape"    "NO FINDINGS$NL" --check "$TMP/denied-empty.json"
expect_pass "leading whitespace is preserved verbatim" "    indented finding$NL" \
  --check "$TMP/indented.json"

# The documented newline contract, both directions: an existing trailing newline is not
# doubled, and a missing one gets exactly one added.
cat > "$TMP/no-trailing-nl.json" <<'EOF'
{"conversation_id":"x","status":"SUCCESS","response":"NO FINDINGS"}
EOF
expect_pass "missing trailing newline gets exactly one" "NO FINDINGS$NL" \
  --check "$TMP/no-trailing-nl.json"

cat > "$TMP/double-nl.json" <<'EOF'
{"conversation_id":"x","status":"SUCCESS","response":"line one\n\n"}
EOF
expect_pass "interior and trailing blank lines survive" "line one$NL$NL" \
  --check "$TMP/double-nl.json"

# The response must survive an ASCII locale — agy's output is UTF-8 either way.
LC_ALL=C PYTHONUTF8=0 expect_pass "non-ASCII response under LC_ALL=C" \
  "Finding 1 — café → ошибка → 設定$NL" --check "$TMP/utf8.json"

# --- run-path cases, driven by a stub agy --------------------------------------------

STUB="$TMP/stub-agy"
cat > "$STUB" <<'EOF'
#!/bin/bash
# `agy models` is a different call shape: a listing on stdout, a progress note on stderr,
# and it happens BEFORE the review. It is counted rather than recorded in $STUB_ARGV,
# which the review call that follows would overwrite anyway.
if [ "${1:-}" = "models" ]; then
  echo "models" >> "$STUB_MODELS_CALLS"
  [ -n "${STUB_MODELS_SLEEP:-}" ] && sleep "$STUB_MODELS_SLEEP"
  [ -n "${STUB_MODELS:-}" ] && cat "$STUB_MODELS"
  [ -n "${STUB_MODELS_ERR:-}" ] && cat "$STUB_MODELS_ERR" >&2
  exit "${STUB_MODELS_RC:-0}"
fi
# Records its argv NUL-delimited so arguments containing newlines keep their boundaries,
# then emits whatever the fixture files dictate. The attempt number picks the fixture, so
# a retry ladder can be driven: STUB_STDOUT_2 answers the second attempt, STUB_STDOUT the
# rest; STUB_RC_<n> does the same for the exit code.
echo "review" >> "$STUB_CALLS"
N="$(wc -l < "$STUB_CALLS" | tr -d ' ')"
printf '%s\0' "$@" > "$STUB_ARGV"
printf '%s\0' "$@" > "$STUB_ARGV.$N"
OUT_VAR="STUB_STDOUT_$N"
RC_VAR="STUB_RC_$N"
cat "${!OUT_VAR:-$STUB_STDOUT}"
[ -n "${STUB_STDERR:-}" ] && cat "$STUB_STDERR" >&2
exit "${!RC_VAR:-${STUB_RC:-0}}"
EOF
chmod +x "$STUB"

export STUB_STDOUT="$TMP/good.json"
export STUB_RC=0

# The listing `agy models` really printed at 1.1.27, verbatim — including the tab before
# each label and the baked-in effort suffix on every id.
cat > "$TMP/models-real.txt" <<'EOF'
gemini-3.8-flash-high	Gemini 3.8 Flash (High)
gemini-3.8-flash-medium	Gemini 3.8 Flash (Medium)
gemini-3.8-flash-low	Gemini 3.8 Flash (Low)
gemini-3.7-flash-high	Gemini 3.7 Flash (High)
gemini-3.7-flash-medium	Gemini 3.7 Flash (Medium)
gemini-3.7-flash-low	Gemini 3.7 Flash (Low)
gemini-3.6-flash-high	Gemini 3.6 Flash (High)
gemini-3.6-flash-medium	Gemini 3.6 Flash (Medium)
gemini-3.6-flash-low	Gemini 3.6 Flash (Low)
gemini-3.1-pro-high	Gemini 3.1 Pro (High)
gemini-3.1-pro-low	Gemini 3.1 Pro (Low)
claude-sonnet-4-6	Claude Sonnet 4.6 (Thinking)
claude-opus-4-6-thinking	Claude Opus 4.6 (Thinking)
gpt-oss-120b-medium	GPT-OSS 120B (Medium)
EOF
export STUB_MODELS="$TMP/models-real.txt"

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

# A pre-existing report must be refused AND left byte-for-byte alone, and the run must
# not have happened at all. An empty fixture could not prove either.
mkdir -p "$TMP/run-collide"
printf 'SENTINEL-OUT-DO-NOT-TOUCH\n' > "$TMP/run-collide/out.json"
expect_fail "--out already holds out.json" 2 "already exists" \
  --agy "$STUB" --out "$TMP/run-collide" "$TMP/prompt.txt"
if [ "$(cat "$TMP/run-collide/out.json")" = "SENTINEL-OUT-DO-NOT-TOUCH" ]; then
  note_pass "existing out.json left untouched"
else
  note_fail "existing out.json was modified: $(cat "$TMP/run-collide/out.json")"
fi
if [ ! -e "$STUB_ARGV" ]; then
  note_pass "collision refused before agy ran"
else
  note_fail "agy was invoked despite the collision"
fi

# err.txt collides too, not just out.json
mkdir -p "$TMP/run-collide2"
printf 'SENTINEL-ERR\n' > "$TMP/run-collide2/err.txt"
expect_fail "--out already holds err.txt" 2 "already exists" \
  --agy "$STUB" --out "$TMP/run-collide2" "$TMP/prompt.txt"
if [ "$(cat "$TMP/run-collide2/err.txt")" = "SENTINEL-ERR" ]; then
  note_pass "existing err.txt left untouched"
else
  note_fail "existing err.txt was modified"
fi

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
argv_equals "suffixed id: full argv, no --effort anywhere" \
  "-p" "$PROMPT_ARG" "--model" "gemini-3.8-flash-high" \
  "--disable-slash-commands" "--output-format" "json" "--print-timeout" "9m"

# a Claude id must NOT get --effort (agy: "--effort is not supported for model ...")
expect_pass "claude model runs" "$GOOD_STDOUT" \
  --agy "$STUB" --model claude-opus-4-6-thinking --out "$TMP/run3" "$TMP/prompt.txt"
argv_equals "claude id: full argv, no --effort anywhere" \
  "-p" "$PROMPT_ARG" "--model" "claude-opus-4-6-thinking" \
  "--disable-slash-commands" "--output-format" "json" "--print-timeout" "9m"

# an explicit --effort is passed through even for a model that will reject it,
# so agy's own error surfaces instead of being silently dropped
expect_pass "explicit --effort passed through" "$GOOD_STDOUT" \
  --agy "$STUB" --model claude-sonnet-4-6 --effort low --out "$TMP/run4" "$TMP/prompt.txt"
argv_equals "explicit --effort is forwarded even to a model that rejects it" \
  "-p" "$PROMPT_ARG" "--model" "claude-sonnet-4-6" \
  "--disable-slash-commands" "--output-format" "json" "--print-timeout" "9m" \
  "--effort" "low"

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

# The nonzero-exit branch has its own JSON read. It must survive the same pathological
# input the --check parser handles, rather than dying with a RecursionError traceback.
STUB_RC=4 STUB_STDOUT="$TMP/deep.json" \
  expect_fail "nested JSON on the nonzero-exit path" 1 "agy exited 4" \
  --agy "$STUB" --out "$TMP/run-deep" "$TMP/prompt.txt"

# An empty option value is a mistake, never a request for the default — otherwise
# `--check "$UNSET_VAR"` silently becomes a real, billed review.
expect_fail "--check with an empty value"  2 "empty value" --check "" "$TMP/prompt.txt"

# NaN parses under json's defaults but is not JSON, and agy never emits it.
cat > "$TMP/nan.json" <<'EOF'
{"conversation_id":"x","status":"SUCCESS","response":"ok","usage":{"total_tokens":NaN}}
EOF
expect_fail "NaN is not JSON" 1 "non-JSON constant" --check "$TMP/nan.json"

# A CRLF prompt must reach agy with its CRLFs intact — universal-newline translation
# would silently review different bytes than the file holds.
printf 'line one\r\nline two\r\n' > "$TMP/crlf-prompt.txt"
CRLF_ARG="$(cat "$TMP/crlf-prompt.txt"; printf x)"; CRLF_ARG="${CRLF_ARG%x}"
expect_pass "CRLF prompt survives" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run-crlf" "$TMP/crlf-prompt.txt"
argv_equals "CRLF prompt reaches agy byte-for-byte" \
  "-p" "$CRLF_ARG" "--model" "gemini-3.8-flash" \
  "--disable-slash-commands" "--output-format" "json" "--print-timeout" "9m" \
  "--effort" "high"

# A closed reader (`| head -1`) is not our error: exit conventionally, no traceback.
python3 "$BIN" --check "$TMP/good.json" 2>"$TMP/.pipe-err" | head -1 >/dev/null
if grep -q 'Traceback' "$TMP/.pipe-err" 2>/dev/null; then
  note_fail "closed pipe produced a traceback"
else
  note_pass "closed pipe produces no traceback"
fi

expect_fail "--model with an empty value"  2 "empty value" \
  --agy "$STUB" --model "" --out "$TMP/run-empty1" "$TMP/prompt.txt"
expect_fail "--out with an empty value"    2 "empty value" \
  --agy "$STUB" --out "" "$TMP/prompt.txt"

# --- the default output location, which no --out run can exercise --------------------
# Replacing the private mkdtemp with a predictable shared path must not stay green.
# TMPDIR is pinned so mkdtemp lands inside the suite's own directory: the path below is
# parsed out of the OUTPUT OF THE CODE UNDER TEST, and a broken wrapper printing
# "raw output: /Users/alice/out.json" must never become `rm -rf /Users/alice`.
TMPDIR="$TMP" expect_pass "run with no --out" "$GOOD_STDOUT" --agy "$STUB" "$TMP/prompt.txt"
DEFAULT_OUT="$(printf '%s' "$STDERR" | sed -n 's/^raw output: \(.*\)\/out\.json$/\1/p')"
DEFAULT_OUT_REAL="$(cd "$DEFAULT_OUT" 2>/dev/null && pwd -P || true)"
TMP_REAL="$(cd "$TMP" && pwd -P)"
if [ -z "$DEFAULT_OUT" ] || [ ! -d "$DEFAULT_OUT" ]; then
  note_fail "default --out: could not find the reported directory in stderr"
elif [ -z "$DEFAULT_OUT_REAL" ] || [ "${DEFAULT_OUT_REAL#"$TMP_REAL"/}" = "$DEFAULT_OUT_REAL" ]; then
  note_fail "default --out escaped the test directory: $DEFAULT_OUT (refusing to touch it)"
else
  dmode="$(stat -f '%Lp' "$DEFAULT_OUT" 2>/dev/null || stat -c '%a' "$DEFAULT_OUT")"
  fmode="$(stat -f '%Lp' "$DEFAULT_OUT/out.json" 2>/dev/null || stat -c '%a' "$DEFAULT_OUT/out.json")"
  emode="$(stat -f '%Lp' "$DEFAULT_OUT/err.txt" 2>/dev/null || stat -c '%a' "$DEFAULT_OUT/err.txt")"
  if [ "$dmode" = "700" ]; then
    note_pass "default output directory is 0700"
  else
    note_fail "default output directory is $dmode, expected 700"
  fi
  if [ "$fmode" = "600" ] && [ "$emode" = "600" ]; then
    note_pass "both report files are 0600"
  else
    note_fail "report files are out.json=$fmode err.txt=$emode, expected 600/600"
  fi
  case "$DEFAULT_OUT" in
    */agy-review-*) note_pass "default output directory is a fresh mkdtemp" ;;
    *) note_fail "default output directory is not a mkdtemp path: $DEFAULT_OUT" ;;
  esac
  # Safe: proven to be a real path beneath $TMP, which the EXIT trap removes anyway.
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

# --- the default model: pinned, never discovered -------------------------------------
# The owner pinned gemini-3.8-flash at --effort high on 2026-09-25. A newer Flash in the
# listing must NOT move the default, and the default must not even ask for the listing.
# Each case gets an empty XDG_CACHE_HOME: the old discovery code cached its answer there,
# and a warm cache would let a reintroduced listing call hide behind "0 calls".

: > "$STUB_MODELS_CALLS"
XDG_CACHE_HOME="$TMP/cold-cache-1" expect_pass "the default run" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run-default1" "$TMP/prompt.txt"
argv_equals "the default is gemini-3.8-flash at --effort high" \
  "-p" "$PROMPT_ARG" "--model" "gemini-3.8-flash" \
  "--disable-slash-commands" "--output-format" "json" "--print-timeout" "9m" \
  "--effort" "high"
expect_models_calls "the default asks agy for no model listing" 0
expect_stderr "the model line labels the pinned default" \
  "model:      gemini-3.8-flash (default), effort high"

# A listing that offers a newer Flash changes nothing: the default is pinned by decision.
cat > "$TMP/models-newer.txt" <<'EOF2'
gemini-4-flash-high	Gemini 4 Flash (High)
gemini-3.10-flash-high	Gemini 3.10 Flash (High)
gemini-3.8-flash-high	Gemini 3.8 Flash (High)
gemini-3.1-pro-high	Gemini 3.1 Pro (High)
EOF2
: > "$STUB_MODELS_CALLS"
XDG_CACHE_HOME="$TMP/cold-cache-2" STUB_MODELS="$TMP/models-newer.txt" \
  expect_pass "a newer Flash in the listing does not move the default" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run-default2" "$TMP/prompt.txt"
argv_has "the default stays gemini-3.8-flash" "--model" "gemini-3.8-flash"
expect_models_calls "a newer listing is never consulted" 0

# An explicit --model is still used as given, and labelled as such.
expect_pass "an explicit --model is used as given" "$GOOD_STDOUT" \
  --agy "$STUB" --model claude-opus-4-6-thinking --out "$TMP/run-default3" \
  "$TMP/prompt.txt"
argv_has "the explicit id reaches agy" "--model" "claude-opus-4-6-thinking"
expect_stderr "an explicit --model is labelled as such" "explicit --model"

# The discovery flag is gone; a caller still passing it must hear so, not be ignored.
expect_fail "--refresh-models no longer exists" 2 "unrecognized arguments" \
  --agy "$STUB" --refresh-models --out "$TMP/run-default4" "$TMP/prompt.txt"

# --- gemini-3.1-pro is banned ---------------------------------------------------------
# Every variant, any case, with or without --effort, is refused before agy runs: no
# review call, no argv capture, and the refusal names the default to use instead.
for banned in gemini-3.1-pro-high gemini-3.1-pro-low gemini-3.1-pro GEMINI-3.1-Pro-High \
  " gemini-3.1-pro-high"; do
  : > "$STUB_CALLS"
  expect_fail "--model '$banned' is refused" 2 \
    "is banned — gemini-3.1-pro is never used" \
    --agy "$STUB" --model "$banned" --out "$TMP/run-ban-$RANDOM" "$TMP/prompt.txt"
  expect_calls "--model '$banned' never reaches agy" 0
done
: > "$STUB_CALLS"
expect_fail "a banned id with an explicit --effort is refused too" 2 "is banned" \
  --agy "$STUB" --model gemini-3.1-pro --effort high --out "$TMP/run-ban-effort" \
  "$TMP/prompt.txt"
expect_calls "a banned id with --effort never reaches agy" 0
expect_fail "the refusal points at the default" 2 \
  "Omit --model for the default (gemini-3.8-flash, effort high)" \
  --agy "$STUB" --model gemini-3.1-pro-high --out "$TMP/run-ban-hint" "$TMP/prompt.txt"

# The ban is exact: ids that merely share a prefix still run.
expect_pass "gemini-3.10-pro is not caught by the 3.1 ban" "$GOOD_STDOUT" \
  --agy "$STUB" --model gemini-3.10-pro --out "$TMP/run-ban-310" "$TMP/prompt.txt"
argv_has "gemini-3.10-pro reaches agy" "--model" "gemini-3.10-pro"
expect_pass "an older Flash still runs" "$GOOD_STDOUT" \
  --agy "$STUB" --model gemini-3.7-flash-high --out "$TMP/run-ban-37" "$TMP/prompt.txt"
argv_has "gemini-3.7-flash-high reaches agy" "--model" "gemini-3.7-flash-high"

# --- the output token limit: retried a rung lower, or explained ----------------------
# This failure arrives AFTER the model has run and been paid for, with either exit code,
# so the run is already spent — reporting it without retrying wastes the whole attempt.
# `$TMP/token-limit.json` is the envelope a real limit failure produced.

: > "$STUB_CALLS"
STUB_STDOUT="$TMP/token-limit.json" \
  STUB_STDOUT_2="$TMP/good.json" \
  expect_pass "a limit failure is retried a rung lower" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run-retry1" "$TMP/prompt.txt"
expect_calls "the retry costs exactly one more run" 2
expect_stderr "the retry is announced with both efforts" \
  "exceeded the output token limit; retrying at --effort medium"
expect_stderr "the summary names the effort that produced the review" \
  "effort=medium attempts=2"
ARGV_FILE_OVERRIDE="$STUB_ARGV.1" argv_equals "attempt 1 runs at the default effort" \
  "-p" "$PROMPT_ARG" "--model" "gemini-3.8-flash" \
  "--disable-slash-commands" "--output-format" "json" "--print-timeout" "9m" \
  "--effort" "high"
ARGV_FILE_OVERRIDE="$STUB_ARGV.2" argv_equals "attempt 2 differs only in the effort" \
  "-p" "$PROMPT_ARG" "--model" "gemini-3.8-flash" \
  "--disable-slash-commands" "--output-format" "json" "--print-timeout" "9m" \
  "--effort" "medium"

# The failed attempt is the evidence that the retry was warranted, so it is kept.
if [ -f "$TMP/run-retry1/out.json" ] && [ -f "$TMP/run-retry1/out-2.json" ]; then
  note_pass "both attempts keep their raw report"
  if grep -q "output token limit" "$TMP/run-retry1/out.json"; then
    note_pass "the first report still holds the limit failure"
  else
    note_fail "the first report was overwritten by the retry"
  fi
  rmode="$(stat -f '%Lp' "$TMP/run-retry1/out-2.json" 2>/dev/null || stat -c '%a' "$TMP/run-retry1/out-2.json")"
  if [ "$rmode" = "600" ]; then
    note_pass "the retry's report is 0600 like the first"
  else
    note_fail "the retry's report is $rmode, expected 600"
  fi
else
  note_fail "the retry did not keep one report per attempt"
fi

# The ladder is finite: high, medium, low, then stop.
: > "$STUB_CALLS"
STUB_STDOUT="$TMP/token-limit.json" \
  expect_fail "an exhausted ladder fails rather than looping" 1 \
  "effort tried: high, medium, low" \
  --agy "$STUB" --out "$TMP/run-retry2" "$TMP/prompt.txt"
expect_calls "the ladder stops at low" 3
expect_stderr "the exhausted ladder leads with the keep-the-effort lever" \
  "split the bundle and review it in parts"
expect_stderr "the exhausted ladder says agy has no budget flag" \
  "agy has no budget flag"
expect_stderr "the exhausted ladder puts the thinking numbers on the record" \
  "54977 of its 55850"
expect_stderr "the exhausted ladder offers a claude id as the other model" \
  "a claude id (claude-opus-4-6-thinking)"
expect_stderr_absent "the exhausted ladder never suggests running 3.1 Pro" \
  "--model gemini-3.1-pro"

# --no-retry is for a caller who wants the effort they asked for, or nothing.
: > "$STUB_CALLS"
STUB_STDOUT="$TMP/token-limit.json" \
  expect_fail "--no-retry keeps the effort and fails" 1 "drop --no-retry" \
  --agy "$STUB" --no-retry --out "$TMP/run-retry3" "$TMP/prompt.txt"
expect_calls "--no-retry runs exactly once" 1
expect_stderr "--no-retry still names the keep-the-effort route" "split the bundle"

# A suffixed id carries its effort in the id, and the sibling id need not exist, so the
# step down is handed back, never invented.
: > "$STUB_CALLS"
STUB_STDOUT="$TMP/token-limit.json" \
  expect_fail "a suffixed id is not stepped down" 1 \
  "re-run as --model gemini-3.8-flash --effort medium" \
  --agy "$STUB" --model gemini-3.8-flash-high --out "$TMP/run-retry4" "$TMP/prompt.txt"
expect_calls "a suffixed id runs once" 1
argv_lacks "no sibling id is invented" "gemini-3.8-flash-medium" "--effort"

# A model with no effort control at all.
: > "$STUB_CALLS"
STUB_STDOUT="$TMP/token-limit.json" \
  expect_fail "a model without an effort setting says so" 1 "takes no effort setting" \
  --agy "$STUB" --model claude-opus-4-6-thinking --out "$TMP/run-retry5" "$TMP/prompt.txt"
expect_calls "a model without an effort setting runs once" 1

# Only THIS error is retried. Anything else means a second run buys the same answer
# twice — the exact waste this whole branch exists to avoid.
: > "$STUB_CALLS"
STUB_STDOUT="$TMP/error-status.json" \
  expect_fail "a different error is not retried" 1 "invalid model selection" \
  --agy "$STUB" --out "$TMP/run-retry6" "$TMP/prompt.txt"
expect_calls "a non-limit error runs once" 1

# The limit failure has been seen with a non-zero exit too, and the exit-code branch
# used to run first — a retryable failure must not be reported as a dead end.
: > "$STUB_CALLS"
STUB_RC_1=1 STUB_STDOUT="$TMP/token-limit.json" \
  STUB_STDOUT_2="$TMP/good.json" \
  expect_pass "a limit failure on a non-zero exit is still retried" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run-retry7" "$TMP/prompt.txt"
expect_calls "the non-zero-exit limit failure is retried once" 2

# An explicitly requested effort is stepped down too — a review at medium beats none —
# but only where the effort travels in the flag.
: > "$STUB_CALLS"
STUB_STDOUT="$TMP/token-limit.json" \
  STUB_STDOUT_2="$TMP/good.json" \
  expect_pass "an explicit --effort is stepped down as well" "$GOOD_STDOUT" \
  --agy "$STUB" --model gemini-3.8-flash --effort high --out "$TMP/run-retry8" \
  "$TMP/prompt.txt"
ARGV_FILE_OVERRIDE="$STUB_ARGV.2" argv_has "the retry lowered the explicit effort" \
  "--effort" "medium"

: > "$STUB_CALLS"
STUB_STDOUT="$TMP/token-limit.json" \
  expect_fail "the bottom rung has nothing below it" 1 "effort tried: low" \
  --agy "$STUB" --model gemini-3.8-flash --effort low --out "$TMP/run-retry9" \
  "$TMP/prompt.txt"
expect_calls "the bottom rung runs once" 1

# A big prompt at high effort is where this failure lives, so say so before the run
# rather than after the bill.
python3 -c 'import sys; open(sys.argv[1], "w").write("Review this:\n" + "x\n" * 30000)' \
  "$TMP/big-prompt.txt"
: > "$STUB_CALLS"
expect_pass "a large prompt still runs" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run-big" "$TMP/big-prompt.txt"
expect_stderr "a large prompt at high effort is flagged before the run" \
  "KB of prompt at --effort high"
expect_pass "an ordinary prompt runs unremarked" \
  "$GOOD_STDOUT" --agy "$STUB" --out "$TMP/run-small" "$TMP/prompt.txt"
expect_stderr_absent "an ordinary prompt is not flagged" "KB of prompt at --effort high"

# --check validates an envelope, so the run options the retry added are rejected there
# too rather than silently ignored.
expect_fail "--check with --no-retry" 2 "takes no run options" \
  --check "$TMP/good.json" --no-retry

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

# The stderr and listing-count helpers must be able to go red as well.
run_bin --check "$TMP/good.json"    # a run whose stderr holds no warning at all
meta_expect_red "expect_stderr notices a message that is absent" \
  expect_stderr "META" "this string never appears on stderr"

: > "$STUB_MODELS_CALLS"
meta_expect_red "expect_models_calls notices the wrong count" \
  expect_models_calls "META" 7

: > "$STUB_CALLS"
meta_expect_red "expect_calls notices the wrong count" \
  expect_calls "META" 7

# The per-attempt captures are a new way for an assertion to pass on nothing: a case
# that names an attempt the ladder never reached must fail, not read as "absent".
seed_argv
ARGV_FILE_OVERRIDE="$TMP/no-such-attempt.bin" meta_expect_red \
  "argv_equals fails when the named attempt never ran" \
  argv_equals "META" "--model" "gemini-3.8-flash"

# Needs a run that DOES print to stderr: a --check success prints nothing, so the
# absence would hold for the wrong reason and the meta-test could never go red.
run_bin --agy "$STUB" --out "$TMP/run-meta-absent" "$TMP/prompt.txt"
meta_expect_red "expect_stderr_absent notices a message that IS present" \
  expect_stderr_absent "META" "raw output"

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
