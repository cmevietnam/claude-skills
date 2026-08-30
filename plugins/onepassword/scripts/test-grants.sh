#!/usr/bin/env bash
# Regression tests for the approval windows (lib/grants.sh + the Pre/Post hook
# handshake). No 1Password, no Touch ID, no network.
#
#   bash scripts/test-grants.sh
#
# Every test runs the hooks with HOME pointed at a throwaway directory. That is
# deliberate rather than an OPGATE_STATE_HOME override: grants.sh refuses to read
# its location from the environment, because a redirectable grant directory is one
# an agent can point at grants it wrote itself.
set -uo pipefail

dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
pass=0 fail=0

tmp=$(mktemp -d "${TMPDIR:-/tmp}/opgate-grants.XXXXXX") || exit 1
trap 'rm -rf -- "$tmp"' EXIT
FAKEHOME="$tmp/home"
PROJ="$tmp/proj"
mkdir -p "$FAKEHOME" "$PROJ/sub" "$PROJ/certs"
# macOS puts mktemp under /var, which is a symlink to /private/var. Canonicalise
# now so the literal paths in these tests are the ones the guards will key on.
FAKEHOME=$(cd "$FAKEHOME" && pwd -P)
PROJ=$(cd "$PROJ" && pwd -P)
: >"$PROJ/.env"
: >"$PROJ/.env.production"

state="$FAKEHOME/.local/state/opgate"

reset() { rm -rf -- "$state"; }

# --- harness ----------------------------------------------------------------

# Run one hook script with the isolated HOME.
hook() { # <script> <json>
  printf '%s' "$2" | env HOME="$FAKEHOME" bash "$1"
}

decision() { # <script> <json>
  hook "$1" "$2" | sed -n 's/.*"permissionDecision":"\([a-z]*\)".*/\1/p'
}

# Call a grants.sh function under the isolated HOME.
lib() { # <shell-snippet>
  env HOME="$FAKEHOME" bash -c "source '$dir/lib/grants.sh'; $1"
}

ok_() { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
no_() { fail=$((fail + 1)); printf '  FAIL %s — %s\n' "$1" "$2"; }

want() { # <label> <got> <expected>
  local got="${2:-pass}"
  [[ "$got" == "$3" ]] && ok_ "$1" || no_ "$1" "got=$got want=$3"
}

# --- payloads ---------------------------------------------------------------

pre_read()  { python3 -c 'import json,sys;print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Read","tool_use_id":sys.argv[2],"cwd":sys.argv[3],"tool_input":{"file_path":sys.argv[1]}}))' "$1" "${2:-t1}" "${3:-$PROJ}"; }
pre_bash()  { python3 -c 'import json,sys;print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":sys.argv[2],"cwd":sys.argv[3],"tool_input":{"command":sys.argv[1]}}))' "$1" "${2:-t1}" "${3:-$PROJ}"; }
pre_grep()  { python3 -c 'import json,sys;print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Grep","tool_use_id":sys.argv[2],"cwd":sys.argv[3],"tool_input":{"pattern":"KEY","path":sys.argv[1]}}))' "$1" "${2:-t1}" "${3:-$PROJ}"; }
post()      { python3 -c 'import json,sys;print(json.dumps({"hook_event_name":"PostToolUse","tool_name":"Read","tool_use_id":sys.argv[1],"permission_mode":sys.argv[2],"session_id":"s1","cwd":sys.argv[3],"tool_input":{},"tool_output":"ok"}))' "${1:-t1}" "${2:-default}" "${3:-$PROJ}"; }

read_guard="$dir/guard-read.sh"
grep_guard="$dir/guard-grep.sh"
bash_guard="$dir/guard-bash.sh"
remember="$dir/remember-approval.sh"

# --- 1. the basic handshake -------------------------------------------------

echo "handshake — ask, approve, then allow until the window closes"
reset
want "first Read of .env asks" "$(decision "$read_guard" "$(pre_read "$PROJ/.env" a1)")" ask
hook "$remember" "$(post a1 default)" >/dev/null
want "second Read of .env is allowed" "$(decision "$read_guard" "$(pre_read "$PROJ/.env" a2)")" allow

echo "the window is per file, not per project"
want ".env.production still asks" "$(decision "$read_guard" "$(pre_read "$PROJ/.env.production" a3)")" ask

echo "the window is shared across tools"
want "cat .env is allowed too" "$(decision "$bash_guard" "$(pre_bash 'cat .env' a4)")" allow
want "Grep on .env is allowed too" "$(decision "$grep_guard" "$(pre_grep "$PROJ/.env" a5)")" allow

# --- 2. what must never open a window ---------------------------------------

echo "PostToolUse cannot invent an approval"
reset
hook "$remember" "$(post zz default)" >/dev/null
want "no pending record, no grant" "$(decision "$read_guard" "$(pre_read "$PROJ/.env" b1)")" ask

echo "permission modes where nothing was actually asked"
for mode in bypassPermissions dontAsk auto; do
  reset
  decision "$read_guard" "$(pre_read "$PROJ/.env" "c-$mode")" >/dev/null
  hook "$remember" "$(post "c-$mode" "$mode")" >/dev/null
  want "$mode records nothing" "$(decision "$read_guard" "$(pre_read "$PROJ/.env" "c2-$mode")")" ask
done

echo "an unrecognised mode must fail closed, not be assumed benign"
reset
decision "$read_guard" "$(pre_read "$PROJ/.env" d1)" >/dev/null
hook "$remember" "$(post d1 someFutureMode)" >/dev/null
want "unknown mode records nothing" "$(decision "$read_guard" "$(pre_read "$PROJ/.env" d2)")" ask

echo "modes where a prompt IS shown must record"
for mode in default plan acceptEdits; do
  reset
  decision "$read_guard" "$(pre_read "$PROJ/.env" "e-$mode")" >/dev/null
  hook "$remember" "$(post "e-$mode" "$mode")" >/dev/null
  want "$mode records" "$(decision "$read_guard" "$(pre_read "$PROJ/.env" "e2-$mode")")" allow
done

echo "a window never turns deny into allow"
reset
lib "grant_open '$PROJ/.env' 60 unlock s1" >/dev/null
want "op read still denied" "$(decision "$bash_guard" "$(pre_bash 'op read op://Dev/a/B' f1)")" deny
want "op item get still denied" "$(decision "$bash_guard" "$(pre_bash 'op item get app' f2)")" deny

echo "a payload with no tool_use_id still hands off (digest of tool_input)"
reset
noid_pre=$(python3 -c 'import json,sys;print(json.dumps({"hook_event_name":"PreToolUse","tool_name":"Read","cwd":sys.argv[2],"tool_input":{"file_path":sys.argv[1]}}))' "$PROJ/.env" "$PROJ")
noid_post=$(python3 -c 'import json,sys;print(json.dumps({"hook_event_name":"PostToolUse","tool_name":"Read","permission_mode":"default","session_id":"s1","cwd":sys.argv[2],"tool_input":{"file_path":sys.argv[1]},"tool_output":"ok"}))' "$PROJ/.env" "$PROJ")
want "still asks the first time" "$(decision "$read_guard" "$noid_pre")" ask
hook "$remember" "$noid_post" >/dev/null
want "and the window still opens" "$(decision "$read_guard" "$noid_pre")" allow

echo "a payload with no permission_mode records nothing"
reset
decision "$read_guard" "$(pre_read "$PROJ/.env" nm1)" >/dev/null
nomode=$(python3 -c 'import json,sys;print(json.dumps({"hook_event_name":"PostToolUse","tool_name":"Read","tool_use_id":"nm1","session_id":"s1","cwd":sys.argv[1],"tool_input":{},"tool_output":"ok"}))' "$PROJ")
hook "$remember" "$nomode" >/dev/null
want "missing mode is not 'default'" "$(decision "$read_guard" "$(pre_read "$PROJ/.env" nm2)")" ask

echo "a declined call leaves no window and no lingering pending record"
reset
decision "$read_guard" "$(pre_read "$PROJ/.env" dc1)" >/dev/null
# PostToolUse never runs for a declined call — simulate by not calling it at all.
want "still asks" "$(decision "$read_guard" "$(pre_read "$PROJ/.env" dc2)")" ask
[[ -d "$state/grants" ]] && no_ "no grant was written" "grants/ exists" || ok_ "no grant was written"

# --- 3. expiry and corruption must fail closed ------------------------------

echo "expiry"
reset
lib "grant_open '$PROJ/.env' 60 unlock s1" >/dev/null
slot=$(lib "grant_slot '$PROJ/.env'")
printf 'v1\t%s\tunlock\ts1\t%s\n' "$(( $(date +%s) - 1 ))" "$PROJ/.env" >"$state/grants/$slot"
want "expired one second ago asks" "$(decision "$read_guard" "$(pre_read "$PROJ/.env" g1)")" ask

echo "a grant file that does not parse is not a grant"
reset; mkdir -p "$state/grants"
printf 'v2\t9999999999\tunlock\ts1\t%s\n' "$PROJ/.env" >"$state/grants/$slot"
want "wrong version" "$(decision "$read_guard" "$(pre_read "$PROJ/.env" h1)")" ask
printf 'v1\tsoon\tunlock\ts1\t%s\n' "$PROJ/.env" >"$state/grants/$slot"
want "non-numeric expiry" "$(decision "$read_guard" "$(pre_read "$PROJ/.env" h2)")" ask
printf 'v1\t9999999999\tunlock\ts1\t%s\n' "$PROJ/.env.production" >"$state/grants/$slot"
want "path inside the file wins over the filename" "$(decision "$read_guard" "$(pre_read "$PROJ/.env" h3)")" ask
: >"$state/grants/$slot"
want "empty file" "$(decision "$read_guard" "$(pre_read "$PROJ/.env" h4)")" ask

echo "a stale pending record is not a fresh approval"
reset
decision "$read_guard" "$(pre_read "$PROJ/.env" i1)" >/dev/null
find "$state/pending" -type f -exec touch -t 200001010000 {} +
hook "$remember" "$(post i1 default)" >/dev/null
want "20-minute-old pending is dropped" "$(decision "$read_guard" "$(pre_read "$PROJ/.env" i2)")" ask

# --- 4. multi-file commands -------------------------------------------------

echo "a command touching two secret files needs both open"
reset
lib "grant_open '$PROJ/.env' 60 unlock s1" >/dev/null
want "one of two granted -> ask" "$(decision "$bash_guard" "$(pre_bash 'diff .env .env.production' j1)")" ask
lib "grant_open '$PROJ/.env.production' 60 unlock s1" >/dev/null
want "both granted -> allow" "$(decision "$bash_guard" "$(pre_bash 'diff .env .env.production' j2)")" allow

echo "approving the two-file command opens both"
reset
decision "$bash_guard" "$(pre_bash 'diff .env .env.production' k1)" >/dev/null
hook "$remember" "$(post k1 default)" >/dev/null
want "left file open"  "$(decision "$read_guard" "$(pre_read "$PROJ/.env" k2)")" allow
want "right file open" "$(decision "$read_guard" "$(pre_read "$PROJ/.env.production" k3)")" allow

# --- 5. canonicalisation ----------------------------------------------------

echo "the same file by a different spelling is the same window"
reset
lib "grant_open '$PROJ/.env' 60 unlock s1" >/dev/null
want "sub/../.env"       "$(decision "$read_guard" "$(pre_read "$PROJ/sub/../.env" l1)")" allow
want "relative .env"     "$(decision "$bash_guard" "$(pre_bash 'cat .env' l2)")" allow
want "relative sub/../.env" "$(decision "$bash_guard" "$(pre_bash 'cat sub/../.env' l3)")" allow
want "a different cwd is a different file" \
  "$(decision "$bash_guard" "$(pre_bash 'cat .env' l4 "$PROJ/sub")")" ask

echo "two paths that squeeze to the same slot do not share a window"
reset
: >"$PROJ/.env.a b"; : >"$PROJ/.env.a_b"
lib "grant_open '$PROJ/.env.a b' 60 unlock s1" >/dev/null
s1=$(lib "grant_slot '$PROJ/.env.a b'"); s2=$(lib "grant_slot '$PROJ/.env.a_b'")
[[ "$s1" == "$s2" ]] && ok_ "the two paths really do collide" \
  || no_ "the two paths really do collide" "slots differ, test proves nothing"
want "the granted one is allowed" \
  "$(decision "$read_guard" "$(pre_read "$PROJ/.env.a b" m0)")" allow
want "the collided neighbour still asks" \
  "$(decision "$read_guard" "$(pre_read "$PROJ/.env.a_b" m1)")" ask

# --- 6. lock / grants -------------------------------------------------------

echo "lock and grants"
reset
lib "grant_open '$PROJ/.env' 60 unlock s1" >/dev/null
lib "grant_open '$PROJ/.env.production' 60 auto s1" >/dev/null
n=$(lib "grant_list | wc -l | tr -d ' '")
want "two windows listed" "$n" 2
n=$(lib "grant_revoke_all")
want "revoke_all closes both" "$n" 2
want "and the guard asks again" "$(decision "$read_guard" "$(pre_read "$PROJ/.env" n1)")" ask

reset
lib "grant_open '$PROJ/.env' 60 unlock s1" >/dev/null
lib "grant_open '$PROJ/.env.production' 60 unlock s1" >/dev/null
lib "grant_revoke '$PROJ/.env'" >/dev/null
want "revoking one leaves the other" \
  "$(decision "$read_guard" "$(pre_read "$PROJ/.env.production" o1)")" allow
want "and closes the one named"     \
  "$(decision "$read_guard" "$(pre_read "$PROJ/.env" o2)")" ask

echo "an expired window is swept out of the listing"
reset
lib "grant_open '$PROJ/.env' 60 unlock s1" >/dev/null
printf 'v1\t%s\tunlock\ts1\t%s\n' "$(( $(date +%s) - 1 ))" "$PROJ/.env" >"$state/grants/$(lib "grant_slot '$PROJ/.env'")"
n=$(lib "grant_list | wc -l | tr -d ' '")
want "nothing listed" "$n" 0

# --- 7. auditability --------------------------------------------------------

echo "every window opened and used leaves a record"
reset
decision "$read_guard" "$(pre_read "$PROJ/.env" p1)" >/dev/null
hook "$remember" "$(post p1 default)" >/dev/null
decision "$read_guard" "$(pre_read "$PROJ/.env" p2)" >/dev/null
log="$state/access.log"
grep -q 'GRANT	' "$log" 2>/dev/null && ok_ "opening is logged" || no_ "opening is logged" "no GRANT record"
grep -q 'GRANT-USED' "$log" 2>/dev/null && ok_ "use is logged" || no_ "use is logged" "no GRANT-USED record"
grep -q '	auto	' "$log" 2>/dev/null && ok_ "the record says it was automatic" \
  || no_ "the record says it was automatic" "origin missing from the action field"
perms=$(stat -f %Lp "$log" 2>/dev/null || stat -c %a "$log" 2>/dev/null)
want "audit log is 600" "$perms" 600
perms=$(stat -f %Lp "$state/grants" 2>/dev/null || stat -c %a "$state/grants" 2>/dev/null)
want "grants dir is 700" "$perms" 700

echo "nothing outside the isolated HOME was touched"
if [[ -e "$tmp/../.local/state/opgate/grants" ]]; then
  no_ "state stayed inside HOME" "wrote outside the fake HOME"
else
  ok_ "state stayed inside HOME"
fi

# --- 8. the unguarded majority must stay cheap and silent -------------------

echo "unrelated calls are untouched"
reset
want "Read of README" "$(decision "$read_guard" "$(pre_read "$PROJ/README.md" q1)")" pass
want "npm test"       "$(decision "$bash_guard" "$(pre_bash 'npm test' q2)")" pass
hook "$remember" "$(post q2 default)" >/dev/null
[[ -d "$state/grants" ]] && no_ "no grant dir is created for unguarded calls" "grants/ exists" \
  || ok_ "no grant dir is created for unguarded calls"

start=$(date +%s)
for i in 1 2 3 4 5 6 7 8 9 10; do hook "$remember" "$(post "none-$i" default)" >/dev/null; done
elapsed=$(( $(date +%s) - start ))
(( elapsed < 5 )) && ok_ "10 no-op PostToolUse calls in ${elapsed}s" \
  || no_ "10 no-op PostToolUse calls" "${elapsed}s is too slow for a per-tool-call hook"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
