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

pass=0
fail=0

note_pass() { echo "ok    $1"; pass=$((pass + 1)); }
note_fail() { echo "FAIL  $1"; fail=$((fail + 1)); }

# run_bin -- runs $BIN with the given args. Streams are captured SEPARATELY: a wrapper
# that printed the review to stderr must not be able to satisfy a stdout assertion.
run_bin() {
  # Drop any previous argv capture so a stale one cannot satisfy this run's assertions.
  rm -f "${STUB_ARGV:-/dev/null}" 2>/dev/null || true
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
  if [ -z "$OUT" ]; then
    note_fail "$name: no output at all — the check did not run"
  elif [ "$RC" -eq 0 ]; then
    note_fail "$name: exited 0, should have failed"
  elif [ "$RC" -ne "$want_rc" ]; then
    note_fail "$name: exit $RC, expected $want_rc — got: ${OUT:0:120}"
  elif ! printf '%s' "$OUT" | grep -q -- "$want"; then
    note_fail "$name: exit $RC but message lacked '$want' — got: ${OUT:0:160}"
  else
    note_pass "$name"
  fi
}

# An argv assertion is only meaningful if the capture exists. Without this guard, a
# missing capture makes every grep fail, which argv_lacks would read as "absent" — the
# same silence-passes bug this suite exists to prevent.
argv_capture_ok() {
  local name="$1"
  if [ ! -s "$STUB_ARGV" ]; then
    note_fail "$name: no argv capture at $STUB_ARGV — the stub never ran"
    return 1
  fi
  return 0
}

# argv_has NAME EXPECTED... -- every string must appear as its own argv entry
argv_has() {
  local name="$1"; shift
  argv_capture_ok "$name" || return
  local missing=""
  for want in "$@"; do
    grep -qxF -- "$want" "$STUB_ARGV" || missing="$missing $want"
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
    grep -qxF -- "$bad" "$STUB_ARGV" && present="$present $bad"
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
expect_fail "usage is not an object"   1 "not an object"           --check "$TMP/usage-string.json"

# --check is about an existing envelope; run options alongside it mean a mistyped command
expect_fail "--check with a prompt file"  2 "takes no run options" \
  --check "$TMP/good.json" "$TMP/prompt.txt"
expect_fail "--check with --out"          2 "takes no run options" \
  --check "$TMP/good.json" --out "$TMP/somewhere"

expect_pass "real review"              "$GOOD_STDOUT"            --check "$TMP/good.json"
expect_pass "NO FINDINGS is a result"  "NO FINDINGS"             --check "$TMP/good-no-findings.json"
expect_pass "non-ASCII response"       "Finding 1 — cấu hình → hỏng" --check "$TMP/utf8.json"

# --- run-path cases, driven by a stub agy --------------------------------------------

STUB="$TMP/stub-agy"
cat > "$STUB" <<'EOF'
#!/bin/bash
# Records its argv, then emits whatever the fixture files dictate.
printf '%s\n' "$@" > "$STUB_ARGV"
cat "$STUB_STDOUT"
[ -n "${STUB_STDERR:-}" ] && cat "$STUB_STDERR" >&2
exit "${STUB_RC:-0}"
EOF
chmod +x "$STUB"

export STUB_ARGV="$TMP/argv.txt"
export STUB_STDOUT="$TMP/good.json"
export STUB_RC=0

printf 'review this please\n' > "$TMP/prompt.txt"
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

# The invocation contract, not just the flags: `agy -p` does not read stdin, so the
# prompt MUST arrive as the argument after -p. Without this a wrapper that dropped the
# prompt entirely would leave the suite green.
argv_has "prompt is passed via -p, with its exact contents" \
  "-p" "$(cat "$TMP/prompt.txt")"
argv_has "gemini id gets --model and default --effort high" \
  "--model" "gemini-3.8-flash" "--effort" "high" \
  "--disable-slash-commands" "--output-format" "json" \
  "--print-timeout" "9m"

# -p and the prompt must be adjacent, in that order. The stub records "$@", so the
# first flag is line 1 and its value line 2.
if [ "$(grep -n -xF -- "-p" "$STUB_ARGV" | cut -d: -f1)" = "1" ] &&
   [ "$(sed -n '2p' "$STUB_ARGV")" = "$(cat "$TMP/prompt.txt")" ]; then
  note_pass "prompt immediately follows -p in argv"
else
  note_fail "prompt does not immediately follow -p in argv (line1=$(sed -n '1p' "$STUB_ARGV"))"
fi

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

# --- meta-tests: prove each helper can actually go red -------------------------------
# Without these, a crashing binary or a mis-wired assertion would make cases pass by
# accident — which is exactly the defect this suite exists to catch in agy itself.

# meta_expect_red DESCRIPTION -- <a deliberately wrong assertion>
meta_expect_red() {
  local what="$1"; shift
  local before=$fail
  "$@" >/dev/null 2>&1
  if [ "$fail" -eq $((before + 1)) ]; then
    fail=$before               # the deliberate failure is the expected result
    pass=$((pass - 1)) 2>/dev/null || true
    pass=$((pass + 1))
    note_pass "meta: $what"
  else
    note_fail "meta: $what — the harness did NOT detect it; every result is suspect"
  fi
}

meta_expect_red "expect_pass rejects a denied envelope" \
  expect_pass "META" "$GOOD_STDOUT" --check "$TMP/denied.json"

meta_expect_red "expect_fail rejects the wrong exit code" \
  expect_fail "META" 99 "empty output file" --check "$TMP/zero-byte.json"

meta_expect_red "expect_fail rejects the wrong message" \
  expect_fail "META" 1 "this string never appears" --check "$TMP/zero-byte.json"

meta_expect_red "argv_has notices a missing argument" \
  argv_has "META" "--this-flag-was-never-passed"

meta_expect_red "argv_lacks notices an argument that is present" \
  argv_lacks "META" "--model"

# The subtle one: with no capture at all, every grep fails, which a naive argv_lacks
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
