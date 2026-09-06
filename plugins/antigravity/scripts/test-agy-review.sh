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

# One line per `agy models` call the stub answers, so a test can prove the cache stopped
# a second fetch — and prove a fetch happened at all, which no argv assertion can show
# (the review call that follows overwrites the argv capture).
STUB_MODELS_CALLS="$TMP/models-calls.txt"
export STUB_MODELS_CALLS
: > "$STUB_MODELS_CALLS"

# The default model is discovered and cached. Pin the cache inside the suite's own
# directory so no case can read, write or invalidate the real user's cache.
export XDG_CACHE_HOME="$TMP/cache"

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
expect_pass "non-ASCII response"       "Finding 1 — cấu hình → hỏng$NL" --check "$TMP/utf8.json"
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
  "Finding 1 — cấu hình → hỏng$NL" --check "$TMP/utf8.json"

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
# then emits whatever the fixture files dictate.
printf '%s\0' "$@" > "$STUB_ARGV"
cat "$STUB_STDOUT"
[ -n "${STUB_STDERR:-}" ] && cat "$STUB_STDERR" >&2
exit "${STUB_RC:-0}"
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

# --- the default model: discovered from `agy models`, not pinned ---------------------
# The whole point is that the default stops being right the day Google ships a newer
# Flash. Every case here fixes its own XDG_CACHE_HOME so it starts from a cold cache and
# cannot be answered by an earlier case's.

# The listing agy really produces resolves to the base id, not a suffixed one: a
# suffixed --model makes agy reject the default --effort.
: > "$STUB_MODELS_CALLS"
XDG_CACHE_HOME="$TMP/c-real" expect_pass "default model comes from the real listing" \
  "$GOOD_STDOUT" --agy "$STUB" --out "$TMP/run-disc1" "$TMP/prompt.txt"
argv_equals "suffixed listing collapses to the unsuffixed base id" \
  "-p" "$PROMPT_ARG" "--model" "gemini-3.8-flash" \
  "--disable-slash-commands" "--output-format" "json" "--print-timeout" "9m" \
  "--effort" "high"
expect_models_calls "a cold cache costs exactly one models call" 1
expect_stderr "the model line names where the id came from" \
  "model:      gemini-3.8-flash (latest Flash from"

# A newer generation must be picked up with no code change — this is the whole feature.
cat > "$TMP/models-newer.txt" <<'EOF'
gemini-4-flash-high	Gemini 4 Flash (High)
gemini-3.10-flash-high	Gemini 3.10 Flash (High)
gemini-3.8-flash-high	Gemini 3.8 Flash (High)
gemini-3.1-pro-high	Gemini 3.1 Pro (High)
claude-opus-4-6-thinking	Claude Opus 4.6 (Thinking)
EOF
XDG_CACHE_HOME="$TMP/c-newer" STUB_MODELS="$TMP/models-newer.txt" \
  expect_pass "a newer Flash generation is used without a code change" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run-disc2" "$TMP/prompt.txt"
argv_equals "newest generation wins over the pinned fallback" \
  "-p" "$PROMPT_ARG" "--model" "gemini-4-flash" \
  "--disable-slash-commands" "--output-format" "json" "--print-timeout" "9m" \
  "--effort" "high"

# Versions are numbers, not strings: "3.9" > "3.10" lexically, and that would pick the
# older model forever once a .10 exists.
cat > "$TMP/models-3-10.txt" <<'EOF'
gemini-3.9-flash-high	Gemini 3.9 Flash (High)
gemini-3.10-flash-high	Gemini 3.10 Flash (High)
gemini-3.8-flash-low	Gemini 3.8 Flash (Low)
EOF
XDG_CACHE_HOME="$TMP/c-310" STUB_MODELS="$TMP/models-3-10.txt" \
  expect_pass "3.10 beats 3.9" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run-disc3" "$TMP/prompt.txt"
argv_has "versions compare numerically, not lexically" "--model" "gemini-3.10-flash"
argv_lacks "the lexically-larger older id is not chosen" "gemini-3.9-flash"

# Ids this wrapper does not understand must be ignored, never guessed at: passing an id
# agy does not offer turns the whole review into an ERROR envelope.
cat > "$TMP/models-odd.txt" <<'EOF'
gemini-99999-flash-high	Absurd version, outside the bounded digit range
gemini-9.9-flash-turbo	Unknown effort suffix
gemini-flash-high	No version at all
gemini-4.2-flash-high	Gemini 4.2 Flash (High)
gemini-3.8-flash-high	Gemini 3.8 Flash (High)
EOF
XDG_CACHE_HOME="$TMP/c-odd" STUB_MODELS="$TMP/models-odd.txt" \
  expect_pass "unrecognised Flash-ish ids are skipped" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run-disc4" "$TMP/prompt.txt"
argv_has "the newest well-formed id is chosen" "--model" "gemini-4.2-flash"
argv_lacks "an out-of-range version and an unknown suffix are both skipped" \
  "gemini-99999-flash" "gemini-9.9-flash"

# No Flash at all in the listing: fall back, and say so rather than inventing an id.
cat > "$TMP/models-noflash.txt" <<'EOF'
gemini-3.1-pro-high	Gemini 3.1 Pro (High)
claude-sonnet-4-6	Claude Sonnet 4.6 (Thinking)
gpt-oss-120b-medium	GPT-OSS 120B (Medium)
EOF
XDG_CACHE_HOME="$TMP/c-noflash" STUB_MODELS="$TMP/models-noflash.txt" \
  expect_pass "a Flash-less listing falls back" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run-disc5" "$TMP/prompt.txt"
argv_has "the fallback id is used" "--model" "gemini-3.8-flash"
expect_stderr "a Flash-less listing is reported" "no gemini-\*-flash id"

# `agy models` failing (no auth, no network) must not fail the review.
printf 'Please sign in to continue.\n' > "$TMP/models-err.txt"
XDG_CACHE_HOME="$TMP/c-modelfail" STUB_MODELS_RC=1 STUB_MODELS="" \
  STUB_MODELS_ERR="$TMP/models-err.txt" \
  expect_pass "a failing models call still runs the review" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run-disc6" "$TMP/prompt.txt"
argv_has "the fallback id is used when the listing cannot be fetched" \
  "--model" "gemini-3.8-flash"
expect_stderr "the listing failure is reported with agy's own message" "Please sign in"

# A hung `agy models` must not hang the review behind it.
: > "$STUB_MODELS_CALLS"
XDG_CACHE_HOME="$TMP/c-timeout" AGY_REVIEW_MODELS_TIMEOUT=1 STUB_MODELS_SLEEP=4 \
  expect_pass "a hung models call times out and falls back" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run-disc7" "$TMP/prompt.txt"
expect_stderr "the timeout is reported" "timed out after 1s"
argv_has "a timed-out listing still yields a usable model" "--model" "gemini-3.8-flash"

# An explicit --model is the user pinning the reviewer: no listing call at all.
: > "$STUB_MODELS_CALLS"
XDG_CACHE_HOME="$TMP/c-explicit" expect_pass "an explicit --model is used as given" \
  "$GOOD_STDOUT" --agy "$STUB" --model claude-opus-4-6-thinking \
  --out "$TMP/run-disc8" "$TMP/prompt.txt"
expect_models_calls "an explicit --model asks for no listing" 0
expect_stderr "an explicit --model is labelled as such" "explicit --model"

# --refresh-models alongside --model changes nothing, so it must not look like it did.
: > "$STUB_MODELS_CALLS"
XDG_CACHE_HOME="$TMP/c-explicit2" expect_pass "--refresh-models with --model still runs" \
  "$GOOD_STDOUT" --agy "$STUB" --model gemini-3.6-flash --refresh-models \
  --out "$TMP/run-disc9" "$TMP/prompt.txt"
expect_stderr "--refresh-models with --model is called out" \
  "has no effect alongside an explicit --model"
expect_models_calls "--refresh-models with --model asks for no listing" 0

# --- the cache -----------------------------------------------------------------------
# A 3-second listing call on every review would be paid for nothing: the answer changes
# every few months.
: > "$STUB_MODELS_CALLS"
XDG_CACHE_HOME="$TMP/c-cache" expect_pass "first run populates the cache" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run-cache1" "$TMP/prompt.txt"
XDG_CACHE_HOME="$TMP/c-cache" expect_pass "second run reuses it" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run-cache2" "$TMP/prompt.txt"
expect_models_calls "two runs, one listing call" 1
argv_has "the cached id is still the right one" "--model" "gemini-3.8-flash"
expect_stderr "a cache hit is labelled" "latest Flash, cached"

CACHE_JSON="$TMP/c-cache/agy-review/latest-flash.json"
if [ -f "$CACHE_JSON" ]; then
  note_pass "the cache file is where it is documented to be"
  cmode="$(stat -f '%Lp' "$TMP/c-cache/agy-review" 2>/dev/null || stat -c '%a' "$TMP/c-cache/agy-review")"
  jmode="$(stat -f '%Lp' "$CACHE_JSON" 2>/dev/null || stat -c '%a' "$CACHE_JSON")"
  if [ "$cmode" = "700" ]; then
    note_pass "the cache directory is 0700"
  else
    note_fail "the cache directory is $cmode, expected 700"
  fi
  if [ "$jmode" = "600" ]; then
    note_pass "the cache file is 0600"
  else
    note_fail "the cache file is $jmode, expected 600"
  fi
else
  note_fail "no cache file at $CACHE_JSON"
fi

# --refresh-models is the escape hatch when a new generation lands mid-day.
: > "$STUB_MODELS_CALLS"
XDG_CACHE_HOME="$TMP/c-cache" STUB_MODELS="$TMP/models-newer.txt" \
  expect_pass "--refresh-models re-asks" "$GOOD_STDOUT" \
  --agy "$STUB" --refresh-models --out "$TMP/run-cache3" "$TMP/prompt.txt"
expect_models_calls "--refresh-models forces a listing call" 1
argv_has "--refresh-models picks up the newer generation" "--model" "gemini-4-flash"

# TTL 0 means never trust the cache.
: > "$STUB_MODELS_CALLS"
XDG_CACHE_HOME="$TMP/c-cache" AGY_REVIEW_CACHE_TTL=0 \
  expect_pass "TTL 0 re-asks" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run-cache4" "$TMP/prompt.txt"
expect_models_calls "AGY_REVIEW_CACHE_TTL=0 forces a listing call" 1

# ...including a remembered failure, which is the other half of the cache.
: > "$STUB_MODELS_CALLS"
XDG_CACHE_HOME="$TMP/c-negttl" STUB_MODELS_RC=1 STUB_MODELS="" \
  STUB_MODELS_ERR="$TMP/models-err.txt" \
  expect_pass "a failure is remembered under the default TTL" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run-negttl1" "$TMP/prompt.txt"
XDG_CACHE_HOME="$TMP/c-negttl" AGY_REVIEW_CACHE_TTL=0 \
  expect_pass "TTL 0 retries a remembered failure" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run-negttl2" "$TMP/prompt.txt"
expect_models_calls "AGY_REVIEW_CACHE_TTL=0 ignores the remembered failure too" 2
argv_has "the TTL 0 retry resolves a real model" "--model" "gemini-3.8-flash"
expect_stderr "the TTL 0 retry is a fresh listing, not a cache hit" \
  "latest Flash from"

XDG_CACHE_HOME="$TMP/c-cache" AGY_REVIEW_CACHE_TTL=nonsense \
  expect_pass "an unparseable TTL still runs" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run-cache5" "$TMP/prompt.txt"
expect_stderr "an unparseable TTL is reported" "AGY_REVIEW_CACHE_TTL"

# A cache is untrusted input: its id lands in agy's argv. Every rejected shape below must
# cost one listing call, never a bad --model.
write_cache_file() {   # write_cache_file DIR JSON
  mkdir -p "$1/agy-review"
  printf '%s' "$2" > "$1/agy-review/latest-flash.json"
}
NOW="$(python3 -c 'import time; print(int(time.time()))')"

: > "$STUB_MODELS_CALLS"
write_cache_file "$TMP/c-bad1" 'this is not json at all'
XDG_CACHE_HOME="$TMP/c-bad1" expect_pass "a corrupt cache is ignored" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run-bad1" "$TMP/prompt.txt"
argv_has "a corrupt cache does not choose the model" "--model" "gemini-3.8-flash"
expect_models_calls "a corrupt cache is refetched" 1

: > "$STUB_MODELS_CALLS"
write_cache_file "$TMP/c-bad2" "{\"model\":\"claude-opus-4-6-thinking\",\"agy\":\"$STUB\",\"fetched_at\":$NOW}"
XDG_CACHE_HOME="$TMP/c-bad2" STUB_MODELS="$TMP/models-newer.txt" \
  expect_pass "a non-Flash cached id is ignored" \
  "$GOOD_STDOUT" --agy "$STUB" --out "$TMP/run-bad2" "$TMP/prompt.txt"
argv_lacks "a planted cache cannot swap the reviewer" "claude-opus-4-6-thinking"
argv_has "a planted cache is replaced by a real listing" "--model" "gemini-4-flash"

: > "$STUB_MODELS_CALLS"
write_cache_file "$TMP/c-bad3" "{\"model\":\"gemini-4-flash\",\"agy\":\"/somewhere/else/agy\",\"fetched_at\":$NOW}"
XDG_CACHE_HOME="$TMP/c-bad3" expect_pass "a cache from another agy is ignored" \
  "$GOOD_STDOUT" --agy "$STUB" --out "$TMP/run-bad3" "$TMP/prompt.txt"
argv_has "another binary's cache does not answer for this one" \
  "--model" "gemini-3.8-flash"
expect_models_calls "another binary's cache is refetched" 1

: > "$STUB_MODELS_CALLS"
write_cache_file "$TMP/c-bad4" "{\"model\":\"gemini-4-flash\",\"agy\":\"$STUB\",\"fetched_at\":$((NOW - 200000))}"
XDG_CACHE_HOME="$TMP/c-bad4" expect_pass "an expired cache is ignored" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run-bad4" "$TMP/prompt.txt"
argv_has "an expired cache is replaced" "--model" "gemini-3.8-flash"
expect_models_calls "an expired cache is refetched" 1

: > "$STUB_MODELS_CALLS"
write_cache_file "$TMP/c-bad5" "{\"model\":\"gemini-4-flash\",\"agy\":\"$STUB\",\"fetched_at\":$((NOW + 200000))}"
XDG_CACHE_HOME="$TMP/c-bad5" expect_pass "a cache from the future is ignored" \
  "$GOOD_STDOUT" --agy "$STUB" --out "$TMP/run-bad5" "$TMP/prompt.txt"
expect_models_calls "a future-dated cache is refetched" 1

# A failed listing is remembered too, briefly: otherwise an offline machine pays the
# timeout on every single review.
: > "$STUB_MODELS_CALLS"
XDG_CACHE_HOME="$TMP/c-negcache" STUB_MODELS_RC=1 STUB_MODELS="" \
  STUB_MODELS_ERR="$TMP/models-err.txt" \
  expect_pass "a failed listing is recorded" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run-neg1" "$TMP/prompt.txt"
XDG_CACHE_HOME="$TMP/c-negcache" STUB_MODELS_RC=1 STUB_MODELS="" \
  STUB_MODELS_ERR="$TMP/models-err.txt" \
  expect_pass "the next run does not retry it" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run-neg2" "$TMP/prompt.txt"
expect_models_calls "a remembered failure is not retried every run" 1
argv_has "a remembered failure still yields the fallback model" \
  "--model" "gemini-3.8-flash"
expect_stderr "a remembered failure explains how to retry" "--refresh-models retries it"

: > "$STUB_MODELS_CALLS"
XDG_CACHE_HOME="$TMP/c-negcache" \
  expect_pass "--refresh-models retries a remembered failure" "$GOOD_STDOUT" \
  --agy "$STUB" --refresh-models --out "$TMP/run-neg3" "$TMP/prompt.txt"
expect_models_calls "--refresh-models overrides the remembered failure" 1
argv_has "the retry produces a real model" "--model" "gemini-3.8-flash"

# A --refresh-models that cannot reach the listing must keep the answer it already
# has rather than replacing a known-good id with the pinned fallback.
: > "$STUB_MODELS_CALLS"
XDG_CACHE_HOME="$TMP/c-keep" STUB_MODELS="$TMP/models-newer.txt" \
  expect_pass "a good answer is cached first" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run-keep1" "$TMP/prompt.txt"
argv_has "the cached answer is the newer generation" "--model" "gemini-4-flash"
XDG_CACHE_HOME="$TMP/c-keep" STUB_MODELS_RC=1 STUB_MODELS="" \
  STUB_MODELS_ERR="$TMP/models-err.txt" \
  expect_pass "a failed refresh still runs the review" "$GOOD_STDOUT" \
  --agy "$STUB" --refresh-models --out "$TMP/run-keep2" "$TMP/prompt.txt"
argv_has "a failed refresh keeps the cached id, not the fallback" \
  "--model" "gemini-4-flash"
argv_lacks "a failed refresh does not downgrade to the pinned id" "gemini-3.8-flash"
expect_stderr "a failed refresh says what it kept" "keeping the cached gemini-4-flash"
XDG_CACHE_HOME="$TMP/c-keep" STUB_MODELS="$TMP/models-newer.txt" \
  expect_pass "the cache survived the failed refresh" "$GOOD_STDOUT" \
  --agy "$STUB" --out "$TMP/run-keep3" "$TMP/prompt.txt"
argv_has "the next run still has the cached id" "--model" "gemini-4-flash"

# An unwritable cache directory is an inconvenience, not a failed review.
mkdir -p "$TMP/c-ro"
: > "$TMP/c-ro/agy-review"      # a FILE where the cache directory must go
XDG_CACHE_HOME="$TMP/c-ro" expect_pass "an unwritable cache does not fail the run" \
  "$GOOD_STDOUT" --agy "$STUB" --out "$TMP/run-ro" "$TMP/prompt.txt"
argv_has "an unwritable cache still resolves a model" "--model" "gemini-3.8-flash"
expect_stderr "an unwritable cache is warned about" "could not write the model cache"

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

# The two helpers added for model discovery must be able to go red as well.
run_bin --check "$TMP/good.json"    # a run whose stderr holds no warning at all
meta_expect_red "expect_stderr notices a message that is absent" \
  expect_stderr "META" "this string never appears on stderr"

: > "$STUB_MODELS_CALLS"
meta_expect_red "expect_models_calls notices the wrong count" \
  expect_models_calls "META" 7

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
