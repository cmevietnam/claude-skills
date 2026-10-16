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
# --repo cases: keep agy's settings exactly as this attempt saw them, change them behind
# the wrapper's back, or hold still long enough to be signalled.
if [ -n "${STUB_SETTINGS_SNAP:-}" ]; then
  cp "$HOME/.gemini/antigravity-cli/settings.json" "$STUB_SETTINGS_SNAP.$N" 2>/dev/null \
    || echo "ABSENT" > "$STUB_SETTINGS_SNAP.$N"
fi
if [ -n "${STUB_EDIT_SETTINGS:-}" ]; then
  printf ' ' >> "$HOME/.gemini/antigravity-cli/settings.json"
fi
# A parked attempt records its pid, then waits up to STUB_SLEEP seconds, or until the
# file STUB_RELEASE appears, which lets a test end it as a normal, successful run.
if [ -n "${STUB_SLEEP:-}" ]; then
  echo $$ > "$STUB_STARTED"
  i=0
  while [ $i -lt $((STUB_SLEEP * 10)) ]; do
    [ -n "${STUB_RELEASE:-}" ] && [ -e "$STUB_RELEASE" ] && break
    sleep 0.1
    i=$((i + 1))
  done
fi
cat "${!OUT_VAR:-$STUB_STDOUT}"
[ -n "${STUB_STDERR:-}" ] && cat "$STUB_STDERR" >&2
[ -n "${STUB_UNLINK_ERR:-}" ] && unlink "$STUB_UNLINK_ERR"
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
  "--model" "gemini-4-argon" \
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

# A Claude base id takes --effort exactly like a Gemini one (agy 1.3.4:
# `--model claude-opus-5-5 --effort high` runs), so it gets the default effort too.
expect_pass "claude base id runs" "$GOOD_STDOUT" \
  --agy "$STUB" --model claude-opus-5-5 --out "$TMP/run3" "$TMP/prompt.txt"
argv_equals "claude base id: full argv, with the default effort" \
  "-p" "$PROMPT_ARG" "--model" "claude-opus-5-5" \
  "--disable-slash-commands" "--output-format" "json" "--print-timeout" "9m" \
  "--effort" "high"
expect_stderr "claude base id: the model line names the effort" \
  "model:      claude-opus-5-5 (explicit --model), effort high"

# ...and a suffixed Claude id must NOT (agy: "conflicts with --effort=high")
expect_pass "suffixed claude id runs" "$GOOD_STDOUT" \
  --agy "$STUB" --model claude-opus-5-5-high --out "$TMP/run3b" "$TMP/prompt.txt"
argv_equals "suffixed claude id: full argv, no --effort anywhere" \
  "-p" "$PROMPT_ARG" "--model" "claude-opus-5-5-high" \
  "--disable-slash-commands" "--output-format" "json" "--print-timeout" "9m"

# An id from a family the wrapper has no rule for gets no --effort: agy picks the level,
# and a model that takes none still runs.
expect_pass "an id from another family runs" "$GOOD_STDOUT" \
  --agy "$STUB" --model gpt-oss-120b --out "$TMP/run3c" "$TMP/prompt.txt"
argv_equals "another family: full argv, no --effort anywhere" \
  "-p" "$PROMPT_ARG" "--model" "gpt-oss-120b" \
  "--disable-slash-commands" "--output-format" "json" "--print-timeout" "9m"

# an explicit --effort is passed through even for an id that will reject it,
# so agy's own error surfaces instead of being silently dropped
expect_pass "explicit --effort passed through" "$GOOD_STDOUT" \
  --agy "$STUB" --model claude-opus-5-5-low --effort high --out "$TMP/run4" "$TMP/prompt.txt"
argv_equals "explicit --effort is forwarded even to an id that rejects it" \
  "-p" "$PROMPT_ARG" "--model" "claude-opus-5-5-low" \
  "--disable-slash-commands" "--output-format" "json" "--print-timeout" "9m" \
  "--effort" "high"

# ...and when agy rejects that combination, the error reaches the user rather than
# being swallowed. This is the behaviour the pass-through exists for. The envelope is the
# one agy 1.3.4 printed for this exact command line.
cat > "$TMP/effort-rejected.json" <<'EOF'
{"conversation_id":"","status":"ERROR","response":"",
 "error":"invalid model selection (--model \"claude-opus-5-5-low\" --effort \"high\"): --model claude-opus-5-5-low conflicts with --effort=high"}
EOF
STUB_RC=1 STUB_STDOUT="$TMP/effort-rejected.json" \
  expect_fail "rejected --effort surfaces agy's error" 1 "conflicts with --effort=high" \
  --agy "$STUB" --model claude-opus-5-5-low --effort high --out "$TMP/run4b" "$TMP/prompt.txt"

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
  "-p" "$CRLF_ARG" "--model" "gemini-4-argon" \
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
# The owner pinned gemini-4-argon at --effort high on 2026-10-14 (it was gemini-3.8-flash
# from 2026-09-25). A newer model in the listing must NOT move the default, and the
# default must not even ask for the listing.
# Each case gets an empty XDG_CACHE_HOME: the old discovery code cached its answer there,
# and a warm cache would let a reintroduced listing call hide behind "0 calls".

: > "$STUB_MODELS_CALLS"
XDG_CACHE_HOME="$TMP/cold-cache-1" expect_pass "the default run" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run-default1" "$TMP/prompt.txt"
argv_equals "the default is gemini-4-argon at --effort high" \
  "-p" "$PROMPT_ARG" "--model" "gemini-4-argon" \
  "--disable-slash-commands" "--output-format" "json" "--print-timeout" "9m" \
  "--effort" "high"
expect_models_calls "the default asks agy for no model listing" 0
expect_stderr "the model line labels the pinned default" \
  "model:      gemini-4-argon (default), effort high"

# A listing that offers a newer model changes nothing: the default is pinned by decision.
cat > "$TMP/models-newer.txt" <<'EOF2'
gemini-5-argon-high	Gemini 5 Argon (High)
gemini-4.1-argon-high	Gemini 4.1 Argon (High)
gemini-4-argon-high	Gemini 4 Argon (High)
gemini-3.8-flash-high	Gemini 3.8 Flash (High)
EOF2
: > "$STUB_MODELS_CALLS"
XDG_CACHE_HOME="$TMP/cold-cache-2" STUB_MODELS="$TMP/models-newer.txt" \
  expect_pass "a newer model in the listing does not move the default" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run-default2" "$TMP/prompt.txt"
argv_has "the default stays gemini-4-argon" "--model" "gemini-4-argon"
expect_models_calls "a newer listing is never consulted" 0

# An explicit --model is still used as given, and labelled as such.
expect_pass "an explicit --model is used as given" "$GOOD_STDOUT" \
  --agy "$STUB" --model claude-opus-5-5-high --out "$TMP/run-default3" \
  "$TMP/prompt.txt"
argv_has "the explicit id reaches agy" "--model" "claude-opus-5-5-high"
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
  "Omit --model for the default (gemini-4-argon, effort high)" \
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
  "-p" "$PROMPT_ARG" "--model" "gemini-4-argon" \
  "--disable-slash-commands" "--output-format" "json" "--print-timeout" "9m" \
  "--effort" "high"
ARGV_FILE_OVERRIDE="$STUB_ARGV.2" argv_equals "attempt 2 differs only in the effort" \
  "-p" "$PROMPT_ARG" "--model" "gemini-4-argon" \
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
  "a claude id (claude-opus-5-5)"
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

# An id the wrapper sent no effort for has no rung to step down from. It must not claim
# the model has no effort setting: agy 1.3.4 accepted `--model gpt-oss-120b --effort medium`.
: > "$STUB_CALLS"
STUB_STDOUT="$TMP/token-limit.json" \
  expect_fail "an id run without an effort says so" 1 "was run without --effort" \
  --agy "$STUB" --model gpt-oss-120b --out "$TMP/run-retry5" "$TMP/prompt.txt"
expect_calls "an id run without an effort runs once" 1
expect_stderr_absent "an id run without an effort is not called effort-less" \
  "takes no effort setting"

# A Claude base id carries its effort in the flag, so the ladder steps it down as well.
: > "$STUB_CALLS"
STUB_STDOUT="$TMP/token-limit.json" \
  STUB_STDOUT_2="$TMP/good.json" \
  expect_pass "a claude base id is stepped down too" "$GOOD_STDOUT" \
  --agy "$STUB" --model claude-opus-5-5 --out "$TMP/run-retry5b" "$TMP/prompt.txt"
expect_calls "the claude retry costs exactly one more run" 2
ARGV_FILE_OVERRIDE="$STUB_ARGV.2" argv_equals "the claude retry differs only in the effort" \
  "-p" "$PROMPT_ARG" "--model" "claude-opus-5-5" \
  "--disable-slash-commands" "--output-format" "json" "--print-timeout" "9m" \
  "--effort" "medium"

# When the reviewer already is a Claude model, "switch to a claude id" is no way out.
: > "$STUB_CALLS"
STUB_STDOUT="$TMP/token-limit.json" \
  expect_fail "an exhausted claude ladder fails" 1 "effort tried: high, medium, low" \
  --agy "$STUB" --model claude-opus-5-5 --out "$TMP/run-retry5c" "$TMP/prompt.txt"
expect_calls "the claude ladder stops at low" 3
expect_stderr "the exhausted claude ladder still offers the split" \
  "split the bundle and review it in parts"
expect_stderr_absent "the exhausted claude ladder does not offer a claude id" \
  "a claude id"

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

# agy at its print timeout: SUCCESS, a response, and "returning partial output" on stderr.
# Whatever the response holds is cut off mid-turn, so it is never passed on as a review.
printf '[agy] print timeout after 9m0s with turn in progress; returning partial output\n' \
  > "$TMP/print-timeout.err"
STUB_STDERR="$TMP/print-timeout.err" expect_fail "print timeout is not a review" 1 \
  "returned partial output" --agy "$STUB" --out "$TMP/run-print-timeout" "$TMP/prompt.txt"
# ...even when err.txt is gone by the time it is checked: the marker is read through the
# descriptor agy wrote to, not by pathname.
STUB_STDERR="$TMP/print-timeout.err" STUB_UNLINK_ERR="$TMP/run-print-timeout-2/err.txt" \
  expect_fail "print timeout with err.txt removed" 1 "returned partial output" \
  --agy "$STUB" --out "$TMP/run-print-timeout-2" "$TMP/prompt.txt"

# --- --repo: a read grant in agy's GLOBAL settings, for one run ----------------------
# Every case runs with HOME pointed at a scratch directory: the real
# ~/.gemini/antigravity-cli/settings.json is never read or written by this suite.

RH="$TMP/home"
mkdir -p "$RH/.gemini/antigravity-cli"
RH="$(cd "$RH" && pwd -P)"        # resolved, the way the wrapper resolves paths
SETTINGS="$RH/.gemini/antigravity-cli/settings.json"
GRANTS="$RH/.gemini/antigravity-cli/agy-review-grants"
REPO="$RH/work/proj"
mkdir -p "$REPO/sub"
printf 'def f():\n    return 1\n' > "$REPO/a.py"
printf 'x = 2\n' > "$REPO/sub/b.py"
git -C "$REPO" init -q && git -C "$REPO" add a.py sub/b.py \
  || { echo "FATAL: cannot build the --repo fixture"; exit 1; }
printf 'SECRET=1\n' > "$REPO/.env"   # untracked: never listed to the model
RULE="read_file($REPO)"
REPO2="$RH/work/proj2"
mkdir -p "$REPO2"
printf 'y = 3\n' > "$REPO2/c.py"
git -C "$REPO2" init -q && git -C "$REPO2" add c.py \
  || { echo "FATAL: cannot build the second --repo fixture"; exit 1; }
RULE2="read_file($REPO2)"
SNAP="$TMP/settings-snap"
export STUB_STARTED="$TMP/stub-started"

# reset_repo_state -- no settings.json, no lock, no snapshots, no counted calls.
reset_repo_state() {
  rm -rf "$SETTINGS" "$GRANTS" "$SNAP".*
  : > "$STUB_CALLS"
}

# expect_after NAME absent|FILE -- after the run: no lock, and settings.json either gone
# or byte-identical to FILE.
expect_after() {
  local name="$1" want="$2"
  if [ -e "$GRANTS" ]; then
    note_fail "$name: the grant registry $GRANTS was left behind"
  elif [ "$want" = absent ]; then
    if [ -e "$SETTINGS" ] || [ -L "$SETTINGS" ]; then
      note_fail "$name: settings.json exists after the run: $(head -c 200 "$SETTINGS")"
    else
      note_pass "$name"
    fi
  elif cmp -s "$SETTINGS" "$want"; then
    note_pass "$name"
  else
    note_fail "$name: settings.json differs from the original after the run"
  fi
}

# expect_snap NAME ATTEMPT EXPECTED_JSON -- what agy saw on that attempt, compared as JSON.
expect_snap() {
  local name="$1" n="$2" want="$3"
  if [ ! -s "$SNAP.$n" ]; then
    note_fail "$name: no snapshot for attempt $n — the stub never ran that far"
  elif python3 -c '
import json, sys
got = open(sys.argv[1]).read()
sys.exit(0 if got != "ABSENT\n" and json.loads(got) == json.loads(sys.argv[2]) else 1)' \
      "$SNAP.$n" "$want"; then
    note_pass "$name"
  else
    note_fail "$name: agy saw $(head -c 300 "$SNAP.$n")"
  fi
}

# prompt_check NAME has|lacks TEXT -- the -p argument of the last review call.
prompt_check() {
  local name="$1" mode="$2" text="$3"
  argv_capture_ok "$name" || return
  if ARGV_FILE="$(argv_file)" python3 -c '
import os, sys
a = open(os.environ["ARGV_FILE"], "rb").read().split(b"\0")
p = a[a.index(b"-p") + 1].decode()
found = sys.argv[2] in p
sys.exit(0 if found == (sys.argv[1] == "has") else 1)' "$mode" "$text"; then
    note_pass "$name"
  else
    note_fail "$name: the prompt should $mode '$text'"
  fi
}

export STUB_SETTINGS_SNAP="$SNAP"

# 1. No settings.json before: agy sees exactly our rule, and the file is gone afterwards.
reset_repo_state
HOME="$RH" expect_pass "--repo runs the review" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/repo-1" --repo "$REPO" "$TMP/prompt.txt"
expect_snap "--repo: agy sees exactly one read_file rule" 1 \
  "{\"permissions\":{\"allow\":[\"$RULE\"]}}"
expect_after "--repo: a settings.json it created is removed" absent
expect_stderr "--repo announces the grant" "repo:       $RULE added to"
prompt_check "--repo lists a tracked file" has $'\na.py\n'
prompt_check "--repo lists a tracked file in a subdirectory" has $'\nsub/b.py\n'
prompt_check "--repo keeps the caller's prompt" has "+++ b/foo.py"
prompt_check "--repo tells the model not to run commands" has "do NOT run shell commands"
prompt_check "--repo does not list an untracked .env" lacks ".env"
argv_lacks "--repo widens nothing else on the command line" \
  "--add-dir" "--dangerously-skip-permissions"

# 2. An existing settings.json with other keys: merged for the run, then byte-identical,
#    mode included.
reset_repo_state
printf '{\n  "theme": "dark",\n  "permissions": {"deny": ["command(rm)"]}\n}\n' > "$SETTINGS"
chmod 640 "$SETTINGS"
cp -p "$SETTINGS" "$TMP/settings-orig"
HOME="$RH" expect_pass "--repo with an existing settings.json" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/repo-2" --repo "$REPO" "$TMP/prompt.txt"
expect_snap "--repo keeps the user's other settings during the run" 1 \
  "{\"theme\":\"dark\",\"permissions\":{\"deny\":[\"command(rm)\"],\"allow\":[\"$RULE\"]}}"
expect_after "--repo restores settings.json byte for byte" "$TMP/settings-orig"
if [ "$(stat -f '%Lp' "$SETTINGS" 2>/dev/null || stat -c '%a' "$SETTINGS")" = 640 ]; then
  note_pass "--repo restores the file mode"
else
  note_fail "--repo changed the mode of settings.json"
fi

# 3. An empty allow-list is no rule at all.
reset_repo_state
printf '{"permissions":{"allow":[]}}' > "$SETTINGS"
cp "$SETTINGS" "$TMP/settings-orig"
HOME="$RH" expect_pass "--repo with an empty allow-list" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/repo-3" --repo "$REPO" "$TMP/prompt.txt"
expect_after "--repo restores an empty allow-list" "$TMP/settings-orig"

# 4. Refusals that must leave settings.json untouched and never start agy.
refuse_case() {
  local name="$1" content="$2" want="$3"
  reset_repo_state
  printf '%s' "$content" > "$SETTINGS"
  cp "$SETTINGS" "$TMP/settings-orig"
  HOME="$RH" expect_fail "$name" 2 "$want" \
    --agy "$STUB" --out "$TMP/repo-r-$RANDOM" --repo "$REPO" "$TMP/prompt.txt"
  expect_calls "$name: agy never ran" 0
  expect_after "$name: settings.json untouched" "$TMP/settings-orig"
}
refuse_case "--repo refuses when allow-rules exist" \
  '{"permissions":{"allow":["command(cat)"]}}' "already has allow-rules"
refuse_case "--repo refuses settings that are not JSON" '{"permissions": ' "not plain JSON"
refuse_case "--repo refuses a non-object permissions" '{"permissions":[1]}' "is not an object"
refuse_case "--repo refuses a non-list allow" '{"permissions":{"allow":"x"}}' "is not a list"

reset_repo_state
printf '{}' > "$TMP/elsewhere.json"
ln -s "$TMP/elsewhere.json" "$SETTINGS"
HOME="$RH" expect_fail "--repo refuses a symlinked settings.json" 2 "symlink" \
  --agy "$STUB" --out "$TMP/repo-5" --repo "$REPO" "$TMP/prompt.txt"
expect_calls "--repo symlinked settings: agy never ran" 0
if [ -L "$SETTINGS" ] && [ "$(cat "$TMP/elsewhere.json")" = "{}" ] && [ ! -e "$GRANTS" ]; then
  note_pass "--repo symlinked settings: link and target untouched, no registry"
else
  note_fail "--repo symlinked settings: something was changed or a registry was left"
fi

# 5. Directories that must never be granted.
reset_repo_state
mkdir -p "$TMP/not-git" "$RH/.gemini/inner" "$RH/work/par(en"
HOME="$RH" expect_fail "--repo refuses HOME itself" 2 "whole home directory" \
  --agy "$STUB" --repo "$RH" "$TMP/prompt.txt"
HOME="$RH" expect_fail "--repo refuses an ancestor of HOME" 2 "whole home directory" \
  --agy "$STUB" --repo "$(dirname "$RH")" "$TMP/prompt.txt"
HOME="$RH" expect_fail "--repo refuses /" 2 "whole home directory" \
  --agy "$STUB" --repo / "$TMP/prompt.txt"
HOME="$RH" expect_fail "--repo refuses ~/.gemini" 2 "OAuth token" \
  --agy "$STUB" --repo "$RH/.gemini/inner" "$TMP/prompt.txt"
HOME="$RH" expect_fail "--repo refuses a parenthesis in the path" 2 "parenthesis" \
  --agy "$STUB" --repo "$RH/work/par(en" "$TMP/prompt.txt"
HOME="$RH" expect_fail "--repo refuses a directory outside git" 2 "not in a git work tree" \
  --agy "$STUB" --repo "$TMP/not-git" "$TMP/prompt.txt"
HOME="$RH" expect_fail "--repo refuses a missing directory" 2 "is not a directory" \
  --agy "$STUB" --repo "$TMP/no-such-dir" "$TMP/prompt.txt"
HOME="$RH" expect_fail "--repo refuses an empty value" 2 "empty value" \
  --agy "$STUB" --repo "" "$TMP/prompt.txt"
expect_calls "refused --repo directories: agy never ran" 0
expect_after "refused --repo directories: nothing written" absent

mkdir -p "$TMP/nohome"
HOME="$TMP/nohome" expect_fail "--repo needs agy's config directory" 2 "run \`agy\` once" \
  --agy "$STUB" --out "$TMP/repo-6" --repo "$REPO" "$TMP/prompt.txt"

# 5b. Secrets reachable through the repo. Each fixture is a HOME of its own, so the
#     dotfiles layouts below cannot leak into the other cases.
mkhome() {  # mkhome DIR -- a fresh HOME with agy's config directory in it
  mkdir -p "$1/.gemini/antigravity-cli"
}
mkgit() {   # mkgit DIR FILE... -- a git work tree tracking the named files
  local d="$1"; shift
  git -C "$d" init -q && git -C "$d" add "$@"
}

# ~/.gemini is a symlink into a dotfiles repo: the repo holds agy's OAuth token.
HA="$TMP/home-dotgemini"; mkdir -p "$HA" "$TMP/dotfiles/.gemini/antigravity-cli"
echo x > "$TMP/dotfiles/vimrc"; mkgit "$TMP/dotfiles" vimrc
ln -s "$TMP/dotfiles/.gemini" "$HA/.gemini"
HOME="$HA" expect_fail "--repo refuses a repo that holds ~/.gemini through a symlink" 2 \
  "OAuth token" --agy "$STUB" --repo "$TMP/dotfiles" "$TMP/prompt.txt"

# ~/.ssh is a symlink into the repo.
HS="$TMP/home-dotssh"; mkhome "$HS"; mkdir -p "$TMP/dotssh-repo/ssh"
echo k > "$TMP/dotssh-repo/ssh/id_ed25519"; echo x > "$TMP/dotssh-repo/a"
mkgit "$TMP/dotssh-repo" a; ln -s "$TMP/dotssh-repo/ssh" "$HS/.ssh"
HOME="$HS" expect_fail "--repo refuses a repo that holds ~/.ssh through a symlink" 2 \
  "SSH keys" --agy "$STUB" --repo "$TMP/dotssh-repo" "$TMP/prompt.txt"

# HOME itself is a git work tree (a dotfiles repo): ~/.ssh passes `git ls-files`.
HG="$TMP/home-git"; mkhome "$HG"; mkdir -p "$HG/.ssh" "$HG/notes"
echo cfg > "$HG/.ssh/config"; echo KEY > "$HG/.ssh/id_ed25519"; echo n > "$HG/notes/n.txt"
mkgit "$HG" .ssh/config notes/n.txt
HOME="$HG" expect_fail "--repo refuses ~/.ssh" 2 "SSH keys" \
  --agy "$STUB" --repo "$HG/.ssh" "$TMP/prompt.txt"
HOME="$HG" expect_fail "--repo refuses a directory whose work tree is HOME" 2 \
  "rooted at the home directory" --agy "$STUB" --repo "$HG/notes" "$TMP/prompt.txt"

# GIT_DIR from the caller's environment must not vouch for a directory outside git.
HOME="$RH" GIT_DIR="$REPO/.git" expect_fail "--repo ignores an exported GIT_DIR" 2 \
  "not in a git work tree" --agy "$STUB" --repo "$TMP/not-git" "$TMP/prompt.txt"
HOME="$RH" GIT_WORK_TREE="$REPO" GIT_DIR="$REPO/.git" expect_fail \
  "--repo ignores an exported GIT_WORK_TREE" 2 "not in a git work tree" \
  --agy "$STUB" --repo "$TMP/not-git" "$TMP/prompt.txt"

# ~/.gemini itself, not only a directory inside it.
HOME="$RH" expect_fail "--repo refuses ~/.gemini itself" 2 "OAuth token" \
  --agy "$STUB" --repo "$RH/.gemini" "$TMP/prompt.txt"
expect_calls "secret-bearing --repo directories: agy never ran" 0

# A git that answers `rev-parse --show-toplevel` with nothing (older releases did, run
# inside a .git directory) must not make the caller's cwd pass for the work tree.
mkdir -p "$TMP/fakegit"
REAL_GIT="$(command -v git)"
printf '#!/bin/bash\nfor a in "$@"; do [ "$a" = rev-parse ] && exit 0; done\nexec "%s" "$@"\n' \
  "$REAL_GIT" > "$TMP/fakegit/git"
chmod +x "$TMP/fakegit/git"
HOME="$RH" PATH="$TMP/fakegit:$PATH" expect_fail "--repo: an empty work-tree answer is no work tree" \
  2 "not in a git work tree" --agy "$STUB" --repo "$REPO" "$TMP/prompt.txt"

# 6. A symlink to the repo is granted as the directory it points at.
reset_repo_state
ln -s "$REPO" "$TMP/repo-link"
HOME="$RH" expect_pass "--repo through a symlink" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/repo-7" --repo "$TMP/repo-link" "$TMP/prompt.txt"
expect_snap "--repo through a symlink grants the resolved path" 1 \
  "{\"permissions\":{\"allow\":[\"$RULE\"]}}"

# 7. Every failure after the grant still takes it back.
reset_repo_state
STUB_RC=1 STUB_STDOUT="$TMP/error-status.json" HOME="$RH" expect_fail \
  "--repo: agy exits non-zero" 1 "agy exited 1" \
  --agy "$STUB" --out "$TMP/repo-8" --repo "$REPO" "$TMP/prompt.txt"
expect_after "--repo: grant removed after agy failed" absent

reset_repo_state
STUB_STDOUT="$TMP/denied.json" HOME="$RH" expect_fail \
  "--repo: a denied tool fails the run with a --repo hint" 1 "With --repo only file reads" \
  --agy "$STUB" --out "$TMP/repo-9" --repo "$REPO" "$TMP/prompt.txt"
expect_after "--repo: grant removed after a denied run" absent

reset_repo_state
STUB_STDOUT="$TMP/token-limit.json" HOME="$RH" expect_fail \
  "--repo: output limit at the bottom of the ladder" 1 "overran the output budget" \
  --agy "$STUB" --out "$TMP/repo-10" --effort low --repo "$REPO" "$TMP/prompt.txt"
expect_after "--repo: grant removed after a limit failure" absent

# 8. The retry ladder keeps the grant for every attempt and removes it once.
reset_repo_state
STUB_STDOUT_1="$TMP/token-limit.json" HOME="$RH" expect_pass \
  "--repo: retry after the output limit" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/repo-11" --repo "$REPO" "$TMP/prompt.txt"
expect_calls "--repo: two attempts" 2
expect_snap "--repo: attempt 1 has the grant" 1 "{\"permissions\":{\"allow\":[\"$RULE\"]}}"
expect_snap "--repo: attempt 2 has the grant" 2 "{\"permissions\":{\"allow\":[\"$RULE\"]}}"
expect_after "--repo: grant removed after the ladder" absent

# 9. Someone edits settings.json during the run: never overwritten, registry kept, no
#    review, and every later run or --restore refuses until a human sorts it out.
reset_repo_state
STUB_EDIT_SETTINGS=1 HOME="$RH" expect_fail \
  "--repo: settings changed during the run" 1 "changed by someone else" \
  --agy "$STUB" --out "$TMP/repo-12" --repo "$REPO" "$TMP/prompt.txt"
if [ -d "$GRANTS" ] && grep -q "$RULE" "$SETTINGS" && [ "$(tail -c 1 "$SETTINGS")" = " " ]; then
  note_pass "--repo: someone else's edit is not overwritten and the registry is kept"
else
  note_fail "--repo: the edited settings.json was overwritten or the registry removed"
fi
HOME="$RH" expect_fail "--repo: a foreign edit blocks the next run" 2 "changed by someone else" \
  --agy "$STUB" --out "$TMP/repo-13" --repo "$REPO" "$TMP/prompt.txt"
HOME="$RH" expect_fail "--restore will not clobber an edited settings.json" 1 \
  "changed by someone else" --restore
if [ -d "$GRANTS" ] && grep -q "$RULE" "$SETTINGS" && [ "$(tail -c 1 "$SETTINGS")" = " " ]; then
  note_pass "--restore refusal: the edit and the registry are both still there"
else
  note_fail "--restore refusal: it overwrote the edit or removed the registry"
fi

# start_held NAME REPO SLEEP -- a --repo run in the background, parked inside agy until
# killed or SLEEP runs out. Sets HELD_PID (the wrapper) and HELD_STUB (the stub agy).
start_held() {
  local tag="$1" repo="$2" secs="$3"
  rm -f "$TMP/started-$tag" "$TMP/release-$tag" "$TMP/held-$tag.out" "$TMP/held-$tag.err"
  STUB_STARTED="$TMP/started-$tag" STUB_RELEASE="$TMP/release-$tag" STUB_SLEEP="$secs" \
    HOME="$RH" \
    python3 "$BIN" --agy "$STUB" --out "$TMP/held-$tag-$RANDOM" --repo "$repo" \
    "$TMP/prompt.txt" >"$TMP/held-$tag.out" 2>"$TMP/held-$tag.err" &
  HELD_PID=$!
  local i=0
  while [ ! -s "$TMP/started-$tag" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  HELD_STUB="$(cat "$TMP/started-$tag" 2>/dev/null)"
  [ -n "$HELD_STUB" ]
}

# settings_rules -- the allow-list in settings.json right now, one rule per line.
settings_rules() {
  python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except FileNotFoundError:
    print("ABSENT"); raise SystemExit
for r in d.get("permissions", {}).get("allow", []):
    print(r)' "$SETTINGS"
}

expect_rules() {
  local name="$1" want="$2" got
  got="$(settings_rules)"
  if [ "$got" = "$want" ]; then note_pass "$name"; else note_fail "$name: allow-list is '$got'"; fi
}

# 10. Overlapping runs on two repos: each sees the union, each removes only its own rule,
#     the last one out restores the original.
reset_repo_state
printf '{"theme":"light"}\n' > "$SETTINGS"
cp "$SETTINGS" "$TMP/settings-orig"
if start_held A "$REPO" 30; then
  PID_A=$HELD_PID
  expect_rules "overlap: A alone holds its rule" "$RULE"
  HOME="$RH" expect_pass "overlap: B runs while A holds a grant" "$GOOD_STDOUT" \
    --agy "$STUB" --out "$TMP/repo-ov-b" --repo "$REPO2" "$TMP/prompt.txt"
  N_B="$(wc -l < "$STUB_CALLS" | tr -d ' ')"
  expect_snap "overlap: B's agy sees both rules" "$N_B" \
    "{\"theme\":\"light\",\"permissions\":{\"allow\":[\"$RULE\",\"$RULE2\"]}}"
  expect_stderr "overlap: B says A's rule stays" "rule(s) of other running reviews stay"
  expect_rules "overlap: after B, only A's rule is left" "$RULE"
  touch "$TMP/release-A"   # A's agy finishes; A takes its rule back
  wait "$PID_A"; RC_A=$?
  if [ "$RC_A" -eq 0 ]; then note_pass "overlap: A completes"; else note_fail "overlap: A exited $RC_A — $(head -c 200 "$TMP/held-A.err")"; fi
  expect_after "overlap: the last run out restores the original" "$TMP/settings-orig"
else
  note_fail "overlap: run A never reached agy"
fi

# 11. Two runs on the same repo: one rule, held until the second one leaves.
reset_repo_state
if start_held A "$REPO" 30; then
  PID_A=$HELD_PID
  HOME="$RH" expect_pass "same repo: a second run on it" "$GOOD_STDOUT" \
    --agy "$STUB" --out "$TMP/repo-same-b" --repo "$REPO" "$TMP/prompt.txt"
  N_B="$(wc -l < "$STUB_CALLS" | tr -d ' ')"
  expect_snap "same repo: the rule appears once" "$N_B" \
    "{\"permissions\":{\"allow\":[\"$RULE\"]}}"
  expect_rules "same repo: the first run still has its rule" "$RULE"
  touch "$TMP/release-A"; wait "$PID_A"
  expect_after "same repo: gone once both have left" absent
else
  note_fail "same repo: run A never reached agy"
fi

# 12. A run killed with SIGKILL cannot clean up. Its grant is dropped by the next run, or
#     by --restore, and never outlives it in anyone's allow-list.
reset_repo_state
printf '{"theme":"light"}\n' > "$SETTINGS"
cp "$SETTINGS" "$TMP/settings-orig"
if start_held K "$REPO" 30; then
  kill -KILL "$HELD_PID" "$HELD_STUB" 2>/dev/null; wait "$HELD_PID" 2>/dev/null
  expect_rules "SIGKILL: the dead run's rule is still there" "$RULE"
  HOME="$RH" expect_pass "SIGKILL: the next run proceeds" "$GOOD_STDOUT" \
    --agy "$STUB" --out "$TMP/repo-k2" --repo "$REPO2" "$TMP/prompt.txt"
  N_B="$(wc -l < "$STUB_CALLS" | tr -d ' ')"
  expect_snap "SIGKILL: the next run drops the dead run's rule" "$N_B" \
    "{\"theme\":\"light\",\"permissions\":{\"allow\":[\"$RULE2\"]}}"
  expect_after "SIGKILL: the original is back after the next run" "$TMP/settings-orig"
else
  note_fail "SIGKILL: run K never reached agy"
fi

reset_repo_state
printf '{"theme":"light"}\n' > "$SETTINGS"
if start_held K "$REPO" 30; then
  kill -KILL "$HELD_PID" "$HELD_STUB" 2>/dev/null; wait "$HELD_PID" 2>/dev/null
  run_bin_home() { HOME="$RH" run_bin "$@"; }
  run_bin_home --restore
  if [ "$RC" -eq 0 ] && printf '%s' "$STDERR" | grep -q "no --repo grant is left"; then
    note_pass "--restore after SIGKILL reports the restore"
  else
    note_fail "--restore after SIGKILL: exit $RC — ${STDERR:0:200}"
  fi
  expect_after "--restore after SIGKILL puts the original back" "$TMP/settings-orig"
else
  note_fail "--restore after SIGKILL: run K never reached agy"
fi

# --restore while a live run holds a grant: dead ones go, the live one stays.
reset_repo_state
if start_held A "$REPO" 30; then
  PID_A=$HELD_PID
  HOME="$RH" run_bin --restore
  if [ "$RC" -eq 0 ] && printf '%s' "$STDERR" | grep -q "rule(s) of running reviews stay"; then
    note_pass "--restore leaves a live run's grant alone"
  else
    note_fail "--restore with a live run: exit $RC — ${STDERR:0:200}"
  fi
  expect_rules "--restore: the live rule is still granted" "$RULE"
  touch "$TMP/release-A"; wait "$PID_A"
  expect_after "--restore: the live run still cleans up after itself" absent
else
  note_fail "--restore with a live run: run A never reached agy"
fi

HOME="$RH" run_bin --restore
if [ "$RC" -eq 0 ] && printf '%s' "$STDERR" | grep -q "nothing to restore"; then
  note_pass "--restore with nothing outstanding says so"
else
  note_fail "--restore with nothing outstanding: exit $RC — ${STDERR:0:200}"
fi

# 13. The edit mutex: a run waits for whoever holds it instead of racing them.
reset_repo_state
python3 -c '
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(3)' "$RH/.gemini/antigravity-cli/agy-review.lock" "$TMP/mutex-held" &
MUTEX_PID=$!
i=0; while [ ! -e "$TMP/mutex-held" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
now() { python3 -c "import time; print(int(time.time() * 1000))"; }
T0=$(now)
HOME="$RH" expect_pass "mutex: a run waits for the edit lock" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/repo-mutex" --repo "$REPO" "$TMP/prompt.txt"
T1=$(now)
wait "$MUTEX_PID"; rm -f "$TMP/mutex-held"
# The holder keeps the lock 3 s; a run that did not wait finishes in well under 1 s.
if [ $((T1 - T0)) -ge 2500 ]; then note_pass "mutex: the run really waited"; else note_fail "mutex: the run did not wait ($((T1 - T0)) ms)"; fi
expect_after "mutex: grant removed" absent

HOME="$RH" expect_fail "--restore takes no other options" 2 "takes no other options" \
  --restore "$TMP/prompt.txt"
HOME="$RH" expect_fail "--check with --repo" 2 "takes no run options" \
  --check "$TMP/good.json" --repo "$REPO"

# 14. Signals: the grant is taken back when the run is interrupted mid-flight.
signal_case() {
  local sig="$1" want_rc="$2"
  reset_repo_state
  rm -f "$STUB_STARTED"
  STUB_SLEEP=30 HOME="$RH" python3 "$BIN" --agy "$STUB" --out "$TMP/repo-sig-$sig" \
    --repo "$REPO" "$TMP/prompt.txt" >"$TMP/.sig-out" 2>"$TMP/.sig-err" &
  local pid=$! i=0
  while [ ! -e "$STUB_STARTED" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  if [ ! -e "$STUB_STARTED" ]; then
    kill -KILL "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    note_fail "--repo $sig: the stub never started"
    return
  fi
  if ! grep -q "$RULE" "$SETTINGS" 2>/dev/null; then
    note_fail "--repo $sig: the grant was not in place while agy ran"
  fi
  kill -"$sig" "$pid"
  wait "$pid"; local rc=$?
  if [ "$rc" -ne "$want_rc" ]; then
    note_fail "--repo $sig: exit $rc, expected $want_rc — $(head -c 200 "$TMP/.sig-err")"
  elif grep -q Traceback "$TMP/.sig-err"; then
    note_fail "--repo $sig: died with a traceback"
  else
    note_pass "--repo $sig: exits $want_rc"
  fi
  expect_after "--repo $sig: grant removed" absent
}
signal_case TERM 143
signal_case INT 130
signal_case HUP 129

# 15. A burst of signals: the second and third must not cut the release short.
reset_repo_state
if start_held S "$REPO" 30; then
  kill -TERM "$HELD_PID"; kill -INT "$HELD_PID"; kill -HUP "$HELD_PID"
  wait "$HELD_PID"
  expect_after "signal burst: grant removed" absent
else
  note_fail "signal burst: the run never reached agy"
fi

# 15b. A signal that arrives while the release is under way must not abort it. Holding
#      the edit mutex parks the run inside its release, deterministically, while the
#      signal is sent; then the mutex is let go.
reset_repo_state
if start_held R "$REPO" 30; then
  rm -f "$TMP/mutex-held" "$TMP/mutex-go"
  python3 -c '
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
while not os.path.exists(sys.argv[3]):
    time.sleep(0.05)' "$RH/.gemini/antigravity-cli/agy-review.lock" "$TMP/mutex-held" \
    "$TMP/mutex-go" &
  HOLDER=$!
  i=0; while [ ! -e "$TMP/mutex-held" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  touch "$TMP/release-R"     # agy finishes; the run now waits for the mutex to release
  sleep 1
  kill -TERM "$HELD_PID" 2>/dev/null
  sleep 0.5
  touch "$TMP/mutex-go"; wait "$HOLDER"
  wait "$HELD_PID"; R_RC=$?
  expect_after "signal during the release: grant still removed" absent
  # The signal was only held back while the grant came out: it still ends the run,
  # and no review is printed as if nothing had happened.
  if [ "$R_RC" -eq 143 ] && [ ! -s "$TMP/held-R.out" ]; then
    note_pass "signal during the release: still exits 143, prints nothing"
  else
    note_fail "signal during the release: exit $R_RC, stdout $(head -c 80 "$TMP/held-R.out")"
  fi
else
  note_fail "signal during the release: the run never reached agy"
fi

# 15c. A signal while the run still waits to add its grant: it stops cleanly and leaves
#      nothing behind.
reset_repo_state
rm -f "$TMP/mutex-held" "$TMP/mutex-go"
python3 -c '
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
while not os.path.exists(sys.argv[3]):
    time.sleep(0.05)' "$RH/.gemini/antigravity-cli/agy-review.lock" "$TMP/mutex-held" \
  "$TMP/mutex-go" &
HOLDER=$!
i=0; while [ ! -e "$TMP/mutex-held" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
: > "$STUB_CALLS"
HOME="$RH" python3 "$BIN" --agy "$STUB" --out "$TMP/repo-acq-sig" --repo "$REPO" \
  "$TMP/prompt.txt" >/dev/null 2>"$TMP/.acq-err" &
ACQ=$!
sleep 1
kill -TERM "$ACQ"
sleep 0.5
touch "$TMP/mutex-go"; wait "$HOLDER"
wait "$ACQ"; ACQ_RC=$?
if [ "$ACQ_RC" -eq 143 ] && ! grep -q Traceback "$TMP/.acq-err"; then
  note_pass "signal while acquiring: exits 143 cleanly"
else
  note_fail "signal while acquiring: exit $ACQ_RC — $(head -c 200 "$TMP/.acq-err")"
fi
expect_calls "signal while acquiring: agy never ran" 0
expect_after "signal while acquiring: nothing left behind" absent

# 16. stderr that breaks right after the grant is written (a reader such as `| head -1`
#     that has gone away): the write fails inside the `try`, and the grant still goes.
reset_repo_state
HOME="$RH" python3 - "$BIN" "$STUB" "$TMP/repo-epipe" "$REPO" "$TMP/prompt.txt" <<'PY'
import os, subprocess, sys
r, w = os.pipe()
os.close(r)                      # every write to stderr now fails with EPIPE
binary, stub, out, repo, prompt = sys.argv[1:]
subprocess.call([sys.executable, binary, "--agy", stub, "--out", out, "--repo", repo, prompt],
                stdout=subprocess.DEVNULL, stderr=w)
PY
expect_after "broken stderr: grant removed" absent

# write_registry RULE PID STARTED -- a registry as a run with that pid and start time
# would have left it, settings.json included, with the original {"theme":"light"}.
write_registry() {
  printf '{"theme":"light"}\n' > "$TMP/settings-orig"
  mkdir -m 700 "$GRANTS"
  cp "$TMP/settings-orig" "$GRANTS/settings.orig"
  python3 - "$GRANTS" "$SETTINGS" "$1" "$2" "$3" "$TMP/settings-orig" <<'PY'
import hashlib, json, sys
g, s, rule, pid, started, orig = sys.argv[1:]
o = json.load(open(orig))
w = (json.dumps(dict(o, permissions={"allow": [rule]}), indent=2) + "\n").encode()
open(s, "wb").write(w)
json.dump({"existed": True, "mode": 0o600, "accepted": [hashlib.sha256(w).hexdigest()]},
          open(g + "/state.json", "w"))
json.dump({"pid": int(pid), "rule": rule, "started": started or None},
          open(f"{g}/grant-{pid}.json", "w"))
PY
}

# 17. A dead run's pid now belongs to an unrelated process: the start time tells them
#     apart, and the stale rule goes.
reset_repo_state
write_registry "$RULE" $$ "Thu Jan  1 00:00:00 1970"
HOME="$RH" run_bin --restore
if [ "$RC" -eq 0 ] && printf '%s' "$STDERR" | grep -q "no --repo grant is left"; then
  note_pass "pid reuse: --restore drops the dead run's rule"
else
  note_fail "pid reuse: exit $RC — ${STDERR:0:200}"
fi
expect_after "pid reuse: the original is back" "$TMP/settings-orig"

# ...while a grant whose pid AND start time match is a live run, and stays.
reset_repo_state
write_registry "$RULE" $$ "$(LC_ALL=C ps -o lstart= -p $$ | sed 's/^ *//; s/ *$//')"
HOME="$RH" run_bin --restore
if [ "$RC" -eq 0 ] && printf '%s' "$STDERR" | grep -q "rule(s) of running reviews stay"; then
  note_pass "pid reuse: a matching start time is a live run"
else
  note_fail "pid reuse, live: exit $RC — ${STDERR:0:200}"
fi
expect_rules "pid reuse: the live rule stays" "$RULE"

# 18. Killed after putting the original back but before removing the registry: the
#     original bytes are not someone else's edit.
reset_repo_state
write_registry "$RULE" 999999 ""
cp "$TMP/settings-orig" "$SETTINGS"
rm -f "$GRANTS"/grant-*.json
HOME="$RH" run_bin --restore
if [ "$RC" -eq 0 ] && printf '%s' "$STDERR" | grep -q "no --repo grant is left"; then
  note_pass "original back, registry left: --restore finishes the job"
else
  note_fail "original back, registry left: exit $RC — ${STDERR:0:200}"
fi
expect_after "original back, registry left: nothing remains" "$TMP/settings-orig"

# A registry with no grant at all (its run died before registering) does not block the
# next run.
reset_repo_state
write_registry "$RULE" 999999 ""
cp "$TMP/settings-orig" "$SETTINGS"
rm -f "$GRANTS"/grant-*.json
HOME="$RH" expect_pass "orphan registry: the next run proceeds" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/repo-orphan" --repo "$REPO2" "$TMP/prompt.txt"
expect_after "orphan registry: cleaned up afterwards" "$TMP/settings-orig"

# 19. A grant file carrying this very process's pid was left by a dead run whose pid
#     the OS reused for it: it is stale whatever its start time says. Exercised in
#     process, since no shell can predict the pid of the run it starts.
reset_repo_state
HOME="$RH" python3 - "$BIN" "$RULE" <<'PY' >"$TMP/.f1" 2>&1
import hashlib, importlib.machinery, importlib.util, json, os, sys
sys.dont_write_bytecode = True   # no __pycache__ inside the plugin
loader = importlib.machinery.SourceFileLoader("agyreview", sys.argv[1])
spec = importlib.util.spec_from_loader("agyreview", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
rule = sys.argv[2]
for started in ("Thu Jan  1 00:00:00 1970", m.process_start(os.getpid()), None):
    g = m.grants_dir()
    os.mkdir(g, 0o700)
    w = (json.dumps({"permissions": {"allow": [rule]}}, indent=2) + "\n").encode()
    open(m.settings_path(), "wb").write(w)
    json.dump({"existed": False, "mode": 0o600, "accepted": [hashlib.sha256(w).hexdigest()]},
              open(g + "/state.json", "w"))
    json.dump({"pid": os.getpid(), "rule": rule, "started": started},
              open(f"{g}/grant-{os.getpid()}.json", "w"))
    with m.settings_mutex():
        left = m.update_grants()
    print(f"started={started!r} rules_left={left} settings_exists={os.path.exists(m.settings_path())}")
PY
if [ "$(grep -c "rules_left=\[\] settings_exists=False" "$TMP/.f1")" = 3 ]; then
  note_pass "own-pid grant: dropped as stale, whatever its start time"
else
  note_fail "own-pid grant: $(cat "$TMP/.f1")"
fi
expect_after "own-pid grant: nothing left" absent

# 20. grant_alive: a pid of another user is not a run of ours, and a pid that exits
#     between the liveness check and `ps` is dead, not "unknown, so alive".
python3 - "$BIN" <<'PY' >"$TMP/.f2" 2>&1
import importlib.machinery, importlib.util, os, sys
sys.dont_write_bytecode = True   # no __pycache__ inside the plugin
loader = importlib.machinery.SourceFileLoader("agyreview", sys.argv[1])
spec = importlib.util.spec_from_loader("agyreview", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
real_kill = os.kill
def denied(pid, sig):
    raise PermissionError(1, "Operation not permitted")
os.kill = denied
print("other-user", m.pid_alive(12345), m.grant_alive(12345, "x"))
os.kill = real_kill
answers = iter([True, False])                 # alive at the first look, gone at the second
m.pid_alive = lambda pid: next(answers)
m.process_start = lambda pid: None            # ps found nothing in between
print("exited-between", m.grant_alive(12345, "Wed Oct 15 01:00:00 2026"))
PY
if grep -q "other-user False False" "$TMP/.f2" && grep -q "exited-between False" "$TMP/.f2"; then
  note_pass "grant_alive: other users' pids and vanished pids are dead"
else
  note_fail "grant_alive: $(cat "$TMP/.f2")"
fi

# 21. Setup failures before anything is written are exit 2 with the real cause, never a
#     claim that a grant could not be taken back.
reset_repo_state
unlink "$RH/.gemini/antigravity-cli/agy-review.lock"   # left by earlier cases
ln -s "$TMP/nowhere" "$RH/.gemini/antigravity-cli/agy-review.lock" \
  || { echo "FATAL: cannot plant the symlinked mutex"; exit 1; }
HOME="$RH" expect_fail "--repo with a symlinked mutex file" 2 "could not add the read grant" \
  --agy "$STUB" --out "$TMP/repo-f3" --repo "$REPO" "$TMP/prompt.txt"
expect_stderr_absent "--repo with a symlinked mutex file: no false release failure" \
  "back out of"
unlink "$RH/.gemini/antigravity-cli/agy-review.lock"
expect_after "--repo with a symlinked mutex file: nothing written" absent

# ...and a signal while waiting for the mutex ends the run at once, not after the
# holder lets go.
reset_repo_state
rm -f "$TMP/mutex-held" "$TMP/mutex-go"
python3 -c '
import fcntl, os, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(fd, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
while not os.path.exists(sys.argv[3]):
    time.sleep(0.05)' "$RH/.gemini/antigravity-cli/agy-review.lock" "$TMP/mutex-held" \
  "$TMP/mutex-go" &
HOLDER=$!
i=0; while [ ! -e "$TMP/mutex-held" ] && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
HOME="$RH" python3 "$BIN" --agy "$STUB" --out "$TMP/repo-f3b" --repo "$REPO" \
  "$TMP/prompt.txt" >/dev/null 2>"$TMP/.f3b" &
WAITER=$!
sleep 1
T0=$(now); kill -TERM "$WAITER"; wait "$WAITER"; W_RC=$?; T1=$(now)
touch "$TMP/mutex-go"; wait "$HOLDER"
if [ "$W_RC" -eq 143 ] && [ $((T1 - T0)) -lt 1500 ]; then
  note_pass "signal while waiting for the mutex: exits at once ($((T1 - T0)) ms)"
else
  note_fail "signal while waiting for the mutex: exit $W_RC after $((T1 - T0)) ms"
fi
expect_after "signal while waiting for the mutex: nothing left" absent

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
