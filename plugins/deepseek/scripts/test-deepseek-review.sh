#!/bin/bash
# Tests for bin/deepseek-review, written BEFORE the wrapper (strict TDD).
#
# Every case asserts a marker only the check under test emits (`deepseek-review: ERROR <CODE>:`,
# `deepseek-review: FAIL <CODE>:`, a stub record field, a fence probe result). Silence is never a
# pass: an empty capture, a missing record or a case that ran no check fails. Each case prints ONE
# verdict line listing every failed check under it; META cases prove the assertion helpers, the
# stub and the fence checker can go red (and green), so a red case means the wrapper lacks the
# behaviour, not that the harness is broken.
#
# The run-path cases drive a stub dsh (fixtures/stub-dsh.mjs) installed in a fresh dsh dir per
# case; the stub records argv, execPath, cwd, env, stdin and fence probe results under
# $HOME=<out>/home. No network, no real key: HOME is $TMP/fakehome, the key is fake.
#
# Real-dsh cases are gated by the harness-only DSH_REAL_DIR (a dir holding
# node_modules/@deepseek-ai/dsh/lib/bin.js at 0.2.1-rc.5); they talk to a loopback mock only.
#
# Run: bash plugins/deepseek/scripts/test-deepseek-review.sh
#      DSH_REAL_DIR=/path/to/dsh-install bash plugins/deepseek/scripts/test-deepseek-review.sh

set -uo pipefail
umask 077

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN="$(cd "$HERE/.." && pwd -P)"
BIN="$PLUGIN/bin/deepseek-review"
FIX="$HERE/fixtures"
PINNED=0.2.1-rc.5

# A failed mktemp would leave TMP empty and turn `rm -rf "$TMP"` into a very bad line.
TMP="$(mktemp -d)" || { echo "FATAL: mktemp -d failed"; exit 1; }
if [ -z "$TMP" ] || [ ! -d "$TMP" ]; then
  echo "FATAL: mktemp -d produced no usable directory (got '${TMP}')"
  exit 1
fi
TMP_REAL="$(cd "$TMP" && pwd -P)"
case "$TMP_REAL" in
  /*/*) ;;
  *) echo "FATAL: suspicious temp dir '$TMP_REAL'"; exit 1 ;;
esac
RUNID="dsr$$x$RANDOM$RANDOM"
cleanup() {
  # Anything still running from this run carries a path under TMP_REAL or the RUNID marker.
  pkill -9 -f "$RUNID" 2>/dev/null
  pkill -9 -f "$TMP_REAL/" 2>/dev/null
  # The R3 /tmp control's own dir (the only path this script writes outside TMP).
  case "${R3_TMPDIR:-}" in /tmp/dsr-r3.?*) rm -rf "$R3_TMPDIR" ;; esac
  # The R3b auto-out case's node file in the per-user temp dir.
  case "${R3_TDNODE:-}" in */dsr-node-?*) rm -f "$R3_TDNODE" ;; esac
  # Out dirs this run left in the per-user temp dir (a doctor or an auto out killed before its own
  # cleanup, as under a mutant): only those whose fence names a path under this run's TMP_REAL.
  local td f d
  td="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"
  if [ -n "$td" ] && [ -n "${TMP_REAL:-}" ]; then
    for f in "${td%/}"/deepseek-review-*/fence-1.sb; do
      [ -f "$f" ] && grep -qF "\"$TMP_REAL/" "$f" || continue
      d="$(dirname "$f")"
      case "$d" in */deepseek-review-?*)
        echo "WARNING: cleanup removed a leftover out dir of this run: $d" >&2
        chmod -R u+rwx "$d" 2>/dev/null; rm -rf "$d" ;; esac
    done
  fi
  chflags -R nouchg "$TMP" 2>/dev/null
  chmod -R u+rwx "$TMP" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

PY="$(command -v python3)" || { echo "FATAL: python3 not on PATH"; exit 1; }
NODE_WHICH="$(command -v node)" || { echo "FATAL: node not on PATH"; exit 1; }
NODE_REAL="$("$PY" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$NODE_WHICH")"
for tool in perl git /usr/bin/sandbox-exec pgrep; do
  command -v "$tool" >/dev/null || { echo "FATAL: $tool not found"; exit 1; }
done
[ -x "$BIN" ] || { echo "FATAL: $BIN missing or not executable"; exit 1; }

# In a deselected block tl does nothing (fabricate still builds its fixture dir).
tl() {
  if [ -z "$SEL" ] && [ "$1" != fabricate ]; then return 0; fi
  "$PY" -I "$FIX/tlib.py" "$@"
}
psleep() { perl -e "select(undef,undef,undef,$1)"; }
now() { perl -MTime::HiRes=time -e 'printf "%.2f", time'; }
realp() { "$PY" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }

# --- shared fixtures --------------------------------------------------------------------------

FAKEHOME="$TMP_REAL/fakehome"
mkdir -p "$FAKEHOME/.ssh" "$FAKEHOME/src"
printf 'SSH-SECRET-SENTINEL\n' > "$FAKEHOME/.ssh/id_test"
OUTSIDE="$TMP_REAL/outside"
mkdir -p "$OUTSIDE"
printf 'OUTSIDE-SECRET-SENTINEL\n' > "$OUTSIDE/secret.txt"
# The wrapper finds node through PATH; this dir holds only a node symlink, so no real npm (or
# anything else from the caller's toolchain) is reachable through it.
NODEBIN="$TMP_REAL/nodebin"
mkdir -p "$NODEBIN"
ln -s "$NODE_REAL" "$NODEBIN/node"
WPATH="$NODEBIN:/usr/bin:/bin:/usr/sbin:/sbin"
FAKEKEY="FAKE-test-key-0123456789"       # length 24
PROMPT_TEXT=$'Review the change in this repository.\nStart with sentinel.txt.\n'
MODEL_LINE="model: deepseek-flash (default), effort max, max_tokens 393216, endpoint api.deepseek.com"
SSH_CONFIG=/private/etc/ssh/ssh_config
# The account's real home (pw_dir): a case that sets HOME elsewhere must still find it protected.
# Cases only resolve paths under it; nothing is ever written there.
PW_HOME="$("$PY" -I -c 'import os, pwd; print(os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir))')"
case "$PW_HOME" in /?*/?*) [ -d "$PW_HOME" ] || { echo "FATAL: pw_dir $PW_HOME is not a dir"; exit 1; } ;;
  *) echo "FATAL: suspicious pw_dir '$PW_HOME'"; exit 1 ;; esac

pass=0
fail=0
skip=0
note_pass() { echo "ok    $1"; pass=$((pass + 1)); }
note_fail() { printf 'FAIL  %s\n' "$1"; fail=$((fail + 1)); }
note_skip() { echo "SKIP $1"; skip=$((skip + 1)); }

# --- case selection (DSR_ONLY) ----------------------------------------------------------------
# DSR_ONLY=<ERE> (bash =~) runs only the case BLOCKS whose new_case name matches; the META
# section and the shared fixtures always run. A deselected block runs no wrapper and no check
# helper (run_w, run_w_bg, bg_wait, wait_stub and tl return at once) and each of its cases
# prints `DESEL [<block>] <verdict>`, counted apart from passed/failed/skipped, so a case that
# was meant to run but was deselected can never read as a pass. Unset = every block runs.
# The mutation harness (mutate-deepseek-review.sh) lists blocks with DSR_ONLY='^$'.
DSR_ONLY="${DSR_ONLY:-}"
SEL=1        # the current block is selected
SEL_ON=""    # selection applies (set after the META section)
desel=0
if [ -n "$DSR_ONLY" ]; then
  [[ "probe" =~ $DSR_ONLY ]]
  [ $? -le 1 ] || { echo "FATAL: DSR_ONLY is not a valid ERE: $DSR_ONLY"; exit 1; }
fi
sel_block() { # BLOCK-NAME
  SEL_BLOCK="$1"
  if [ -z "$DSR_ONLY" ] || [ -z "$SEL_ON" ]; then SEL=1
  elif [[ "$1" =~ $DSR_ONLY ]]; then SEL=1
  else SEL=""; fi
}
note_desel() { echo "DESEL [$SEL_BLOCK] $1"; desel=$((desel + 1)); }

# --- case machinery ---------------------------------------------------------------------------
# A case collects checks; case_end prints one verdict. A case with zero checks is a FAIL.

case_begin() { CASE="$1"; CASE_ERRS=""; CASE_CHECKS=0; }
c_ok() { CASE_CHECKS=$((CASE_CHECKS + 1)); }
c_bad() {
  CASE_CHECKS=$((CASE_CHECKS + 1))
  CASE_ERRS="$CASE_ERRS
      - $1"
}
case_end() {
  if [ -z "$SEL" ]; then
    note_desel "$CASE"
  elif [ -n "$CASE_ERRS" ]; then
    note_fail "$CASE$CASE_ERRS"
  elif [ "$CASE_CHECKS" -eq 0 ]; then
    note_fail "$CASE: no check ran (silence is not a pass)"
  else
    note_pass "$CASE"
  fi
}
# c_tl LABEL tlib-args... : a tlib check; its printed problems become the failure text.
c_tl() {
  local label="$1" o
  shift
  if o="$(tl "$@" 2>&1)"; then c_ok; else c_bad "$label: ${o:-tlib exited non-zero and printed nothing}"; fi
}

CASE_N=0
new_case() {
  CASE_N=$((CASE_N + 1))
  CNAME="$1"
  sel_block "$1"
  C="$TMP_REAL/c/$CASE_N"
  mkdir -p "$C"
  OUT="$C/out"
  DSH="$C/dsh"
  REPO="$FAKEHOME/src/r$CASE_N"
  PROMPT="$C/prompt.txt"
  printf '%s' "$PROMPT_TEXT" > "$PROMPT"
  rm -f "$FAKEHOME"/stub-*.json
  REC=""
}

# make_dsh DIR KIND [scenario args...] -- a stub dsh install (0700) with its scenario.json.
make_dsh() {
  local dir="$1"
  shift
  local pkg="$dir/node_modules/@deepseek-ai/dsh"
  mkdir -p "$pkg/lib"
  cp "$FIX/stub-dsh.mjs" "$pkg/lib/bin.js"
  printf '{"name":"@deepseek-ai/dsh","version":"%s","type":"module","bin":{"dsh":"lib/bin.js"}}\n' \
    "$PINNED" > "$pkg/package.json"
  tl scenario "$pkg/lib/scenario.json" "$@" || { echo "FATAL: scenario builder failed for $*"; exit 1; }
}
set_scenario() { tl scenario "$DSH/node_modules/@deepseek-ai/dsh/lib/scenario.json" "$@" || exit 1; }

# make_repo DIR -- a git work tree with a sentinel, a .env the fence must deny, and src/.
make_repo() {
  mkdir -p "$1/src"
  git -C "$1" init -q || { echo "FATAL: git init $1"; exit 1; }
  printf 'SENTINEL-REPO\n' > "$1/sentinel.txt"
  printf 'DEEPSEEK_API_KEY=ENV-FILE-SENTINEL\n' > "$1/.env"
  printf 'a\n' > "$1/src/a.txt"
}

# copy_node_tree DESTPREFIX -- COPIES of node (and its ../lib dylibs, which Homebrew's node
# loads through @loader_path/../lib) under DESTPREFIX/{bin,lib}. Never hard links: macOS can hand
# dyld ANY name of a hard-linked file, so @loader_path/../lib of the linked node (or of NODE_REAL
# itself, in a later case) could point at a dir the fence never allowed (observed: the nvm case
# saw /opt/homebrew/Cellar/node/<v>/bin/../lib under a fence for fakehome/.nvm).
copy_node_tree() {
  local src_prefix f
  src_prefix="$(dirname "$(dirname "$NODE_REAL")")"
  mkdir -p "$1/bin" "$1/lib"
  cp -p "$NODE_REAL" "$1/bin/node" || { echo "FATAL: cannot copy node to $1/bin"; exit 1; }
  if [ -d "$src_prefix/lib" ]; then
    for f in "$src_prefix"/lib/*.dylib; do
      [ -e "$f" ] || continue
      cp -p "$f" "$1/lib/" || { echo "FATAL: cannot copy $f"; exit 1; }
    done
  fi
}
# h_node_links [FILE...] -- each FILE (default: NODE_REAL and its ../lib dylibs) has link count 1
# (no harness hard link).
h_node_links() {
  local f n
  if [ $# -eq 0 ]; then set -- "$NODE_REAL" "$(dirname "$(dirname "$NODE_REAL")")"/lib/*.dylib; fi
  for f in "$@"; do
    [ -e "$f" ] || continue
    n="$(stat -f %l "$f")"
    if [ "$n" = 1 ]; then c_ok; else c_bad "$f has $n hard links (dyld may load through another name)"; fi
  done
}

# --- running the wrapper ----------------------------------------------------------------------
# run_w [OPTS...] -- ARGS...   OPTS: CWD= UMASK= ALARM= PATH= HOME= KEY= NOKEY NOLANG ENV:N=V
# The wrapper gets ONLY the environment listed here (env -i), so the caller's shell cannot leak
# a real key or toolchain into a case. Streams are captured separately.
_w_opts() {
  W_CWD="$C"; W_UMASK=077; W_ALARM=90; W_PATH="$WPATH"; W_HOME="$FAKEHOME"; W_KEY="$FAKEKEY"
  W_NOKEY=""; W_LANG="en_US.UTF-8"; W_EXTRA=(); W_NOPTS=0
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    case "$1" in
      CWD=*) W_CWD="${1#CWD=}" ;;
      UMASK=*) W_UMASK="${1#UMASK=}" ;;
      ALARM=*) W_ALARM="${1#ALARM=}" ;;
      PATH=*) W_PATH="${1#PATH=}" ;;
      HOME=*) W_HOME="${1#HOME=}" ;;
      KEY=*) W_KEY="${1#KEY=}" ;;
      NOKEY) W_NOKEY=1 ;;
      NOLANG) W_LANG="" ;;
      ENV:*) W_EXTRA+=("${1#ENV:}") ;;
      *) echo "FATAL: run_w: unknown option '$1'"; exit 1 ;;
    esac
    shift
    W_NOPTS=$((W_NOPTS + 1))
  done
  [ "${1:-}" = "--" ] || { echo "FATAL: run_w needs -- before the wrapper args"; exit 1; }
  W_NOPTS=$((W_NOPTS + 1))
  W_ENVV=("HOME=$W_HOME" "PATH=$W_PATH")
  [ -n "$W_LANG" ] && W_ENVV+=("LANG=$W_LANG")
  [ -z "$W_NOKEY" ] && W_ENVV+=("DEEPSEEK_API_KEY=$W_KEY")
  W_ENVV+=(${W_EXTRA[@]+"${W_EXTRA[@]}"})
}
_w_collect() {
  STDOUT="$(cat "$C/stdout"; printf x)"; STDOUT="${STDOUT%x}"
  STDERR="$(cat "$C/stderr"; printf x)"; STDERR="${STDERR%x}"
}
run_w() {
  _w_opts "$@"
  shift "$W_NOPTS"
  if [ -z "$SEL" ]; then RC=99; STDOUT=""; STDERR=""; return 0; fi
  (
    cd "$W_CWD" || exit 97
    umask "$W_UMASK"
    exec perl -e 'alarm shift @ARGV; exec @ARGV or die "exec failed: $!\n"' "$W_ALARM" \
      /usr/bin/env -i "${W_ENVV[@]}" "$BIN" "$@"
  ) >"$C/stdout" 2>"$C/stderr" </dev/null
  RC=$?
  _w_collect
}
# run_w_bg: same, in the background, with INT/TERM/HUP restored to default (a job started with
# & from a non-interactive bash inherits SIGINT ignored). Sets BGPID (= the wrapper's pid:
# subshell, perl and env all exec).
run_w_bg() {
  _w_opts "$@"
  shift "$W_NOPTS"
  if [ -z "$SEL" ]; then BGPID=""; return 0; fi
  (
    cd "$W_CWD" || exit 97
    umask "$W_UMASK"
    exec perl -e '$SIG{$_} = "DEFAULT" for qw(INT TERM HUP); alarm shift @ARGV;
                  exec @ARGV or die "exec failed: $!\n"' "$W_ALARM" \
      /usr/bin/env -i "${W_ENVV[@]}" "$BIN" "$@"
  ) >"$C/stdout" 2>"$C/stderr" </dev/null &
  BGPID=$!
}
# bg_wait SECS -- wait for BGPID; RC=255 and BG_HUNG=1 if it outlived SECS (then SIGKILLed).
bg_wait() {
  if [ -z "$SEL" ]; then RC=99; BG_HUNG=""; STDOUT=""; STDERR=""; return 0; fi
  local i=0 lim=$(($1 * 10))
  while kill -0 "$BGPID" 2>/dev/null && [ "$i" -lt "$lim" ]; do psleep 0.1; i=$((i + 1)); done
  if kill -0 "$BGPID" 2>/dev/null; then
    kill -9 "$BGPID" 2>/dev/null
    wait "$BGPID" 2>/dev/null
    RC=255
    BG_HUNG=1
  else
    wait "$BGPID"
    RC=$?
    BG_HUNG=""
  fi
  _w_collect
}
# wait_stub SECS -- until the stub's main record appears under OUT or the wrapper is gone.
wait_stub() {
  [ -n "$SEL" ] || return 1
  local i=0 lim=$(($1 * 10))
  while [ "$i" -lt "$lim" ]; do
    [ -n "$(tl find-records record "$OUT")" ] && return 0
    kill -0 "$BGPID" 2>/dev/null || return 1
    psleep 0.1
    i=$((i + 1))
  done
  return 1
}
wr() { run_w -- --dsh-dir "$DSH" --out "$OUT" "$@"; }

# --- assertion helpers (pure: they read RC/STDOUT/STDERR/OUT/REC) -----------------------------

sorted_words() { printf '%s\n' "$@" | grep . | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ $//'; }
first_line() { printf '%s' "$1" | head -c 240 | tr '\n' '|'; }

h_rc() {
  if [ "$RC" = "$1" ]; then c_ok; else c_bad "exit $RC, expected $1 — stderr: $(first_line "$STDERR")"; fi
}
h_stdout_empty() {
  if [ -z "$STDOUT" ]; then c_ok; else c_bad "stdout not empty: $(first_line "$STDOUT")"; fi
}
h_stderr_has() {
  if [ -z "$STDERR" ]; then
    c_bad "stderr empty (wanted '$1')"
  elif printf '%s' "$STDERR" | grep -qF -- "$1"; then
    c_ok
  else
    c_bad "stderr lacks '$1' — got: $(first_line "$STDERR")"
  fi
}
# h_stderr_line_starts PREFIX -- some stderr line begins with PREFIX (fixed string).
h_stderr_line_starts() {
  if printf '%s' "$STDERR" | "$PY" -c '
import sys
p = sys.argv[1]
sys.exit(0 if any(l.startswith(p) for l in sys.stdin.read().splitlines()) else 1)' "$1"; then
    c_ok
  else
    c_bad "no stderr line starts with '$1' — got: $(first_line "$STDERR")"
  fi
}
# h_text_lacks LABEL NEEDLE TEXT -- negative; every use sits beside a positive check of the same run.
h_text_lacks() {
  if printf '%s' "$3" | grep -qF -- "$2"; then c_bad "$1: contains '$2'"; else c_ok; fi
}
h_no_traceback() {
  if printf '%s' "$STDERR" | grep -q 'Traceback (most recent call last)'; then
    c_bad "died with a traceback"
  else
    c_ok
  fi
}
h_setup() {
  h_rc 2
  h_stdout_empty
  h_stderr_has "deepseek-review: ERROR $1:"
  h_no_traceback
}
# h_no_stub DIR... -- the stub (main run OR the --version call) never ran: no record anywhere.
h_no_stub() {
  local hits
  hits="$(tl find-records any "$@" "$FAKEHOME")"
  if [ -z "$hits" ]; then c_ok; else c_bad "the stub ran: $(printf '%s' "$hits" | tr '\n' ' ')"; fi
}
# h_record -- exactly one main stub record under OUT; sets REC.
h_record() {
  local hits n
  hits="$(tl find-records record "$OUT")"
  n="$(printf '%s' "$hits" | grep -c .)"
  if [ "$n" = 1 ]; then
    REC="$hits"
    c_ok
  else
    REC=""
    c_bad "expected 1 stub record under <out>/home, found $n (stub never ran with HOME=<out>/home)"
  fi
}
h_rec_eq() { # LABEL FIELD JSON
  if [ -z "$REC" ]; then c_bad "$1: no stub record"; return; fi
  local got
  got="$(tl rec "$REC" "$2" 2>&1)"
  if [ "$got" = "$3" ]; then c_ok; else c_bad "$1: $2=$got, expected $3"; fi
}
h_fail_codes() { # "CODES" exact|contains
  local got want
  got="$(printf '%s' "$STDERR" | tl codes FAIL)"
  want="$(sorted_words $1)"
  h_rc 1
  h_stdout_empty
  h_no_traceback
  for c in $1; do
    case " $got " in
      *" $c "*) c_ok ;;
      *) c_bad "no 'deepseek-review: FAIL $c:' line (FAIL codes seen: ${got:-none})" ;;
    esac
  done
  if [ "$2" = exact ] && [ "$got" != "$want" ]; then
    c_bad "FAIL codes '${got:-none}', expected exactly '$want'"
  fi
}
# h_fail_line_has CODE TEXT -- the FAIL line for CODE carries TEXT (e.g. the turn_end kind).
h_fail_line_has() {
  if printf '%s' "$STDERR" | grep "^deepseek-review: FAIL $1:" | grep -qF -- "$2"; then
    c_ok
  else
    c_bad "the FAIL $1 line does not name '$2'"
  fi
}
# h_fail_once CODE -- exactly one FAIL line for CODE (h_fail_codes compares a sorted set).
h_fail_once() {
  local k
  k="$(printf '%s\n' "$STDERR" | grep -c "^deepseek-review: FAIL $1:" || true)"
  if [ "$k" = 1 ]; then
    c_ok
  else
    c_bad "${k:-0} 'deepseek-review: FAIL $1:' lines, expected exactly 1"
  fi
}
# h_pass_stdout EXPECTED_FILE -- exit 0 and stdout byte-identical to the file.
h_pass_stdout() {
  h_rc 0
  if [ -z "$STDOUT" ]; then
    c_bad "stdout empty — no answer printed"
  elif [ ! -f "$1" ]; then
    c_bad "no expected answer (stub record missing)"
  elif cmp -s "$C/stdout" "$1"; then
    c_ok
  else
    c_bad "stdout differs from the final text + newline: got $(printf '%q' "${STDOUT:0:160}")"
  fi
}
h_pass() { # stdout == final text of the stub + "\n"
  h_record
  if [ -n "$REC" ]; then tl final-text "$REC" "$C/expected" >/dev/null 2>&1 || rm -f "$C/expected"; fi
  h_pass_stdout "$C/expected"
}
# h_status N -- status-N.json verdict/reasons agree with this run's exit and FAIL lines.
h_status() {
  local got want codes
  got="$(tl status-reasons "$OUT/status-$1.json")"
  codes="$(printf '%s' "$STDERR" | tl codes FAIL)"
  if [ "$RC" = 0 ]; then want="PASS"; else want="$(printf 'FAIL %s' "$codes" | sed 's/ $//')"; fi
  if [ "$got" = "$want" ]; then c_ok; else c_bad "status-$1.json says '$got', the run said '$want'"; fi
}
# h_compare LRC LCODES LOUT CRC CCODES COUT -- a --check verdict equals the live one.
h_compare() {
  case "$4" in 0 | 1) c_ok ;; *) c_bad "--check exit $4 (not a verdict)" ;; esac
  if [ "$1" = "$4" ] && [ "$2" = "$5" ] && [ "$3" = "$6" ]; then
    c_ok
  else
    c_bad "--check disagrees: live exit $1 codes '$2', --check exit $4 codes '$5'$([ "$3" = "$6" ] || echo ', stdout differs')"
  fi
}
# h_check_agrees [--check args...] -- run --check on OUT; same verdict, files untouched.
h_check_agrees() {
  local lrc="$RC" lout="$STDOUT" lerr="$STDERR" lcodes before after ccodes
  lcodes="$(printf '%s' "$lerr" | tl codes FAIL)"
  before="$(tl tree-hash "$OUT" 2>/dev/null)"
  run_w -- --check "$OUT" "$@"
  after="$(tl tree-hash "$OUT" 2>/dev/null)"
  ccodes="$(printf '%s' "$STDERR" | tl codes FAIL)"
  h_compare "$lrc" "$lcodes" "$lout" "$RC" "$ccodes" "$STDOUT"
  if [ -n "$before" ] && [ "$before" = "$after" ]; then c_ok; else c_bad "--check changed files under out"; fi
  RC="$lrc"; STDOUT="$lout"; STDERR="$lerr"
}
h_path_absent() {
  if [ -e "$1" ] || [ -L "$1" ]; then c_bad "$2: $1 exists"; else c_ok; fi
}
h_path_present() {
  if [ -e "$1" ]; then c_ok; else c_bad "$2: $1 missing"; fi
}
# h_gone MARKER SECS -- no process with MARKER in its argv within SECS.
h_gone() {
  local i=0 lim=$(($2 * 10))
  while pgrep -f "$1" >/dev/null 2>&1 && [ "$i" -lt "$lim" ]; do psleep 0.1; i=$((i + 1)); done
  if pgrep -f "$1" >/dev/null 2>&1; then
    c_bad "a process carrying $1 survived ${2}s: $(pgrep -f "$1" | tr '\n' ' ')"
    pkill -9 -f "$1" 2>/dev/null
  else
    c_ok
  fi
}
h_probe() { # KIND PATH WANT  (WANT = OK | EPERM)
  if [ -z "$REC" ]; then c_bad "probe $1 $2: no stub record"; return; fi
  local got
  got="$(tl rec "$REC" "probes.$1" 2>/dev/null | "$PY" -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], "<not probed>"))' "$2" 2>/dev/null)"
  if [ "$got" = "$3" ]; then c_ok; else c_bad "fence probe $1 $2 -> ${got:-<none>}, expected $3"; fi
}
# h_layout N -- the per-attempt files and the shared dirs exist.
h_layout() {
  local f
  for f in home tmp work review.patch.yml "prompt-$1.txt" "run-$1.patch.yml" "fence-$1.sb" \
    "run-$1.jsonl" "err-$1.txt" "status-$1.json"; do
    h_path_present "$OUT/$f" "out layout"
  done
}

# --- standard case shapes ---------------------------------------------------------------------

# fail_case NAME KIND "CODES" exact|contains [scenario args...] -- no --repo.
fail_case() {
  local name="$1" kind="$2" codes="$3" mode="$4"
  shift 4
  new_case "$name"
  make_dsh "$DSH" "$kind" "$@"
  wr "$PROMPT"
  case_begin "validate: $name"
  h_fail_codes "$codes" "$mode"
  h_record
  [ -n "$REC" ] && c_tl "attempt files" attempt-check "$REC" "$PROMPT" "$OUT" 1
  h_status 1
  h_check_agrees
  case_end
}
# setup_end CODE -- the last run was a setup error CODE and nothing ran.
setup_end() {
  case_begin "setup: $CNAME"
  h_setup "$1"
  h_no_stub "$OUT" "$C"
  case_end
}

# ==============================================================================================
echo "== META: the helpers, the stub and the fence checker can go red"

# meta_red DESC CMD... -- CMD, run as a case in a subshell, must record at least one failure.
meta_red() {
  local desc="$1" n
  shift
  n="$( (case_begin m; "$@" >/dev/null 2>&1; printf '%s' "$CASE_ERRS" | grep -c .) )"
  if [ "${n:-0}" -ge 1 ]; then note_pass "META red: $desc"; else note_fail "META red: $desc — the check did not go red"; fi
}
meta_green() {
  local desc="$1" res
  shift
  res="$( (case_begin m; "$@" >/dev/null 2>&1; printf '%s %s' "$CASE_CHECKS" "$(printf '%s' "$CASE_ERRS" | grep -c .)") )"
  case "$res" in
    "0 "*) note_fail "META green: $desc — ran no check" ;;
    *" 0") note_pass "META green: $desc" ;;
    *) note_fail "META green: $desc — went red on a correct input" ;;
  esac
}

new_case "meta"
mkdir -p "$OUT"
# Fake runs, set as the wrapper would leave them.
fake() { RC="$1"; STDOUT="$2"; STDERR="$3"; printf '%s' "$2" > "$C/stdout"; }
m_setup_wrong() { fake 2 "" "deepseek-review: ERROR KEY_MISSING: x"; h_setup PROMPT_EMPTY; }
m_setup_rc() { fake 1 "" "deepseek-review: ERROR PROMPT_EMPTY: x"; h_setup PROMPT_EMPTY; }
m_setup_ok() { fake 2 "" "deepseek-review: ERROR PROMPT_EMPTY: x"; h_setup PROMPT_EMPTY; }
m_setup_silent() { fake 2 "" ""; h_setup PROMPT_EMPTY; }
meta_red "h_setup: wrong code" m_setup_wrong
meta_red "h_setup: wrong exit" m_setup_rc
meta_red "h_setup: empty stderr" m_setup_silent
meta_green "h_setup: right code" m_setup_ok
m_fail_stdout() { fake 1 "partial" "deepseek-review: FAIL VERDICT_MISSING: x"; h_fail_codes VERDICT_MISSING exact; }
m_fail_missing() { fake 1 "" "deepseek-review: FAIL STREAM_EMPTY: x"; h_fail_codes VERDICT_MISSING contains; }
m_fail_extra() { fake 1 "" $'deepseek-review: FAIL VERDICT_MISSING: x\ndeepseek-review: FAIL ERROR_EVENT: y'; h_fail_codes VERDICT_MISSING exact; }
m_fail_rc0() { fake 0 "" "deepseek-review: FAIL VERDICT_MISSING: x"; h_fail_codes VERDICT_MISSING exact; }
m_fail_ok() { fake 1 "" $'model: x\ndeepseek-review: FAIL VERDICT_MISSING: x\ndeepseek-review: FAIL ERROR_EVENT: y'; h_fail_codes "ERROR_EVENT VERDICT_MISSING" exact; }
m_fail_err_not_fail() { fake 1 "" "deepseek-review: ERROR VERDICT_MISSING: x"; h_fail_codes VERDICT_MISSING contains; }
meta_red "h_fail_codes: stdout not empty" m_fail_stdout
meta_red "h_fail_codes: code missing" m_fail_missing
meta_red "h_fail_codes: extra code under exact" m_fail_extra
meta_red "h_fail_codes: exit 0" m_fail_rc0
meta_red "h_fail_codes: ERROR line is not a FAIL line" m_fail_err_not_fail
meta_green "h_fail_codes: right codes" m_fail_ok
printf 'answer\n' > "$C/exp"
m_pass_nl() { fake 0 "answer" ""; h_pass_stdout "$C/exp"; }
m_pass_rc() { fake 1 $'answer\n' ""; h_pass_stdout "$C/exp"; }
m_pass_ok() { fake 0 $'answer\n' ""; h_pass_stdout "$C/exp"; }
meta_red "h_pass_stdout: missing trailing newline" m_pass_nl
meta_red "h_pass_stdout: exit 1" m_pass_rc
meta_green "h_pass_stdout: exact" m_pass_ok
m_line() { fake 0 "" "xx $MODEL_LINE"; h_stderr_line_starts "$MODEL_LINE"; }
m_line_ok() { fake 0 "" $'a\n'"$MODEL_LINE (x)"; h_stderr_line_starts "$MODEL_LINE"; }
meta_red "h_stderr_line_starts: not at line start" m_line
meta_green "h_stderr_line_starts: at line start" m_line_ok
m_cmp_codes() { h_compare 1 "VERDICT_MISSING" "" 1 "STREAM_EMPTY" ""; }
m_cmp_rc() { h_compare 1 "X" "" 99 "X" ""; }
m_cmp_same99() { h_compare 99 "" "" 99 "" ""; }
m_cmp_ok() { h_compare 1 "X" "" 1 "X" ""; }
meta_red "h_compare: codes differ" m_cmp_codes
meta_red "h_compare: --check exit not a verdict" m_cmp_rc
meta_red "h_compare: both exit 99 is not agreement" m_cmp_same99
meta_green "h_compare: same verdict" m_cmp_ok
m_nostub() { mkdir -p "$OUT/home"; printf '{}' > "$OUT/home/stub-version-1.json"; h_no_stub "$OUT"; }
meta_red "h_no_stub: a --version record counts as the stub running" m_nostub
rm -f "$OUT/home/stub-version-1.json"
m_nostub_ok() { h_no_stub "$OUT"; }
meta_green "h_no_stub: nothing ran" m_nostub_ok
m_record_none() { h_record; }
meta_red "h_record: no record is a failure" m_record_none
n_empty="$( (case_begin m; case_end) )"
case "$n_empty" in FAIL*"no check ran"*) note_pass "META red: a case with zero checks fails" ;;
  *) note_fail "META red: a case with zero checks did not fail" ;; esac
m_status_bad() { mkdir -p "$OUT"; printf '{"verdict":"PASS","reasons":[]}' > "$OUT/status-1.json"; fake 1 "" "deepseek-review: FAIL X: y"; h_status 1; }
meta_red "h_status: PASS status on a failed run" m_status_bad
m_status_ok() { printf '{"verdict":"FAIL","reasons":["X"]}' > "$OUT/status-1.json"; fake 1 "" "deepseek-review: FAIL X: y"; h_status 1; }
meta_green "h_status: matching status" m_status_ok
rm -f "$OUT/status-1.json"

# env-check on fabricated records
mkrec() { printf '%s' "$1" > "$C/rec.json"; }
GOODENV='{"PATH":"/usr/bin:/bin:/usr/sbin:/sbin","HOME":"'"$OUT"'/home","DSH_HOME":"'"$OUT"'/home","TMPDIR":"'"$OUT"'/tmp","DSH_TELEMETRY_DISABLED":"1","DSH_PERMISSION_MODE":"read-only","DEEPSEEK_API_KEY":{"present":true,"length":24},"LANG":"en_US.UTF-8","__CF_USER_TEXT_ENCODING":"0x1F5:0x0:0x0"'
m_env_leak() { mkrec '{"env":'"$GOODENV"',"FAKE_SECRET":"s"}}'; c_tl env env-check "$C/rec.json" "$OUT" keylen=24 lang=en_US.UTF-8; }
m_env_cf() { mkrec '{"env":'"${GOODENV/0x1F5:0x0:0x0/0x1F5:0x7:0x7}"'}}'; c_tl env env-check "$C/rec.json" "$OUT" keylen=24 cf_sentinel=0x1F5:0x7:0x7; }
m_env_tmp() { mkrec '{"env":'"${GOODENV/$OUT\/tmp/$OUT}"'}}'; c_tl env env-check "$C/rec.json" "$OUT" keylen=24; }
m_env_lang() { mkrec '{"env":'"$GOODENV"'}}'; c_tl env env-check "$C/rec.json" "$OUT" lang=none; }
m_env_ok() { mkrec '{"env":'"$GOODENV"'}}'; c_tl env env-check "$C/rec.json" "$OUT" keylen=24 lang=en_US.UTF-8 cf_sentinel=0x1F5:0x7:0x7 forbid=evil.invalid; }
meta_red "env-check: extra name" m_env_leak
meta_red "env-check: caller's __CF_USER_TEXT_ENCODING passed through" m_env_cf
meta_red "env-check: TMPDIR not <out>/tmp" m_env_tmp
meta_red "env-check: LANG present when caller set none" m_env_lang
meta_green "env-check: allowlisted env" m_env_ok

# modes / grep-absent / tree-hash
mkdir -p "$C/modes/d"
printf x > "$C/modes/d/f"
chmod 600 "$C/modes/d/f"
m_modes_ok() { c_tl modes modes "$C/modes" 3; }
meta_green "modes: 0700 dirs, 0600 files" m_modes_ok
m_modes_file() { chmod 644 "$C/modes/d/f"; c_tl modes modes "$C/modes" 3; }
meta_red "modes: a 0644 file" m_modes_file
m_modes_few() { chmod 600 "$C/modes/d/f"; c_tl modes modes "$C/modes" 10; }
meta_red "modes: too few entries is not vacuous success" m_modes_few
m_grep_hit() { printf 'xx FAKEsentinel yy' > "$C/modes/d/f"; c_tl leak grep-absent FAKEsentinel "$C/modes"; }
meta_red "grep-absent: needle present" m_grep_hit

# h_gone must see a live marker process.
m_gone_alive() {
  ( exec perl -e 'sleep 30' "$RUNID-metagone" ) &
  local p=$!
  psleep 0.3
  h_gone "$RUNID-metagone" 1
  kill -9 "$p" 2>/dev/null
  wait "$p" 2>/dev/null
}
meta_red "h_gone: a surviving marker process" m_gone_alive

# fence-check: a reference contract fence passes; each forbidden shape goes red.
MREPO="$FAKEHOME/src/meta-repo"
make_repo "$MREPO"
MOUT="$C/fence-out"
mkdir -p "$MOUT/home" "$MOUT/tmp" "$MOUT/work"
make_dsh "$C/fence-dsh" ok
tl ref-fence "$MREPO" "$MOUT" "$C/fence-dsh" "$NODE_REAL" > "$C/good.sb"
fence_variant() { # NAME SED-OR-APPEND
  cp "$C/good.sb" "$C/v.sb"
  case "$2" in
    append:*) printf '%s\n' "${2#append:}" >> "$C/v.sb" ;;
    del:*) grep -vF -- "${2#del:}" "$C/good.sb" > "$C/v.sb" ;;
  esac
  c_tl fence fence-check "$C/v.sb" "$MREPO" "$MOUT" "$C/fence-dsh" "$NODE_REAL" "$FAKEHOME"
}
m_f_good() { c_tl fence fence-check "$C/good.sb" "$MREPO" "$MOUT" "$C/fence-dsh" "$NODE_REAL" "$FAKEHOME"; }
meta_green "fence-check: reference fence" m_f_good
for v in 'append:(allow file-read* (subpath "/usr"))' \
  'append:(allow file-read* (subpath "/private/etc"))' \
  'append:(allow file-read* (subpath "/opt/homebrew"))' \
  'append:(allow file-read* (subpath "/Users"))' \
  "append:(allow file-read* (subpath \"$FAKEHOME\"))" \
  'append:(allow file-read*)' \
  'append:(allow file-read* (regex #"^/"))' \
  "append:(allow file-read* (literal \"$OUTSIDE/secret.txt\"))" \
  "append:(allow file-write* (subpath \"$MREPO\"))" \
  "append:(allow file-write* (subpath \"$MOUT\"))" \
  'del:(deny file-read*)' \
  'del:(deny file-write*)' \
  'del:.env' \
  "append:(allow file-read* (literal \"$MOUT/prompt-1.txt\"))" \
  "append:(allow file-read* (literal \"$MOUT/run-1.jsonl\"))" \
  "append:(allow file-read* (literal \"$MOUT/fence-1.sb\"))" \
  "append:(allow file-read* (literal \"$MOUT/status-1.json\"))" \
  "append:(allow file-read* (subpath \"$MOUT\"))" \
  "del:$MOUT/review.patch.yml" \
  "del:$MOUT/run-1.patch.yml" \
  "append:(allow file-read* (subpath \"$FAKEHOME/.local\"))" \
  "append:(allow file-read* (subpath \"$FAKEHOME/opt\"))" \
  "append:(allow file-read* (subpath \"$(dirname "$FAKEHOME")\"))" \
  "append:(allow file-read* (subpath \"$PW_HOME\"))" \
  "append:(allow file-read* (subpath \"$PW_HOME/.local\"))" \
  "append:(allow file-read* (subpath \"$PW_HOME/.ssh\"))"; do
  m_f() { fence_variant v "$v"; }
  meta_red "fence-check: ${v:0:70}" m_f
done
# The .env deny: the pre-H6 regex (only `.env` and `.env.*`) and a deny placed before the repo's
# allow (a later allow wins) are both rejected; an over-broad deny (any name holding "env") too.
m_f_oldenv() {
  "$PY" -I -c '
import sys
t = open(sys.argv[1]).read()
new = "/(.*/)?(\\.env[^/]*|[^/]*\\.env)$\""
if t.count(new) != 1:
    sys.exit("new regex not found")
open(sys.argv[2], "w").write(t.replace(new, "/(.*/)?\\.env($|\\.)\""))' "$C/good.sb" "$C/v.sb" || { c_bad "variant not built"; return; }
  c_tl fence fence-check "$C/v.sb" "$MREPO" "$MOUT" "$C/fence-dsh" "$NODE_REAL" "$FAKEHOME"
}
meta_red "fence-check: the pre-H6 .env regex (.envrc, prod.env readable)" m_f_oldenv
m_f_envfirst() {
  "$PY" -I -c '
import sys
ls = open(sys.argv[1]).read().splitlines()
rx = [l for l in ls if "(regex #" in l]
if len(rx) != 1:
    sys.exit("regex line count %d" % len(rx))
ls.remove(rx[0])
ls.insert(ls.index("(deny file-read*)") + 1, rx[0])
open(sys.argv[2], "w").write("\n".join(ls) + "\n")' "$C/good.sb" "$C/v.sb" || { c_bad "variant not built"; return; }
  c_tl fence fence-check "$C/v.sb" "$MREPO" "$MOUT" "$C/fence-dsh" "$NODE_REAL" "$FAKEHOME"
}
meta_red "fence-check: the .env deny placed before the repo allow" m_f_envfirst
m_f_envbroad() {
  { grep -v '(regex #' "$C/good.sb"; printf '(deny file-read* (regex #"env"))\n'; } > "$C/v.sb"
  c_tl fence fence-check "$C/v.sb" "$MREPO" "$MOUT" "$C/fence-dsh" "$NODE_REAL" "$FAKEHOME"
}
meta_red "fence-check: an over-broad .env deny (any path holding env)" m_f_envbroad
# Node under a home: ~/bin/node may get ~/bin and ~/lib, never the home itself.
HNODE="$C/hnode-home"
mkdir -p "$HNODE/bin" "$HNODE/lib"
m_f_homebin_ok() {
  # $HNODE/bin/node does not exist, so fence-check derives no dylib or OpenSSL dirs for it: the
  # variant drops the reference node's prefix, dylib and etc lines (Homebrew paths) as well.
  { grep -v -e "(subpath \"$(dirname "$NODE_REAL")\")" -e "(subpath \"$(dirname "$(dirname "$NODE_REAL")")\")" \
      -e '(subpath "/opt/homebrew/' -e '(subpath "/usr/local/' "$C/good.sb" | grep -v '^(deny file-write\*)' | grep -v '(allow file-write\*'
    printf '(allow file-read* (subpath "%s"))\n(allow file-read* (subpath "%s"))\n' "$HNODE/bin" "$HNODE/lib"
    grep -e '^(deny file-write\*)' -e '(allow file-write\*' "$C/good.sb"; } > "$C/v.sb"
  c_tl fence fence-check "$C/v.sb" "$MREPO" "$MOUT" "$C/fence-dsh" "$HNODE/bin/node" "$HNODE"
}
meta_green "fence-check: node at <home>/bin/node may get <home>/bin and <home>/lib" m_f_homebin_ok
m_f_homebin_home() {
  m_f_homebin_ok >/dev/null 2>&1
  printf '(allow file-read* (subpath "%s"))\n' "$HNODE" >> "$C/v.sb"
  c_tl fence fence-check "$C/v.sb" "$MREPO" "$MOUT" "$C/fence-dsh" "$HNODE/bin/node" "$HNODE"
}
meta_red "fence-check: node at <home>/bin/node granted the home itself" m_f_homebin_home
# Attempt N: only run-N.patch.yml is readable, never another attempt's run patch.
tl ref-fence "$MREPO" "$MOUT" "$C/fence-dsh" "$NODE_REAL" 2 > "$C/good2.sb"
m_f2_good() { c_tl fence fence-check "$C/good2.sb" "$MREPO" "$MOUT" "$C/fence-dsh" "$NODE_REAL" "$FAKEHOME" 2; }
meta_green "fence-check: reference fence for attempt 2" m_f2_good
m_f2_run1() {
  cp "$C/good2.sb" "$C/v2.sb"
  printf '(allow file-read* (literal "%s/run-1.patch.yml"))\n' "$MOUT" >> "$C/v2.sb"
  c_tl fence fence-check "$C/v2.sb" "$MREPO" "$MOUT" "$C/fence-dsh" "$NODE_REAL" "$FAKEHOME" 2
}
meta_red "fence-check: attempt 2 fence also allowing run-1.patch.yml" m_f2_run1
m_f2_as1() { c_tl fence fence-check "$C/good.sb" "$MREPO" "$MOUT" "$C/fence-dsh" "$NODE_REAL" "$FAKEHOME" 2; }
meta_red "fence-check: attempt 1's fence (run-1, no run-2) checked as attempt 2" m_f2_as1
m_f_overlay_early() {
  # The overlay literal must come after (deny file-read*), like every other read allow.
  { printf '(version 1)\n(allow default)\n(allow file-read* (literal "%s/review.patch.yml"))\n' "$MOUT"
    grep -vF -- "(literal \"$MOUT/review.patch.yml\")" "$C/good.sb" | grep -v '^(version 1)$' | grep -v '^(allow default)$'; } > "$C/v3.sb"
  c_tl fence fence-check "$C/v3.sb" "$MREPO" "$MOUT" "$C/fence-dsh" "$NODE_REAL" "$FAKEHOME"
}
meta_red "fence-check: overlay literal placed before (deny file-read*)" m_f_overlay_early

# The stub itself, run directly (no wrapper) under the reference fence: it emits the scenario
# with the nonce, records under HOME, and its probes report EPERM/OK as a contract fence gives.
# This is what makes a red wiring case mean "the wrapper lacks it", not "the stub is broken".
SD="$C/selftest"
mkdir -p "$SD"
make_dsh "$SD/dsh" ok read="$MREPO/sentinel.txt" \
  probe_read="$OUTSIDE/secret.txt" probe_read="$MREPO/.env" probe_read="$MREPO/sentinel.txt" \
  probe_read="$FAKEHOME/.ssh/id_test" probe_read="$SSH_CONFIG" probe_write="$MREPO/stub-wrote.txt"
tl ref-fence "$MREPO" "$MOUT" "$SD/dsh" "$NODE_REAL" > "$SD/fence.sb"
SELF_NONCE="$(tl nonce)"
printf 'prompt\n\n---\nVERDICT-%s: FINDINGS\nor\nVERDICT-%s: NO FINDINGS\n' "$SELF_NONCE" "$SELF_NONCE" > "$SD/stdin"
stub_direct() { # OUTFILE ERRFILE ARGS...  (stdin from $SD/stdin)
  local o="$1" e="$2"
  shift 2
  ( cd "$MREPO" && exec perl -e 'alarm 30; exec @ARGV' /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      HOME="$MOUT/home" TMPDIR="$MOUT/tmp" /usr/bin/sandbox-exec -f "$SD/fence.sb" \
      "$NODE_REAL" "$SD/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js" "$@" ) <"$SD/stdin" >"$o" 2>"$e"
}
stub_direct "$SD/out" "$SD/err" --profile headless --json -
SELF_RC=$?
case_begin "META stub self-test: emits the scenario under a contract fence"
if [ "$SELF_RC" = 0 ]; then c_ok; else c_bad "stub exit $SELF_RC: $(head -c 300 "$SD/err")"; fi
if grep -q "VERDICT-$SELF_NONCE: NO FINDINGS" "$SD/out"; then c_ok; else c_bad "final lacks the nonce"; fi
if grep -qF "\"cwd\":\"$MREPO\"" "$SD/out"; then c_ok; else c_bad "{CWD} not substituted"; fi
OUT="$MOUT"
h_record
h_rec_eq "nonce recorded" nonce "\"$SELF_NONCE\""
h_probe read "$OUTSIDE/secret.txt" EPERM
h_probe read "$MREPO/.env" EPERM
h_probe read "$FAKEHOME/.ssh/id_test" EPERM
if [ -e "$SSH_CONFIG" ]; then h_probe read "$SSH_CONFIG" EPERM; fi
h_probe read "$MREPO/sentinel.txt" OK
h_probe write "$MREPO/stub-wrote.txt" EPERM
case_end
rm -f "$MOUT"/home/stub-*.json
stub_direct "$SD/vout" "$SD/verr" --version
case_begin "META stub self-test: --version answers the pinned version"
if [ "$(cat "$SD/vout")" = "$PINNED" ]; then c_ok; else c_bad "--version printed '$(cat "$SD/vout")'"; fi
if [ -n "$(tl find-records version "$MOUT")" ]; then c_ok; else c_bad "--version wrote no record"; fi
case_end
# The stub reads its --patch overlays first, like real dsh: readable -> runs; unreadable (fence
# EPERM or chmod 000) -> `failed to read overlay`, exit 1, no stream, no record.
printf -- '- id: x\n' > "$MOUT/review.patch.yml"
printf -- '- id: y\n' > "$MOUT/run-1.patch.yml"
printf -- '- id: z\n' > "$MOUT/other.patch.yml"
rm -f "$MOUT"/home/stub-*.json
stub_direct "$SD/pout" "$SD/perr" --profile headless --patch "$MOUT/review.patch.yml" \
  --patch "$MOUT/run-1.patch.yml" --json -
P_RC=$?
case_begin "META stub self-test: readable --patch overlays (contract fence literals) are read, run passes"
if [ "$P_RC" = 0 ]; then c_ok; else c_bad "stub exit $P_RC: $(head -c 300 "$SD/perr")"; fi
if grep -q "VERDICT-$SELF_NONCE: NO FINDINGS" "$SD/pout"; then c_ok; else c_bad "no stream after readable overlays"; fi
OUT="$MOUT"
h_record
[ -n "$REC" ] && c_tl "patch reads" patch-reads "$REC" "$MOUT/review.patch.yml" "$MOUT/run-1.patch.yml"
case_end
m_preads_extra() { c_tl "patch reads" patch-reads "$REC" "$MOUT/review.patch.yml"; }
meta_red "patch-reads: an extra --patch read is not ignored" m_preads_extra
m_preads_none() { mkrec '{"probes":{}}'; c_tl "patch reads" patch-reads "$C/rec.json" "$MOUT/review.patch.yml"; }
meta_red "patch-reads: a record without patch_reads" m_preads_none
rm -f "$MOUT"/home/stub-*.json
stub_direct "$SD/pout2" "$SD/perr2" --profile headless --patch "$MOUT/review.patch.yml" \
  --patch "$MOUT/other.patch.yml" --json -
P_RC=$?
case_begin "META stub self-test: a fence-denied --patch file is fatal (EPERM), like real dsh"
if [ "$P_RC" = 1 ]; then c_ok; else c_bad "stub exit $P_RC, expected 1"; fi
if grep -qF "dsh: failed to read overlay $MOUT/other.patch.yml: Error: EPERM" "$SD/perr2"; then c_ok; else c_bad "stderr lacks the EPERM overlay line: $(head -c 300 "$SD/perr2")"; fi
if [ ! -s "$SD/pout2" ]; then c_ok; else c_bad "stub emitted a stream after an unreadable overlay"; fi
if [ -z "$(tl find-records any "$MOUT")" ]; then c_ok; else c_bad "stub wrote a record after an unreadable overlay"; fi
case_end
# Without a fence: chmod 000 -> exit 1; the same file readable -> exit 0.
stub_nofence() { # OUTFILE ERRFILE ARGS...
  local o="$1" e="$2"
  shift 2
  ( cd "$MREPO" && exec perl -e 'alarm 30; exec @ARGV' /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin \
      HOME="$MOUT/home" TMPDIR="$MOUT/tmp" "$NODE_REAL" "$SD/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js" "$@" ) \
    <"$SD/stdin" >"$o" 2>"$e"
}
printf -- '- id: q\n' > "$SD/locked.patch.yml"
chmod 000 "$SD/locked.patch.yml"
stub_nofence "$SD/lout" "$SD/lerr" --profile headless --patch "$SD/locked.patch.yml" --json -
L_RC=$?
chmod 600 "$SD/locked.patch.yml"
rm -f "$MOUT"/home/stub-*.json
stub_nofence "$SD/uout" "$SD/uerr" --profile headless --patch "$SD/locked.patch.yml" --json -
U_RC=$?
case_begin "META stub self-test: --patch chmod 000 -> exit 1; same file readable -> exit 0"
if [ "$L_RC" = 1 ]; then c_ok; else c_bad "chmod 000 overlay: stub exit $L_RC, expected 1"; fi
if grep -qF "dsh: failed to read overlay $SD/locked.patch.yml: Error: EACCES" "$SD/lerr"; then c_ok; else c_bad "stderr lacks the overlay line: $(head -c 300 "$SD/lerr")"; fi
if [ "$U_RC" = 0 ]; then c_ok; else c_bad "readable overlay: stub exit $U_RC: $(head -c 300 "$SD/uerr")"; fi
if grep -q "VERDICT-$SELF_NONCE: NO FINDINGS" "$SD/uout"; then c_ok; else c_bad "no stream with a readable overlay"; fi
case_end

# Trap: SIGTERM makes the stub print a perfect stream and exit 0.
rm -f "$MOUT"/home/stub-*.json
tl scenario "$SD/dsh/node_modules/@deepseek-ai/dsh/lib/scenario.json" trap marker="$RUNID-selfgc"
( cd "$MREPO" && exec /usr/bin/env -i PATH=/usr/bin:/bin HOME="$MOUT/home" TMPDIR="$MOUT/tmp" \
    "$NODE_REAL" "$SD/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js" --json - ) <"$SD/stdin" >"$SD/tout" 2>"$SD/terr" &
TP=$!
for _ in $(seq 100); do [ -n "$(tl find-records record "$MOUT")" ] && break; psleep 0.1; done
case_begin "META stub self-test: SIGTERM trap prints a valid stream; grandchild marker visible to pgrep"
if pgrep -f "$RUNID-selfgc" >/dev/null; then c_ok; else c_bad "grandchild with the marker not found by pgrep"; fi
kill -TERM "$TP" 2>/dev/null
wait "$TP"
TRC=$?
if [ "$TRC" = 0 ]; then c_ok; else c_bad "trapped stub exit $TRC"; fi
if grep -q "\"type\":\"final\".*VERDICT-$SELF_NONCE: NO FINDINGS" "$SD/tout"; then c_ok; else c_bad "no final with the nonce after SIGTERM"; fi
pkill -9 -f "$RUNID-selfgc" 2>/dev/null
case_end

# version_hang: `--version` spawns its marker grandchild, records, and never answers.
rm -f "$MOUT"/home/stub-*.json
tl scenario "$SD/dsh/node_modules/@deepseek-ai/dsh/lib/scenario.json" version_hang vmarker="$RUNID-selfvgc"
( cd "$MREPO" && exec perl -e 'alarm 20; exec @ARGV' /usr/bin/env -i PATH=/usr/bin:/bin HOME="$MOUT/home" \
    TMPDIR="$MOUT/tmp" "$NODE_REAL" "$SD/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js" --version ) \
  </dev/null >"$SD/vhout" 2>"$SD/vherr" &
VP=$!
for _ in $(seq 100); do [ -n "$(tl find-records version "$MOUT")" ] && break; psleep 0.1; done
psleep 0.3
case_begin "META stub self-test: version_hang records, spawns its marker grandchild and prints nothing"
if [ -n "$(tl find-records version "$MOUT")" ]; then c_ok; else c_bad "no --version record"; fi
if pgrep -f "$RUNID-selfvgc" >/dev/null; then c_ok; else c_bad "version grandchild with the marker not found by pgrep"; fi
if kill -0 "$VP" 2>/dev/null; then c_ok; else c_bad "the stub exited instead of hanging"; fi
kill -9 "$VP" 2>/dev/null
wait "$VP" 2>/dev/null
if [ ! -s "$SD/vhout" ]; then c_ok; else c_bad "a hanging --version printed '$(head -c 80 "$SD/vhout")'"; fi
pkill -9 -f "$RUNID-selfvgc" 2>/dev/null
case_end
# {KEY} in a scenario is the DEEPSEEK_API_KEY the stub got.
rm -f "$MOUT"/home/stub-*.json
tl scenario "$SD/dsh/node_modules/@deepseek-ai/dsh/lib/scenario.json" leak_key_final
( cd "$MREPO" && exec perl -e 'alarm 20; exec @ARGV' /usr/bin/env -i PATH=/usr/bin:/bin HOME="$MOUT/home" \
    TMPDIR="$MOUT/tmp" DEEPSEEK_API_KEY=FAKE-selftest-key-42 "$NODE_REAL" \
    "$SD/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js" --json - ) <"$SD/stdin" >"$SD/kout" 2>"$SD/kerr"
case_begin "META stub self-test: {KEY} in a scenario is replaced by the key the stub got"
if grep -q '"type":"final".*Key seen: FAKE-selftest-key-42' "$SD/kout"; then c_ok; else c_bad "final lacks the substituted key: $(head -c 200 "$SD/kout")"; fi
case_end

# Fixtures used by later cases work on their own.
HIJ="$TMP_REAL/hijack"
mkdir -p "$HIJ"
HIJ_MARK="$TMP_REAL/hijack-marker"
printf '#!/bin/sh\necho hijacked > "%s"\nexit 3\n' "$HIJ_MARK" > "$HIJ/node"
printf '#!/bin/sh\necho hijacked > "%s"\nexit 3\n' "$HIJ_MARK" > "$HIJ/npm"
chmod 755 "$HIJ/node" "$HIJ/npm"
"$HIJ/node" >/dev/null 2>&1
case_begin "META fixture: the PATH-hijack node writes its marker when executed"
h_path_present "$HIJ_MARK" "hijack marker"
case_end
rm -f "$HIJ_MARK"
NVM="$FAKEHOME/.nvm/versions/node/v0"
copy_node_tree "$NVM"
case_begin "META fixture: node copied under fakehome/.nvm starts"
if [ "$("$NVM/bin/node" --version 2>&1)" = "$("$NODE_REAL" --version)" ]; then c_ok; else c_bad "copied node does not run"; fi
case_end
case_begin "META fixture: node and its dylibs have no hard links after the fixtures"
h_node_links
case_end
# The self-test links a file of its own: a link to the shared NODE_REAL would be seen by every
# other suite run at the same time (the mutation harness runs several), turning their check red.
m_links_red() { : > "$C/links-a"; ln "$C/links-a" "$C/links-b" || return; h_node_links "$C/links-a"; rm -f "$C/links-a" "$C/links-b"; }
meta_red "h_node_links: a hard link of node" m_links_red
rm -f "$C/links-a" "$C/links-b"

# Selection (DSR_ONLY) applies from here on; everything above always runs.
SEL_ON=1

# ==============================================================================================
echo "== usage, setup errors and --print-invocation"

new_case "usage"
make_dsh "$DSH" ok
# '--mod' would be --model under argparse's default prefix matching (allow_abbrev).
for bad in "--patch x" "--base-url http://evil.invalid" "--endpoint http://evil.invalid" "--frobnicate" \
  "--mod deepseek-v4-flash"; do
  # shellcheck disable=SC2086
  wr $bad "$PROMPT"
  case_begin "usage: '$bad' is a usage error"
  h_rc 2
  if [ -n "$STDERR" ]; then c_ok; else c_bad "stderr empty"; fi
  h_no_traceback
  h_no_stub "$OUT" "$C"
  h_path_absent "$OUT" "out dir"
  case_end
done
wr
case_begin "usage: no PROMPT_FILE is a usage error"
h_rc 2
h_no_traceback
if [ -n "$STDERR" ]; then c_ok; else c_bad "stderr empty"; fi
case_end
wr --timeout bogus "$PROMPT"
case_begin "usage: --timeout bogus is a usage error"
h_rc 2
if [ -n "$STDERR" ]; then c_ok; else c_bad "stderr empty"; fi
h_no_stub "$OUT" "$C"
case_end
wr --timeout 0 "$PROMPT"
case_begin "usage: --timeout 0 is a usage error"
h_rc 2
h_stderr_has "deepseek-review: usage error: --timeout must be a positive integer"
h_no_stub "$OUT" "$C"
h_path_absent "$OUT" "out dir"
case_end
mkdir -p "$C/chk"
run_w -- --check "$C/chk" "$PROMPT"
case_begin "usage: --check with a PROMPT_FILE is a usage error"
h_rc 2
h_stderr_has "deepseek-review: usage error: --check takes no PROMPT_FILE"
case_end
wr --attempt 2 "$PROMPT"
case_begin "usage: --attempt without --check is a usage error"
h_rc 2
h_stderr_has "deepseek-review: usage error: --attempt goes with --check"
h_no_stub "$OUT" "$C"
h_path_absent "$OUT" "out dir"
case_end

new_case "PROMPT_MISSING"; make_dsh "$DSH" ok
wr "$C/no-such-prompt.txt"; setup_end PROMPT_MISSING
new_case "PROMPT_MISSING (the PROMPT_FILE is a directory)"; make_dsh "$DSH" ok
mkdir -p "$C/prompt-dir.txt"
wr "$C/prompt-dir.txt"; setup_end PROMPT_MISSING
# A FIFO prompt: an open() would block with no writer. The alarm turns a block into a red.
new_case "PROMPT_MISSING (the PROMPT_FILE is a FIFO)"; make_dsh "$DSH" ok
[ -z "$SEL" ] || mkfifo "$C/prompt-fifo"
run_w ALARM=20 -- --dsh-dir "$DSH" --out "$OUT" "$C/prompt-fifo"
case_begin "setup: PROMPT_MISSING (the PROMPT_FILE is a FIFO): refused at once, never opened"
h_setup PROMPT_MISSING
h_stderr_has "deepseek-review: ERROR PROMPT_MISSING: prompt file not found"
case_end
new_case "PROMPT_EMPTY (zero bytes)"; make_dsh "$DSH" ok
: > "$PROMPT"; wr "$PROMPT"; setup_end PROMPT_EMPTY
new_case "PROMPT_EMPTY (whitespace only)"; make_dsh "$DSH" ok
printf ' \n\t\n  ' > "$PROMPT"; wr "$PROMPT"; setup_end PROMPT_EMPTY
for m in DeepSeek-V4 "deepseek/v4" "deepseek_v4" "$(printf 'a%.0s' $(seq 65))"; do
  new_case "MODEL_INVALID (--model '${m:0:12}', ${#m} chars)"; make_dsh "$DSH" ok
  wr --model "$m" "$PROMPT"; setup_end MODEL_INVALID
done
for e in xhigh HIGH "" medium; do
  new_case "EFFORT_INVALID (--effort '$e')"; make_dsh "$DSH" ok
  wr --effort "$e" "$PROMPT"; setup_end EFFORT_INVALID
done
for m in 0 393217 abc -1 1.5; do
  new_case "MAX_TOKENS_INVALID (--max-tokens $m)"; make_dsh "$DSH" ok
  wr --max-tokens "$m" "$PROMPT"; setup_end MAX_TOKENS_INVALID
done
new_case "KEY_MISSING (unset)"; make_dsh "$DSH" ok
run_w NOKEY -- --dsh-dir "$DSH" --out "$OUT" "$PROMPT"
case_begin "setup: $CNAME"; h_setup KEY_MISSING; h_no_stub "$OUT" "$C"; h_path_absent "$OUT" "out created before the key check"; case_end
new_case "KEY_MISSING (empty)"; make_dsh "$DSH" ok
run_w KEY= -- --dsh-dir "$DSH" --out "$OUT" "$PROMPT"
case_begin "setup: $CNAME"; h_setup KEY_MISSING; h_no_stub "$OUT" "$C"; h_path_absent "$OUT" "out created before the key check"; case_end

key_invalid_case() { # NAME KEY WANT_MSG SENTINEL
  new_case "KEY_INVALID ($1)"; make_dsh "$DSH" ok
  mkdir -p "$C/ctmp"
  run_w KEY="$2" ENV:TMPDIR="$C/ctmp" -- --dsh-dir "$DSH" --out "$OUT" "$PROMPT"
  case_begin "setup: $CNAME"
  h_setup KEY_INVALID
  h_stderr_has "$3"
  h_no_stub "$OUT" "$C"
  h_path_absent "$OUT" "out created before the key check"
  c_tl "key value leaked" grep-absent "$4" "$C" "$FAKEHOME"
  case_end
}
key_invalid_case "newline" $'FAKEsentinel\nX' "length 14, bad positions [12]" FAKEsentinel
key_invalid_case "space" "FAKEspace key" "length 13, bad positions [9]" FAKEspace
key_invalid_case "DEL and tab" $'FAKEdel\x7fA\tB' "length 11, bad positions [7, 9]" FAKEdel

# --print-invocation
pinv_case() { # NAME pinv-check-args... -- wrapper args...
  local name="$1"
  shift
  local -a chk=()
  while [ "$1" != "--" ]; do chk+=("$1"); shift; done
  shift
  run_w NOKEY ENV:TMPDIR="$C/ptmp" -- --print-invocation "$@"
  printf '%s' "$STDOUT" > "$C/pinv.json"
  case_begin "print-invocation: $name"
  h_rc 0
  if [ -n "$STDOUT" ]; then c_ok; else c_bad "stdout empty"; fi
  c_tl "structure" pinv-check "$C/pinv.json" "${chk[@]}" review="$PLUGIN/dsh/review.patch.yml"
  h_no_stub "$OUT" "$C"
  h_path_absent "$OUT" "--print-invocation created the out dir"
  if [ -z "$(ls -A "$C/ptmp")" ]; then c_ok; else c_bad "--print-invocation created files in TMPDIR: $(ls -A "$C/ptmp" | tr '\n' ' ')"; fi
  case_end
}
new_case "pinv default"; make_dsh "$DSH" ok; mkdir -p "$C/ptmp"
pinv_case "defaults, no key needed, creates nothing" node="$NODE_REAL" dsh="$DSH" cwd="{OUT}/work" lang=yes \
  model=deepseek-flash effort=max max=393216 -- --dsh-dir "$DSH" --out "$OUT" "$PROMPT"
cp "$C/pinv.json" "$TMP_REAL/pinv-baseline.json"
new_case "pinv repo"; make_dsh "$DSH" ok; make_repo "$REPO"; mkdir -p "$C/ptmp"
pinv_case "--repo, --model, --effort high, --max-tokens 1 (all differ from the defaults)" node="$NODE_REAL" dsh="$DSH" cwd="$REPO" lang=yes \
  model=deepseek-v4-pro effort=high max=1 -- --dsh-dir "$DSH" --out "$OUT" --repo "$REPO" \
  --model deepseek-v4-pro --effort high --max-tokens 1 "$PROMPT"
new_case "pinv low"; make_dsh "$DSH" ok; mkdir -p "$C/ptmp"
pinv_case "--effort low, --max-tokens 393216 (upper bound valid)" node="$NODE_REAL" dsh="$DSH" cwd="{OUT}/work" lang=yes \
  model=deepseek-flash effort=low max=393216 -- --dsh-dir "$DSH" --out "$OUT" --effort low --max-tokens 393216 "$PROMPT"
new_case "pinv default dsh dir"; mkdir -p "$C/ptmp"
# Under the account's home (pw_dir), never under the inherited HOME (here the fake one). Nothing
# is written there: --print-invocation only names the path.
DEFDSH="$PW_HOME/.local/share/deepseek-review/dsh-$PINNED"
pinv_case "default --dsh-dir is <account home>/.local/share/deepseek-review/dsh-$PINNED (HOME does not move it)" \
  node="$NODE_REAL" dsh="$DEFDSH" \
  cwd="{OUT}/work" lang=yes model=deepseek-flash effort=max max=393216 -- --out "$OUT" "$PROMPT"
new_case "pinv nolang"; make_dsh "$DSH" ok
run_w NOKEY NOLANG -- --print-invocation --dsh-dir "$DSH" --out "$OUT" "$PROMPT"
printf '%s' "$STDOUT" > "$C/pinv.json"
case_begin "print-invocation: env_names lacks LANG when the caller set none"
h_rc 0
c_tl "structure" pinv-check "$C/pinv.json" node="$NODE_REAL" dsh="$DSH" cwd="{OUT}/work" lang=no \
  model=deepseek-flash effort=max max=393216 review="$PLUGIN/dsh/review.patch.yml"
case_end
new_case "pinv env invariance"; make_dsh "$DSH" ok
run_w NOKEY ENV:DEEPSEEK_BASE_URL=http://evil.invalid ENV:DEEPSEEK_REVIEW_TEST_BASE_URL=http://evil.invalid \
  ENV:ANTHROPIC_BASE_URL=http://evil.invalid -- --print-invocation --dsh-dir "$DSH" --out "$OUT" "$PROMPT"
A="$STDOUT"
run_w NOKEY -- --print-invocation --dsh-dir "$DSH" --out "$OUT" "$PROMPT"
case_begin "print-invocation: inherited DEEPSEEK_BASE_URL / DEEPSEEK_REVIEW_TEST_BASE_URL change nothing"
h_rc 0
if [ -n "$A" ] && [ "$A" = "$STDOUT" ]; then c_ok; else c_bad "output differs (or is empty) with the endpoint env vars set"; fi
h_text_lacks "print-invocation output" "evil.invalid" "$A"
if printf '%s' "$A" | grep -qF 'api.deepseek.com/anthropic'; then c_ok; else c_bad "output lacks the pinned endpoint"; fi
case_end

# ==============================================================================================
echo "== validation predicates (stub dsh, every case re-checked with --check)"

new_case "success"
# Without --repo the fence grants <out>/work, never the rest of <out>.
make_dsh "$DSH" ok probe_read="$OUT/prompt-1.txt" probe_read="$OUT/fence-1.sb"
wr "$PROMPT"
case_begin "validate: a fully successful run passes"
h_pass
h_stderr_line_starts "$MODEL_LINE"
h_layout 1
[ -n "$REC" ] && c_tl "attempt files" attempt-check "$REC" "$PROMPT" "$OUT" 1
h_rec_eq "stub cwd (no --repo)" cwd "\"$OUT/work\""
h_probe read "$OUT/prompt-1.txt" EPERM
h_probe read "$OUT/fence-1.sb" EPERM
c_tl "status" status-check "$OUT/status-1.json" keys attempt=1 dsh_version="\"$PINNED\"" \
  model='"deepseek-flash"' model_source='"default"' effort='"max"' max_tokens=393216 repo=null \
  repo_mode=false expect_read='[]' session_id='"session-stub-0001"' exit_code=0 signal=null \
  cancelled=false cancel_reason=null verdict='"PASS"' reasons='[]' \
  usage='{"cacheReadTokens": 6, "inputTokens": 22, "outputTokens": 84, "totalTokens": 112}'
h_status 1
h_check_agrees
case_end

new_case "model flag"
make_dsh "$DSH" ok
wr --model deepseek-v4-flash "$PROMPT"
case_begin "validate: --model is announced as (--model) and recorded"
h_pass
h_stderr_line_starts "model: deepseek-v4-flash (--model), effort max, max_tokens 393216, endpoint api.deepseek.com"
c_tl "status" status-check "$OUT/status-1.json" model='"deepseek-v4-flash"' model_source='"--model"'
case_end

new_case "findings"
make_dsh "$DSH" findings
wr "$PROMPT"
case_begin "validate: VERDICT FINDINGS is a review (exit 0)"
h_pass
h_check_agrees
case_end

new_case "trailing blank"
make_dsh "$DSH" verdict_trailing_blank
wr "$PROMPT"
case_begin "validate: blank lines after the VERDICT line are allowed (last NON-BLANK line)"
h_rc 0
h_record
if printf '%s' "$STDOUT" | grep -q "^VERDICT-[0-9a-f]\{16\}: FINDINGS$"; then c_ok; else c_bad "answer lacks the VERDICT line"; fi
h_check_agrees
case_end

new_case "dotenv warning"
make_dsh "$DSH" dotenv
wr "$PROMPT"
case_begin "validate: a fenced .env warning alone does not fail the run"
h_pass
if grep -qF 'failed to load .env' "$OUT/err-1.txt" 2>/dev/null; then c_ok; else c_bad "err-1.txt lacks the .env warning (scenario not reproduced)"; fi
h_check_agrees
case_end

fail_case "dsh exit 1 with an otherwise valid completed stream" exit1 DSH_EXIT_NONZERO exact
new_case "killed"
make_dsh "$DSH" killed
wr "$PROMPT"
case_begin "validate: dsh killed by SIGKILL after a valid completed stream"
h_fail_codes DSH_EXIT_NONZERO exact
h_fail_line_has DSH_EXIT_NONZERO "killed by signal 9"
c_tl "status" status-check "$OUT/status-1.json" exit_code=null signal=9 cancelled=false verdict='"FAIL"'
h_check_agrees
case_end
new_case "zero-byte stdout"
make_dsh "$DSH" empty
wr "$PROMPT"
case_begin "validate: zero-byte stdout"
h_fail_codes STREAM_EMPTY contains
h_fail_line_has STREAM_EMPTY "dsh wrote nothing on stdout"
h_record
h_status 1
h_check_agrees
case_end
new_case "blank lines only"
make_dsh "$DSH" blank_lines
wr "$PROMPT"
case_begin "validate: stdout holding only blank lines is STREAM_EMPTY"
h_fail_codes STREAM_EMPTY contains
h_fail_line_has STREAM_EMPTY "dsh wrote no events"
h_record
h_status 1
h_check_agrees
case_end
fail_case "a non-JSON line" notjson STREAM_NOT_JSON contains
fail_case "a JSON line that is not an object" notobject STREAM_NOT_JSON contains
fail_case "session event not first" session_not_first SESSION_NOT_FIRST exact
fail_case "no session event" no_session SESSION_NOT_FIRST contains
fail_case "no final event" no_final FINAL_NOT_LAST contains
fail_case "an event after final" final_not_last FINAL_NOT_LAST exact
fail_case "an error event" error_event ERROR_EVENT exact
fail_case "no turn_end at all (fail closed)" no_turn_end NO_TURN_END contains
new_case "turn max-tokens"
make_dsh "$DSH" turn_max_tokens
wr "$PROMPT"
case_begin "validate: turn_end max-tokens with a valid VERDICT"
h_fail_codes TURN_NOT_COMPLETED exact
h_fail_line_has TURN_NOT_COMPLETED max-tokens
h_status 1
h_check_agrees
case_end
new_case "last turn"
make_dsh "$DSH" last_turn_not_completed
wr "$PROMPT"
case_begin "validate: an earlier completed turn does not hide a failed LAST turn"
h_fail_codes TURN_NOT_COMPLETED exact
h_fail_line_has TURN_NOT_COMPLETED error
h_check_agrees
case_end
fail_case "provider refusal (observed rc.5 shape)" refusal "TURN_NOT_COMPLETED DSH_EXIT_NONZERO FINAL_EMPTY" contains
fail_case "blank final text" final_blank FINAL_EMPTY contains
fail_case "no VERDICT line" verdict_missing VERDICT_MISSING exact
fail_case "VERDICT with another attempt's nonce" verdict_wrong_nonce VERDICT_MISSING exact
fail_case "text after the VERDICT line" verdict_trailing VERDICT_MISSING contains
fail_case "VERDICT word not FINDINGS/NO FINDINGS" verdict_bad_word VERDICT_MISSING exact
fail_case "text after the verdict word on the VERDICT line" verdict_suffix VERDICT_MISSING exact
fail_case "a second VERDICT line (other nonce)" verdict_dup_other VERDICT_DUPLICATE exact
fail_case "a second VERDICT line (same nonce)" verdict_dup_same VERDICT_DUPLICATE exact
fail_case "composition warning: did not activate" compose_activate COMPOSE_WARNING exact
fail_case "composition warning: patch entry not found" compose_notfound COMPOSE_WARNING exact

# --- --repo predicates --------------------------------------------------------------------------
repo_case() { # NAME KIND "CODES"|PASS MODE [scenario args...] -- [wrapper args...]
  local name="$1" kind="$2" codes="$3" mode="$4"
  shift 4
  local -a sargs=()
  while [ "$1" != "--" ]; do sargs+=("$1"); shift; done
  shift
  make_dsh "$DSH" "$kind" ${sargs[@]+"${sargs[@]}"}
  wr --repo "$REPO" "$@" "$PROMPT"
  case_begin "validate --repo: $name"
  if [ "$codes" = PASS ]; then h_pass; else h_fail_codes "$codes" "$mode"; fi
  h_status 1
  h_check_agrees
}
new_case "repo pass"; make_repo "$REPO"
repo_case "an absolute read inside the repo passes" ok PASS - read="$REPO/sentinel.txt" --
h_rec_eq "stub cwd" cwd "\"$REPO\""
c_tl "status" status-check "$OUT/status-1.json" repo="\"$REPO\"" repo_mode=true expect_read='[]'
case_end
new_case "repo relative"; make_repo "$REPO"
repo_case "a relative read resolves against the session cwd" ok PASS - read=sentinel.txt --
case_end
new_case "repo denied"; make_repo "$REPO"
repo_case "every read denied, final says it could not access the files" denied_all REPO_NOT_READ exact \
  denied="$REPO/sentinel.txt" denied="$REPO/src/a.txt" --
h_stderr_has "denied: read $REPO/sentinel.txt"
h_stderr_has "denied: read $REPO/src/a.txt"
case_end
new_case "repo outside"; make_repo "$REPO"
repo_case "the only successful read is outside the repo" ok REPO_NOT_READ exact read="$OUTSIDE/secret.txt" --
case_end
new_case "repo grep"; make_repo "$REPO"
repo_case "a completed grep is not a read" ok REPO_NOT_READ exact grep="$REPO" --
case_end
new_case "repo edit tool"; make_repo "$REPO"
repo_case "a completed non-read tool whose input has a file_path is not a read" ok REPO_NOT_READ exact \
  edit="$REPO/sentinel.txt" --
case_end
new_case "repo callid"; make_repo "$REPO"
repo_case "a completed tool_result whose callId matches no read call" unmatched_callid \
  "REPO_NOT_READ RESULT_WITHOUT_CALL" exact \
  read="$REPO/sentinel.txt" --
case_end
new_case "repo symlink"; make_repo "$REPO"; ln -s "$OUTSIDE/secret.txt" "$REPO/link-out"
repo_case "a read through a repo symlink that resolves outside" ok REPO_NOT_READ exact read="$REPO/link-out" --
case_end
new_case "repo prefix"; make_repo "$REPO"; mkdir -p "${REPO}-evil"; printf 'e\n' > "${REPO}-evil/f.txt"
repo_case "a sibling dir sharing the repo's name prefix" ok REPO_NOT_READ exact read="${REPO}-evil/f.txt" --
case_end
new_case "repo relative escape"; make_repo "$REPO"; mkdir -p "${REPO}-evil"; printf 'e\n' > "${REPO}-evil/f.txt"
repo_case "a relative read escaping the session cwd" ok REPO_NOT_READ exact read="../$(basename "$REPO")-evil/f.txt" --
case_end
new_case "expect ok"; make_repo "$REPO"
repo_case "--expect-read of a file that was read passes" ok PASS - read="$REPO/sentinel.txt" -- \
  --expect-read "$REPO/sentinel.txt"
c_tl "status" status-check "$OUT/status-1.json" expect_read="[\"$REPO/sentinel.txt\"]"
case_end
new_case "expect missing"; make_repo "$REPO"
repo_case "an --expect-read file never read while other reads succeeded" ok EXPECTED_READ_MISSING exact \
  read="$REPO/sentinel.txt" -- --expect-read "$REPO/sentinel.txt" --expect-read "$REPO/src/a.txt"
h_fail_line_has EXPECTED_READ_MISSING "src/a.txt"
c_tl "status" status-check "$OUT/status-1.json" expect_read="[\"$REPO/sentinel.txt\", \"$REPO/src/a.txt\"]"
case_end
# --check takes expect_read from status-1.json: drop the missing path on a copy and it passes.
case_begin "attempts: --check uses the recorded expect_read"
if [ -f "$OUT/status-1.json" ]; then
  cp -Rp "$OUT" "$C/out-edited"
  # H10: --check keeps a FAIL status's recorded reasons, so the edited copy records PASS too.
  tl status-set "$C/out-edited/status-1.json" expect_read="[\"$REPO/sentinel.txt\"]" \
    verdict='"PASS"' reasons='[]'
  chmod 600 "$C/out-edited/status-1.json"
  SAVE_OUT="$OUT"; OUT="$C/out-edited"
  run_w -- --check "$OUT"
  h_rc 0
  if [ -n "$STDOUT" ]; then c_ok; else c_bad "--check printed no answer"; fi
  OUT="$SAVE_OUT"
else
  c_bad "no status-1.json from the expect-read run"
fi
case_end

# ==============================================================================================
echo "== launch wiring and the fence"

new_case "launch"
make_repo "$REPO"
printf 'NESTED-ENV-SENTINEL\n' > "$REPO/src/.env"
printf 'LOCAL-ENV-SENTINEL\n' > "$REPO/.env.local"
make_dsh "$DSH" ok read="$REPO/sentinel.txt" \
  probe_read="$OUTSIDE/secret.txt" probe_read="$SSH_CONFIG" probe_read="$REPO/.env" \
  probe_read="$REPO/src/.env" probe_read="$REPO/.env.local" \
  probe_read="$FAKEHOME/.ssh/id_test" probe_read="$REPO/sentinel.txt" \
  probe_write="$REPO/stub-wrote-here.txt" probe_write="$FAKEHOME/stub-wrote-here.txt" \
  probe_write="$OUT/tmp/stub-tmp-write.txt" probe_write="$OUT/home/stub-home-write.txt" \
  probe_write=/dev/null probe_write=/dev/tty probe_write=/dev/dtracehelper \
  probe_read="$OUT/review.patch.yml" probe_read="$OUT/run-1.patch.yml" probe_read="$OUT/prompt-1.txt" \
  probe_read="$OUT/fence-1.sb" probe_read="$OUT/run-1.jsonl"
mkdir -p "$C/ptmp"
run_w NOKEY -- --print-invocation --dsh-dir "$DSH" --out "$OUT" --repo "$REPO" "$PROMPT"
printf '%s' "$STDOUT" > "$C/pinv.json"
PINV_RC=$RC
wr --repo "$REPO" "$PROMPT"
case_begin "launch: the run passes"
h_pass
h_layout 1
case_end
case_begin "launch: stub argv[2:] == --print-invocation argv[5:], execPath == node realpath, patch hashes"
if [ "$PINV_RC" = 0 ]; then c_ok; else c_bad "--print-invocation exit $PINV_RC"; fi
if [ -n "$REC" ]; then
  c_tl "argv" argv-vs-pinv "$REC" "$C/pinv.json" "$OUT"
  c_tl "argv contract" argv-exact "$REC" "$OUT" 1
  h_rec_eq "execPath" execPath "\"$NODE_REAL\""
  h_rec_eq "cwd" cwd "\"$REPO\""
else
  c_bad "no stub record"
fi
c_tl "patch hashes" patch-sha "$OUT" "$C/pinv.json"
if cmp -s "$OUT/review.patch.yml" "$PLUGIN/dsh/review.patch.yml"; then c_ok; else c_bad "out/review.patch.yml differs from dsh/review.patch.yml"; fi
case_end
case_begin "launch: fence probes from inside the stub"
h_probe read "$OUTSIDE/secret.txt" EPERM
h_probe read "$REPO/.env" EPERM
h_probe read "$REPO/src/.env" EPERM
h_probe read "$REPO/.env.local" EPERM
h_probe read "$FAKEHOME/.ssh/id_test" EPERM
if [ -e "$SSH_CONFIG" ]; then h_probe read "$SSH_CONFIG" EPERM; fi
h_probe read "$REPO/sentinel.txt" OK
h_probe write "$REPO/stub-wrote-here.txt" EPERM
h_probe write "$FAKEHOME/stub-wrote-here.txt" EPERM
h_path_absent "$REPO/stub-wrote-here.txt" "write into the repo"
case_end
# Each write allow of the fence, seen from inside: home and tmp are writable, and so are the
# three device literals. dsh runs in its own session (no controlling tty), so an ALLOWED
# /dev/tty open fails ENXIO, a denied one EPERM.
case_begin "launch: the fence's write allows (home, tmp, /dev/null, /dev/tty, /dev/dtracehelper)"
h_probe write "$OUT/home/stub-home-write.txt" OK
h_probe write "$OUT/tmp/stub-tmp-write.txt" OK
h_probe write /dev/null OK
h_probe write /dev/tty ENXIO
h_probe write /dev/dtracehelper ENODEV   # allowed: the device refuses the bytes; denied: EPERM
case_end
case_begin "launch: dsh reads both --patch overlays under the fence; nothing else at the top of out"
[ -n "$REC" ] && c_tl "patch reads" patch-reads "$REC" "$OUT/review.patch.yml" "$OUT/run-1.patch.yml"
[ -n "$REC" ] || c_bad "no stub record (stub exit: $(first_line "$(cat "$OUT/err-1.txt" 2>/dev/null)"))"
h_probe read "$OUT/review.patch.yml" OK
h_probe read "$OUT/run-1.patch.yml" OK
h_probe read "$OUT/prompt-1.txt" EPERM
h_probe read "$OUT/fence-1.sb" EPERM
h_probe read "$OUT/run-1.jsonl" EPERM
case_end
# H8: the version check sends nothing, so it gets the child env WITHOUT the key.
case_begin "launch: the --version check runs first, same env and fence"
VREC="$(tl find-records version "$OUT" | head -1)"
if [ -n "$VREC" ]; then
  c_ok
  c_tl "version env" env-check "$VREC" "$OUT" keylen=absent lang=en_US.UTF-8
  SAVE_REC="$REC"; REC="$VREC"
  h_probe read "$OUTSIDE/secret.txt" EPERM
  h_rec_eq "version execPath" execPath "\"$NODE_REAL\""
  REC="$SAVE_REC"
else
  c_bad "no --version record under <out>/home"
fi
case_end
case_begin "fence: static allowlist of fence-1.sb"
if [ -f "$OUT/fence-1.sb" ]; then
  c_tl "fence" fence-check "$OUT/fence-1.sb" "$REPO" "$OUT" "$DSH" "$NODE_REAL" "$FAKEHOME"
else
  c_bad "no fence-1.sb"
fi
case_end

# A node whose prefix is a broad system dir (/usr/local/bin/node, /opt/homebrew/bin/node, a
# copy at /private/tmp/bin/node) must get only its bin dir, never the prefix. No case can put
# a real node there without root, so this one calls the wrapper's fence_profile directly; the
# broad list is the test's own, not the wrapper's.
new_case "fence broad prefix"
case_begin "fence: a node under a broad prefix is narrowed to its bin dir (fence_profile)"
if [ -n "$SEL" ]; then
  if o="$("$PY" -I -B -c '
import importlib.machinery, importlib.util, os, sys
ld = importlib.machinery.SourceFileLoader("dsr_wrapper", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("dsr_wrapper", ld))
ld.exec_module(m)
broad = ["/", "/usr", "/usr/local", "/opt", "/opt/homebrew", "/Users", "/private", "/var", "/tmp",
         "/etc", "/private/var", "/private/tmp", "/private/etc"]
p = []
for node in ("/usr/local/bin/node", "/opt/homebrew/bin/node", "/private/tmp/bin/node", "/opt/bin/node"):
    t = m.fence_profile("/x/out", None, "/x/dsh", node, 1)
    for b in broad:
        if "(subpath \"%s\")" % b in t:
            p.append("%s: the fence allows the broad prefix %s" % (node, b))
    if "(allow file-read* (subpath \"%s\"))" % os.path.dirname(node) not in t:
        p.append("%s: the fence does not allow its bin dir" % node)
print("\n".join(p))
sys.exit(1 if p else 0)' "$BIN" 2>&1)"; then c_ok; else c_bad "${o:-the check printed nothing}"; fi
fi
case_end

new_case "umask"
make_repo "$REPO"
make_dsh "$DSH" ok read="$REPO/sentinel.txt"
run_w UMASK=022 -- --dsh-dir "$DSH" --out "$OUT" --repo "$REPO" "$PROMPT"
case_begin "permissions: every dir 0700 / file 0600 under out with caller umask 022"
h_pass
c_tl "modes" modes "$OUT" 13
case_end

# ==============================================================================================
echo "== env, key and PATH"

new_case "env scrub"
make_repo "$REPO"
make_dsh "$DSH" ok read="$REPO/sentinel.txt"
run_w ENV:FAKE_SECRET=fake-secret-sentinel ENV:DEEPSEEK_BASE_URL=http://evil.invalid \
  ENV:ANTHROPIC_API_KEY=anthropic-key-sentinel ENV:NODE_OPTIONS=--max-old-space-size=4097 \
  ENV:TMPDIR="$REPO" ENV:DSH_HOME="$FAKEHOME/.dsh" ENV:DSH_PROFILE=evil-profile \
  ENV:__CF_USER_TEXT_ENCODING=0x1F5:0x7:0x7 ENV:GIT_DIR="$TMP_REAL/nogit" \
  -- --dsh-dir "$DSH" --out "$OUT" --repo "$REPO" "$PROMPT"
case_begin "env: only the allowlist reaches dsh; inherited TMPDIR=<repo> ignored; GIT_DIR ignored"
h_pass
[ -n "$REC" ] && c_tl "env" env-check "$REC" "$OUT" keylen=24 lang=en_US.UTF-8 cf_sentinel=0x1F5:0x7:0x7 \
  forbid=fake-secret-sentinel forbid=evil.invalid forbid=anthropic-key-sentinel forbid=max-old-space \
  forbid=evil-profile forbid=FAKE_SECRET forbid=ANTHROPIC_API_KEY forbid=NODE_OPTIONS
case_end
new_case "env nolang"
make_dsh "$DSH" ok
run_w NOLANG -- --dsh-dir "$DSH" --out "$OUT" "$PROMPT"
case_begin "env: LANG is passed only when the caller set it"
h_pass
[ -n "$REC" ] && c_tl "env" env-check "$REC" "$OUT" keylen=24 lang=none
case_end

new_case "path hijack"
make_dsh "$DSH" ok
rm -f "$HIJ_MARK"
run_w CWD="$HIJ" PATH=":.:$WPATH" -- --dsh-dir "$DSH" --out "$OUT" "$PROMPT"
case_begin "PATH: empty and '.' entries are skipped; a cwd node is never run"
h_pass
h_path_absent "$HIJ_MARK" "the cwd's fake node ran"
h_rec_eq "execPath" execPath "\"$NODE_REAL\""
case_end
new_case "NODE_NOT_FOUND (only relative PATH entries hold node)"
make_dsh "$DSH" ok
rm -f "$HIJ_MARK"
run_w CWD="$HIJ" PATH=".:/usr/bin:/bin:/usr/sbin:/sbin" -- --dsh-dir "$DSH" --out "$OUT" "$PROMPT"
case_begin "setup: $CNAME"
h_setup NODE_NOT_FOUND
h_no_stub "$OUT" "$C"
h_path_absent "$HIJ_MARK" "the cwd's fake node ran"
case_end
new_case "NODE_NOT_FOUND (--node missing)"; make_dsh "$DSH" ok
wr --node "$C/no/node" "$PROMPT"; setup_end NODE_NOT_FOUND
new_case "NODE_IN_SCOPE (--node inside the repo)"; make_dsh "$DSH" ok; make_repo "$REPO"
mkdir -p "$REPO/tools"; cp -p "$NODE_REAL" "$REPO/tools/node"
wr --repo "$REPO" --node "$REPO/tools/node" "$PROMPT"; setup_end NODE_IN_SCOPE
new_case "NODE_IN_SCOPE (PATH resolves to a node inside the repo)"; make_dsh "$DSH" ok; make_repo "$REPO"
mkdir -p "$REPO/tools"; cp -p "$NODE_REAL" "$REPO/tools/node"
run_w PATH="$REPO/tools:$WPATH" -- --dsh-dir "$DSH" --out "$OUT" --repo "$REPO" "$PROMPT"; setup_end NODE_IN_SCOPE

new_case "nvm node"
make_repo "$REPO"
make_dsh "$DSH" ok read="$REPO/sentinel.txt"
run_w PATH="$NVM/bin:/usr/bin:/bin:/usr/sbin:/sbin" -- --dsh-dir "$DSH" --out "$OUT" --repo "$REPO" \
  --node "$NVM/bin/node" "$PROMPT"
case_begin "node at an unusual location (a copy under fakehome/.nvm, named with --node) starts under the fence"
h_pass
h_rec_eq "execPath" execPath "\"$NVM/bin/node\""
case_end
# The same node found through PATH: fakehome is HOME, not the account's home, so its .nvm is no
# known install location and PATH alone cannot pick it.
new_case "NODE_UNTRUSTED (PATH node outside the known install locations)"
make_repo "$REPO"
make_dsh "$DSH" ok read="$REPO/sentinel.txt"
run_w PATH="$NVM/bin:/usr/bin:/bin:/usr/sbin:/sbin" -- --dsh-dir "$DSH" --out "$OUT" --repo "$REPO" "$PROMPT"
setup_end NODE_UNTRUSTED

# ==============================================================================================
echo "== scope: --repo, --expect-read, --out, --dsh-dir"

scope_case() { # NAME CODE [run_w opts...] -- wrapper args (PROMPT appended)
  local name="$1" code="$2"
  shift 2
  run_w "$@" "$PROMPT"
  setup_end "$code"
}
new_case "REPO_NOT_DIR (a file)"; make_dsh "$DSH" ok; printf x > "$C/afile"
scope_case x REPO_NOT_DIR -- --dsh-dir "$DSH" --out "$OUT" --repo "$C/afile"
new_case "REPO_NOT_DIR (missing)"; make_dsh "$DSH" ok
scope_case x REPO_NOT_DIR -- --dsh-dir "$DSH" --out "$OUT" --repo "$C/nope"
new_case "REPO_IS_ROOT"; make_dsh "$DSH" ok
scope_case x REPO_IS_ROOT -- --dsh-dir "$DSH" --out "$OUT" --repo /
new_case "REPO_HOME_OR_ABOVE (HOME)"; make_dsh "$DSH" ok
scope_case x REPO_HOME_OR_ABOVE -- --dsh-dir "$DSH" --out "$OUT" --repo "$FAKEHOME"
# HOME is two levels down so the out and dsh dirs are NOT inside the repo (no OUT_OVERLAP or
# DSH_DIR_UNSAFE beside it); the repo is spelled through mktemp's /var form, not the realpath.
new_case "REPO_HOME_OR_ABOVE (HOME's parent, given via the non-realpath /var form)"; make_dsh "$DSH" ok
mkdir -p "$C/h1/home"; git -C "$C/h1" init -q
scope_case x REPO_HOME_OR_ABOVE HOME="$C/h1/home" -- --dsh-dir "$DSH" --out "$OUT" --repo "$TMP${C#"$TMP_REAL"}/h1"
new_case "REPO_SECRET_OVERLAP (inside ~/.ssh)"; make_dsh "$DSH" ok; make_repo "$FAKEHOME/.ssh/proj"
scope_case x REPO_SECRET_OVERLAP -- --dsh-dir "$DSH" --out "$OUT" --repo "$FAKEHOME/.ssh/proj"
new_case "REPO_SECRET_OVERLAP (symlink path whose realpath is inside ~/.ssh)"; make_dsh "$DSH" ok
[ -d "$FAKEHOME/.ssh/proj" ] || make_repo "$FAKEHOME/.ssh/proj"
ln -s "$FAKEHOME/.ssh/proj" "$C/ln-ssh"
scope_case x REPO_SECRET_OVERLAP -- --dsh-dir "$DSH" --out "$OUT" --repo "$C/ln-ssh"
new_case "REPO_SECRET_OVERLAP (repo contains the realpath of ~/.aws)"; make_dsh "$DSH" ok
AWSHOME="$C/awshome"; mkdir -p "$AWSHOME"; make_repo "$C/awsstore"; mkdir -p "$C/awsstore/inner/dotaws"
ln -s "$C/awsstore/inner/dotaws" "$AWSHOME/.aws"
scope_case x REPO_SECRET_OVERLAP HOME="$AWSHOME" -- --dsh-dir "$DSH" --out "$OUT" --repo "$C/awsstore"
new_case "REPO_SECRET_OVERLAP (inside ~/Library)"; make_dsh "$DSH" ok; make_repo "$FAKEHOME/Library/proj"
scope_case x REPO_SECRET_OVERLAP -- --dsh-dir "$DSH" --out "$OUT" --repo "$FAKEHOME/Library/proj"
new_case "REPO_SECRET_OVERLAP (inside ~/.claude)"; make_dsh "$DSH" ok; make_repo "$FAKEHOME/.claude/proj"
scope_case x REPO_SECRET_OVERLAP -- --dsh-dir "$DSH" --out "$OUT" --repo "$FAKEHOME/.claude/proj"
# Every other entry of the secret-dir list (.ssh, Library and .claude have cases above).
for sdir in .gnupg .aws .config .dsh .codex .gemini .kimi-code; do
  new_case "REPO_SECRET_OVERLAP (inside ~/$sdir)"; make_dsh "$DSH" ok; make_repo "$FAKEHOME/$sdir/proj"
  scope_case x REPO_SECRET_OVERLAP -- --dsh-dir "$DSH" --out "$OUT" --repo "$FAKEHOME/$sdir/proj"
done
new_case "REPO_NOT_GIT"; make_dsh "$DSH" ok; mkdir -p "$FAKEHOME/src/plain$CASE_N"
scope_case x REPO_NOT_GIT -- --dsh-dir "$DSH" --out "$OUT" --repo "$FAKEHOME/src/plain$CASE_N"
new_case "REPO_NOT_GIT (caller's GIT_DIR points at a real repo)"; make_dsh "$DSH" ok
mkdir -p "$FAKEHOME/src/plain$CASE_N"; make_repo "$C/realgit"
scope_case x REPO_NOT_GIT ENV:GIT_DIR="$C/realgit/.git" ENV:GIT_WORK_TREE="$C/realgit" \
  -- --dsh-dir "$DSH" --out "$OUT" --repo "$FAKEHOME/src/plain$CASE_N"
new_case "REPO_DOTFILES (work-tree root == HOME)"; make_dsh "$DSH" ok
DOTHOME="$C/dothome"; mkdir -p "$DOTHOME/projects/sub"; git -C "$DOTHOME" init -q
scope_case x REPO_DOTFILES HOME="$DOTHOME" -- --dsh-dir "$DSH" --out "$OUT" --repo "$DOTHOME/projects/sub"
new_case "GIT_* ignored"
make_repo "$REPO"
make_dsh "$DSH" ok read="$REPO/sentinel.txt"
# A wrapper that let these through would see the work tree root == HOME (REPO_DOTFILES).
DOTHOME2="$C/dothome"; mkdir -p "$DOTHOME2"; git -C "$DOTHOME2" init -q
run_w HOME="$DOTHOME2" ENV:GIT_DIR="$DOTHOME2/.git" ENV:GIT_WORK_TREE="$DOTHOME2" \
  -- --dsh-dir "$DSH" --out "$OUT" --repo "$REPO" "$PROMPT"
case_begin "scope: the caller's GIT_DIR/GIT_WORK_TREE do not redirect the repo check"
h_pass
case_end
new_case "REPO_BAD_CHARS (newline)"; make_dsh "$DSH" ok
BADR="$FAKEHOME/src/bad"$'\n'"name$CASE_N"; make_repo "$BADR"
scope_case x REPO_BAD_CHARS -- --dsh-dir "$DSH" --out "$OUT" --repo "$BADR"
new_case "REPO_BAD_CHARS (tab)"; make_dsh "$DSH" ok
BADR="$FAKEHOME/src/bad"$'\t'"tab$CASE_N"; make_repo "$BADR"
scope_case x REPO_BAD_CHARS -- --dsh-dir "$DSH" --out "$OUT" --repo "$BADR"
new_case "REPO_BAD_CHARS (DEL)"; make_dsh "$DSH" ok
BADR="$FAKEHOME/src/bad"$'\x7f'"del$CASE_N"; make_repo "$BADR"
scope_case x REPO_BAD_CHARS -- --dsh-dir "$DSH" --out "$OUT" --repo "$BADR"
new_case "REPO_BAD_CHARS (double quote)"; make_dsh "$DSH" ok
BADR="$FAKEHOME/src/bad\"quote$CASE_N"; make_repo "$BADR"
scope_case x REPO_BAD_CHARS -- --dsh-dir "$DSH" --out "$OUT" --repo "$BADR"
new_case "EXPECT_READ_NEEDS_REPO"; make_dsh "$DSH" ok
scope_case x EXPECT_READ_NEEDS_REPO -- --dsh-dir "$DSH" --out "$OUT" --expect-read "$OUTSIDE/secret.txt"
new_case "EXPECT_READ_OUTSIDE_REPO"; make_dsh "$DSH" ok; make_repo "$REPO"
scope_case x EXPECT_READ_OUTSIDE_REPO -- --dsh-dir "$DSH" --out "$OUT" --repo "$REPO" --expect-read "$OUTSIDE/secret.txt"
new_case "EXPECT_READ_OUTSIDE_REPO (repo symlink resolving outside)"; make_dsh "$DSH" ok; make_repo "$REPO"
ln -s "$OUTSIDE/secret.txt" "$REPO/link-out"
scope_case x EXPECT_READ_OUTSIDE_REPO -- --dsh-dir "$DSH" --out "$OUT" --repo "$REPO" --expect-read "$REPO/link-out"
new_case "OUT_EXISTS"; make_dsh "$DSH" ok; mkdir -p "$OUT"
run_w -- --dsh-dir "$DSH" --out "$OUT" "$PROMPT"
case_begin "setup: $CNAME"; h_setup OUT_EXISTS; h_no_stub "$OUT" "$C"
if [ -z "$(ls -A "$OUT")" ]; then c_ok; else c_bad "wrote into the existing out dir"; fi; case_end
new_case "OUT_OVERLAP (inside the repo)"; make_dsh "$DSH" ok; make_repo "$REPO"
scope_case x OUT_OVERLAP -- --dsh-dir "$DSH" --out "$REPO/review-out" --repo "$REPO"
new_case "OUT_OVERLAP (inside the repo through a symlinked parent)"; make_dsh "$DSH" ok; make_repo "$REPO"
ln -s "$REPO" "$C/ln-repo"
scope_case x OUT_OVERLAP -- --dsh-dir "$DSH" --out "$C/ln-repo/review-out" --repo "$REPO"
new_case "OUT_OVERLAP (inside the dsh dir)"; make_dsh "$DSH" ok
scope_case x OUT_OVERLAP -- --dsh-dir "$DSH" --out "$DSH/review-out"
# --out must not exist, so it can hold HOME only when HOME does not exist yet either. Apple's
# python creates ~/Library/Caches/com.apple.python at startup unless bytecode writing is off.
new_case "OUT_OVERLAP (HOME inside the out dir)"; make_dsh "$DSH" ok
scope_case x OUT_OVERLAP HOME="$C/hh/home" ENV:PYTHONDONTWRITEBYTECODE=1 -- --dsh-dir "$DSH" --out "$C/hh"
new_case "DSH_MISSING"; mkdir -p "$DSH"
scope_case x DSH_MISSING -- --dsh-dir "$DSH" --out "$OUT"
new_case "DSH_DIR_UNSAFE (0777)"; make_dsh "$DSH" ok; chmod 777 "$DSH"
scope_case x DSH_DIR_UNSAFE -- --dsh-dir "$DSH" --out "$OUT"
new_case "DSH_DIR_UNSAFE (group-writable 0770)"; make_dsh "$DSH" ok; chmod 770 "$DSH"
scope_case x DSH_DIR_UNSAFE -- --dsh-dir "$DSH" --out "$OUT"
new_case "DSH_DIR_UNSAFE (world-writable only 0702)"; make_dsh "$DSH" ok; chmod 702 "$DSH"
scope_case x DSH_DIR_UNSAFE -- --dsh-dir "$DSH" --out "$OUT"
new_case "DSH_DIR_UNSAFE (inside the repo)"; make_repo "$REPO"; make_dsh "$REPO/.dsh" ok
scope_case x DSH_DIR_UNSAFE -- --dsh-dir "$REPO/.dsh" --out "$OUT" --repo "$REPO"
new_case "DSH_VERSION_MISMATCH"; make_dsh "$DSH" ok version=0.2.1-rc.4
run_w -- --dsh-dir "$DSH" --out "$OUT" "$PROMPT"
case_begin "setup: $CNAME"
h_setup DSH_VERSION_MISMATCH
if [ -z "$(tl find-records record "$OUT" "$FAKEHOME")" ]; then c_ok; else c_bad "the review ran after a version mismatch"; fi
if [ -n "$(tl find-records version "$OUT")" ]; then c_ok; else c_bad "no --version record: the version was never asked"; fi
case_end
# Default out: under getconf's DARWIN_USER_TEMP_DIR, never under the inherited TMPDIR.
new_case "default out"
make_dsh "$DSH" ok
mkdir -p "$C/ctmp"
UTMP="$(realp "$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)")"
run_w ENV:TMPDIR="$C/ctmp" -- --dsh-dir "$DSH" "$PROMPT"
DOUT="$(printf '%s' "$STDERR" | sed -n 's/^out: \(.*\) (attempt 1)$/\1/p' | head -1)"
DOUT_OK=""
case_begin "scope: no --out puts out under DARWIN_USER_TEMP_DIR, ignoring the inherited TMPDIR"
if [ -z "$DOUT" ]; then
  c_bad "no 'out: <path> (attempt 1)' line on stderr — got: $(first_line "$STDERR")"
elif [ -n "$UTMP" ] && [ "$UTMP" != / ] && [ "$(realp "$(dirname "$DOUT")")" = "$UTMP" ] \
  && case "$(basename "$DOUT")" in deepseek-review-?*) true ;; *) false ;; esac; then
  c_ok
  DOUT_OK=1
else
  c_bad "out $DOUT is not $UTMP/deepseek-review-*"
fi
[ -n "$DOUT" ] && OUT="$DOUT"
h_pass
if [ -z "$(ls -A "$C/ctmp")" ]; then c_ok; else c_bad "the inherited TMPDIR got files: $(ls -A "$C/ctmp" | tr '\n' ' ')"; fi
case_end
# Remove the out dir only when it is the user temp dir's deepseek-review-* child we checked.
if [ -n "$DOUT_OK" ] && [ -d "$DOUT" ] && [ ! -L "$DOUT" ]; then rm -rf "$DOUT"; fi

note_skip "setup: NO_SANDBOX: no seam to hide /usr/bin/sandbox-exec without root (needs an implementer seam)"
note_skip "setup: OUT_PERMS (dir owned by another user): needs a second account or root"
note_skip "setup: DSH_DIR_UNSAFE (dir owned by another user): needs a second account or root"

# ==============================================================================================
echo "== attempts: --continue and --check"

new_case "continue"
make_repo "$REPO"
make_dsh "$DSH" ok sid=session-stub-cont-1 read="$REPO/sentinel.txt"
wr --repo "$REPO" "$PROMPT"
A1_RC=$RC
A1_OUT="$OUT"
hash1() { for f in "$OUT"/*-1.*; do [ -f "$f" ] && shasum -a 256 "$f"; done 2>/dev/null; }
H1="$(hash1)"
ELSE="$C/elsewhere"; make_repo "$ELSE"
set_scenario ok sid=session-stub-other read="$REPO/src/a.txt" \
  probe_read="$OUT/run-1.patch.yml" probe_read="$OUT/run-2.patch.yml" probe_read="$OUT/prompt-2.txt"
printf 'Second question: look at src/a.txt.\n' > "$C/prompt2.txt"
PROMPT_SAVE="$PROMPT"; PROMPT="$C/prompt2.txt"
rm -f "$OUT"/home/stub-record-*.json 2>/dev/null
run_w CWD="$ELSE" -- --continue "$OUT" --dsh-dir "$DSH" "$PROMPT"
case_begin "attempts: --continue from another cwd writes *-2.*, keeps *-1.*, resumes the session"
if [ "$A1_RC" = 0 ]; then c_ok; else c_bad "attempt 1 exit $A1_RC"; fi
h_pass
h_layout 2
if [ -n "$H1" ] && [ "$H1" = "$(hash1)" ]; then c_ok; else c_bad "*-1.* files changed (or never existed)"; fi
if [ -n "$REC" ]; then
  c_tl "argv" argv-exact "$REC" "$OUT" 2 session-stub-cont-1
  h_rec_eq "stub cwd is the recorded repo" cwd "\"$REPO\""
  c_tl "env (same home)" env-check "$REC" "$OUT" keylen=24
  c_tl "attempt files" attempt-check "$REC" "$PROMPT" "$OUT" 2
fi
case_end
case_begin "attempts: attempt 2 reads review.patch.yml and run-2.patch.yml, not run-1.patch.yml"
if [ -n "$REC" ]; then
  c_tl "patch reads" patch-reads "$REC" "$OUT/review.patch.yml" "$OUT/run-2.patch.yml"
  h_probe read "$OUT/run-2.patch.yml" OK
  h_probe read "$OUT/run-1.patch.yml" EPERM
  h_probe read "$OUT/prompt-2.txt" EPERM
else
  c_bad "no attempt-2 stub record (err-2: $(first_line "$(cat "$OUT/err-2.txt" 2>/dev/null)"))"
fi
if [ -f "$OUT/fence-2.sb" ]; then
  c_tl "fence-2" fence-check "$OUT/fence-2.sb" "$REPO" "$OUT" "$DSH" "$NODE_REAL" "$FAKEHOME" 2
else
  c_bad "no fence-2.sb"
fi
case_end
case_begin "attempts: --continue status-2 and --check"
c_tl "status-2" status-check "$OUT/status-2.json" attempt=2 repo="\"$REPO\"" repo_mode=true
N1="$(tl rec "$OUT/status-1.json" nonce 2>/dev/null)"; N2="$(tl rec "$OUT/status-2.json" nonce 2>/dev/null)"
if [ -n "$N1" ] && [ -n "$N2" ] && [ "$N1" != "$N2" ]; then c_ok; else c_bad "nonce not new per attempt ($N1 / $N2)"; fi
h_check_agrees
case_end
# Third attempt fails; --check picks the highest attempt by default and --attempt selects.
set_scenario verdict_missing sid=session-stub-other read="$REPO/sentinel.txt"
H12="$(for f in "$OUT"/*-1.* "$OUT"/*-2.*; do [ -f "$f" ] && shasum -a 256 "$f"; done 2>/dev/null)"
run_w -- --continue "$OUT" --dsh-dir "$DSH" "$PROMPT"
case_begin "attempts: --check defaults to the highest attempt; --check --attempt N selects"
h_fail_codes VERDICT_MISSING exact
h_check_agrees
run_w -- --check "$OUT" --attempt 2
h_rc 0
if [ -n "$STDOUT" ]; then c_ok; else c_bad "--check --attempt 2 printed no answer"; fi
if [ -n "$H12" ] && [ "$H12" = "$(for f in "$OUT"/*-1.* "$OUT"/*-2.*; do [ -f "$f" ] && shasum -a 256 "$f"; done 2>/dev/null)" ]; then
  c_ok
else
  c_bad "earlier attempt files changed"
fi
case_end
OTHER="$C/other-repo"; make_repo "$OTHER"
BEFORE="$(tl tree-hash "$OUT" 2>/dev/null)"
run_w -- --continue "$OUT" --repo "$OTHER" --dsh-dir "$DSH" "$PROMPT"
case_begin "setup: CONTINUE_REPO_MISMATCH (--continue with a different --repo)"
h_setup CONTINUE_REPO_MISMATCH
h_path_absent "$OUT/prompt-4.txt" "a 4th attempt was started"
if [ -n "$BEFORE" ] && [ "$BEFORE" = "$(tl tree-hash "$OUT" 2>/dev/null)" ]; then c_ok; else c_bad "out dir changed"; fi
case_end
mkdir -p "$OUT/home" 2>/dev/null
cp -p "$NODE_REAL" "$OUT/home/node" 2>/dev/null
run_w -- --continue "$OUT" --node "$OUT/home/node" --dsh-dir "$DSH" "$PROMPT"
case_begin "setup: NODE_IN_SCOPE (--continue with a node inside the out dir)"
h_setup NODE_IN_SCOPE
h_path_absent "$OUT/prompt-4.txt" "a 4th attempt was started"
case_end
PROMPT="$PROMPT_SAVE"

new_case "OUT_PERMS"
make_dsh "$DSH" ok
printf '{"type":"final","text":"x"}\n' > "$C/fab.jsonl"; : > "$C/fab.err"
tl fabricate "$OUT" "$C/fab.jsonl" "$C/fab.err" 0 0123456789abcdef -
chmod 755 "$OUT"
run_w -- --continue "$OUT" --dsh-dir "$DSH" "$PROMPT"
case_begin "setup: OUT_PERMS (--continue on a 0755 out dir)"
h_setup OUT_PERMS
h_no_stub "$OUT" "$C"
case_end
run_w -- --check "$OUT"
case_begin "setup: OUT_PERMS (--check on a 0755 out dir)"
h_setup OUT_PERMS
case_end

# --continue setup errors on fabricated 0700 out dirs (attempt 1 only, written by tlib).
new_case "continue setup"
make_dsh "$DSH" ok
printf '{"type":"session","sessionId":"session-fab-1","cwd":"/x"}\n{"type":"final","text":"x"}\n' > "$C/fab-s.jsonl"
printf '{"type":"final","text":"x"}\n' > "$C/fab-n.jsonl"
: > "$C/fab.err"
OUT="$C/out-stray"
tl fabricate "$OUT" "$C/fab-s.jsonl" "$C/fab.err" 0 0123456789abcdef -
cp "$PLUGIN/dsh/review.patch.yml" "$OUT/review.patch.yml"   # present, so --continue writes nothing before the check
printf 'stray fence\n' > "$OUT/fence-2.sb"
printf 'stray patch\n' > "$OUT/run-2.patch.yml"
run_w -- --continue "$OUT" --dsh-dir "$DSH" "$PROMPT"
# A failed attempt 2 (its setup wrote fence-2.sb and run-2.patch.yml, then stopped) must not block
# every later --continue with OUT_EXISTS: the next attempt is 3, and attempt 2's files stay as they are.
case_begin "attempts: --continue after a failed attempt 2 (stray fence-2.sb, run-2.patch.yml) runs as attempt 3"
h_path_present "$OUT/prompt-3.txt" "attempt 3"
h_path_absent "$OUT/prompt-2.txt" "attempt 2 rerun"
if [ "$(cat "$OUT/fence-2.sb" 2>/dev/null)" = "stray fence" ] && [ "$(cat "$OUT/run-2.patch.yml" 2>/dev/null)" = "stray patch" ]; then
  c_ok
else
  c_bad "attempt 2's files were rewritten"
fi
c_tl "status-3" status-check "$OUT/status-3.json" attempt=3
if printf '%s' "$STDERR" | grep -q 'ERROR OUT_EXISTS'; then c_bad "refused with OUT_EXISTS"; else c_ok; fi
case_end
if [ -n "$SEL" ]; then printf 'stray fence\n' > "$OUT/fence-4.sb"; printf 'stray patch\n' > "$OUT/run-4.patch.yml"; fi
run_w -- --check "$OUT"
case_begin "attempts: --check ignores a setup-only attempt 4 (stray fence-4.sb, run-4.patch.yml) and judges attempt 3"
h_stderr_has "check: attempt 3 in"
h_text_lacks "stderr" "ATTEMPT_INCOMPLETE" "$STDERR"
case_end
OUT="$C/out-nosession"
tl fabricate "$OUT" "$C/fab-n.jsonl" "$C/fab.err" 0 0123456789abcdef -
run_w -- --continue "$OUT" --dsh-dir "$DSH" "$PROMPT"
case_begin "setup: CONTINUE_NO_SESSION (run-1.jsonl holds no session event)"
h_setup CONTINUE_NO_SESSION
h_no_stub "$OUT"
h_path_absent "$OUT/prompt-2.txt" "a 2nd attempt was started"
case_end
OUT="$C/out-gone"
tl fabricate "$OUT" "$C/fab-s.jsonl" "$C/fab.err" 0 0123456789abcdef "$C/gone-repo"
run_w -- --continue "$OUT" --dsh-dir "$DSH" "$PROMPT"
case_begin "setup: REPO_NOT_DIR (--continue when the recorded repo is gone)"
h_setup REPO_NOT_DIR
h_stderr_has "the recorded repo is gone"
h_no_stub "$OUT"
h_path_absent "$OUT/prompt-2.txt" "a 2nd attempt was started"
case_end

# ==============================================================================================
echo "== process lifetime"

life_case() { # NAME HOW(timeout|INT|TERM|HUP) KIND WANT_REASON WANT_SIGNAL_JSON WANT_EXIT_JSON [timeout]
  local name="$1" how="$2" kind="$3" reason="$4" wsig="$5" wexit="$6" tmo="${7:-3s}"
  local marker="$RUNID-gc-$CASE_N-$how" t0 t1
  new_case "$name"
  make_dsh "$DSH" "$kind" marker="$marker"
  t0="$(now)"
  if [ "$how" = timeout ]; then
    run_w ALARM=60 -- --dsh-dir "$DSH" --out "$OUT" --timeout "$tmo" "$PROMPT"
    BG_HUNG=""
  else
    run_w_bg ALARM=60 -- --dsh-dir "$DSH" --out "$OUT" --timeout 120 "$PROMPT"
    STARTED=""
    wait_stub 20 && STARTED=1
    [ -n "$STARTED" ] && kill -"$how" "$BGPID" 2>/dev/null
    bg_wait 30
  fi
  t1="$(now)"
  case_begin "lifetime: $name"
  if [ "$how" != timeout ] && [ -z "$STARTED" ]; then c_bad "the stub never started, so no SIG$how was sent"; fi
  if [ -n "$BG_HUNG" ]; then c_bad "wrapper still running 30 s after SIG$how"; fi
  h_fail_codes CANCELLED contains
  h_record
  if [ "$kind" != trap ]; then
    if [ -n "$REC" ] && [ "$(tl rec "$REC" grandchild_pid 2>/dev/null)" != null ]; then c_ok; else c_bad "the grandchild never started (scenario not reproduced)"; fi
    h_gone "$marker" 10
  else
    # The trap fired: dsh printed a perfect stream and exited 0, and the run is still a FAIL.
    if grep -q "VERDICT-[0-9a-f]\{16\}: NO FINDINGS" "$OUT/run-1.jsonl" 2>/dev/null; then c_ok; else c_bad "run-1.jsonl lacks the trapped stream (trap scenario not reproduced)"; fi
    [ -n "$REC" ] && c_tl "attempt files" attempt-check "$REC" "$PROMPT" "$OUT" 1 sigterm
  fi
  c_tl "status" status-check "$OUT/status-1.json" cancelled=true cancel_reason="\"$reason\"" \
    signal="$wsig" exit_code="$wexit" verdict='"FAIL"'
  if [ "$kind" = hang_ignore ]; then
    # SIGTERM ignored: the group must get SIGKILL after the 6 s grace, not before.
    if "$PY" -c "import sys; d=$t1-$t0; sys.exit(0 if 2+5 <= d <= 30 else 1)"; then c_ok; else c_bad "wall $(echo "$t1 - $t0" | bc)s, expected ~2+6 s"; fi
    # The SIGTERM went to the whole group, not only to dsh: the grandchild (which ignores it
    # and records it) got it too, during the grace.
    h_path_present "$OUT/home/grandchild-sigterm.txt" "the grandchild never got SIGTERM (only dsh was signalled)"
  elif [ "$how" = timeout ]; then
    if "$PY" -c "import sys; d=$t1-$t0; sys.exit(0 if 2.5 <= d <= 20 else 1)"; then c_ok; else c_bad "wall $(echo "$t1 - $t0" | bc)s for --timeout 3s"; fi
  fi
  h_check_agrees
  pkill -9 -f "$marker" 2>/dev/null
  case_end
}
life_case "trapped SIGTERM + perfect stream after --timeout 3s is still CANCELLED" timeout trap timeout null 0
life_case "trapped SIGTERM + perfect stream after SIGINT to the wrapper is still CANCELLED" INT trap SIGINT null 0
life_case "--timeout 3s kills the whole group (grandchild)" timeout hang timeout 15 null
life_case "SIGINT kills the whole group (grandchild)" INT hang SIGINT 15 null
life_case "SIGTERM kills the whole group (grandchild)" TERM hang SIGTERM 15 null
life_case "SIGHUP kills the whole group (grandchild)" HUP hang SIGHUP 15 null
life_case "SIGTERM ignored: SIGKILL after the 6 s grace" timeout hang_ignore timeout 9 null 2s

# dsh exits 0 on its own but leaves a grandchild in its group (a grep it started, say): the
# wrapper's post-exit group SIGKILL removes it; the run itself is a review.
new_case "orphan grandchild"
OG_MARK="$RUNID-gc-$CASE_N-orphan"
make_dsh "$DSH" ok marker="$OG_MARK"
wr "$PROMPT"
case_begin "lifetime: a grandchild left by a dsh that exited 0 is killed with the group"
h_pass
if [ -n "$REC" ] && [ "$(tl rec "$REC" grandchild_pid 2>/dev/null)" != null ]; then c_ok; else c_bad "the grandchild never started (scenario not reproduced)"; fi
h_gone "$OG_MARK" 5
case_end
pkill -9 -f "$OG_MARK" 2>/dev/null

# A child that never reads stdin, with a prompt larger than the pipe buffer: the timeout still
# fires (the wrapper must not block writing stdin).
new_case "noread"
NR_MARK="$RUNID-gc-$CASE_N-noread"
make_dsh "$DSH" hang_noread marker="$NR_MARK"
"$PY" -c 'import sys; open(sys.argv[1], "w").write("Review this.\n" + ("y" * 1023 + "\n") * 1024)' "$PROMPT"
NR_SIZE="$(stat -f %z "$PROMPT")"
t0="$(now)"
run_w ALARM=40 -- --dsh-dir "$DSH" --out "$OUT" --timeout 3s "$PROMPT"
t1="$(now)"
case_begin "lifetime: a child that never reads a 1 MiB stdin cannot block --timeout 3s"
if [ "$NR_SIZE" -ge 1048576 ]; then c_ok; else c_bad "prompt only $NR_SIZE bytes"; fi
if "$PY" -c "import sys; d=$t1-$t0; sys.exit(0 if 2.5 <= d <= 20 else 1)"; then c_ok; else c_bad "wall $(echo "$t1 - $t0" | bc)s for --timeout 3s (exit $RC)"; fi
h_fail_codes CANCELLED contains
h_record
h_rec_eq "the stub never read stdin (scenario reproduced)" stdin_error '"not read (no_stdin)"'
c_tl "status" status-check "$OUT/status-1.json" cancelled=true cancel_reason='"timeout"' verdict='"FAIL"'
h_gone "$NR_MARK" 10
case_end
pkill -9 -f "$NR_MARK" 2>/dev/null
pkill -9 -f "$DSH/" 2>/dev/null

# ==============================================================================================
echo "== --install and --doctor"

# make_npm PREFIX RC -- a stand-in PREFIX/bin/node (never run by --install) and, beside it, a stub
# PREFIX/bin/npm that records its argv, cwd and env under PREFIX and exits RC. --install runs the
# npm beside node, so every case names this node with --node (no real npm is ever reachable).
make_npm() {
  mkdir -p "$1/bin"
  printf '#!/bin/bash\nprintf "%%s\\0" "$@" > "%s/npm-argv"\npwd -P > "%s/npm-cwd"\n/usr/bin/env > "%s/npm-env"\nexit %s\n' \
    "$1" "$1" "$1" "$2" > "$1/bin/npm"
  printf '#!/bin/sh\nexit 0\n' > "$1/bin/node"
  chmod 755 "$1/bin/npm" "$1/bin/node"
}
new_case "install"
make_npm "$C/np" 0
INST="$C/inst/dsh-$PINNED"; mkdir -p "$C/inst"
run_w PATH="$WPATH" ENV:npm_config_registry=http://127.0.0.1:9 ENV:NODE_OPTIONS=--require=/x/evil.js \
  -- --install --node "$C/np/bin/node" --dsh-dir "$INST"
case_begin "install: npm ci --ignore-scripts in a 0700 dsh dir with the pinned package files"
h_rc 0
h_no_traceback
if [ -f "$C/np/npm-argv" ]; then
  ARGVJ="$(tl nul-argv "$C/np/npm-argv")"
  if [ "$ARGVJ" = '["ci", "--ignore-scripts", "--no-audit", "--no-fund"]' ]; then c_ok; else c_bad "npm argv $ARGVJ"; fi
  if [ "$(cat "$C/np/npm-cwd")" = "$INST" ]; then c_ok; else c_bad "npm cwd $(cat "$C/np/npm-cwd"), expected $INST"; fi
else
  c_bad "the stub npm never ran"
fi
if cmp -s "$INST/package.json" "$PLUGIN/dsh/package.json"; then c_ok; else c_bad "package.json not copied byte-identical"; fi
if cmp -s "$INST/package-lock.json" "$PLUGIN/dsh/package-lock.json"; then c_ok; else c_bad "package-lock.json not copied byte-identical"; fi
if [ -d "$INST" ] && [ "$(stat -f '%Lp' "$INST")" = 700 ]; then c_ok; else c_bad "dsh dir missing or not 0700"; fi
case_end
case_begin "install: npm gets PATH=<node's dir>:<system dirs>, the account's HOME, and none of the caller's variables"
if [ -f "$C/np/npm-env" ]; then
  for v in DEEPSEEK_API_KEY npm_config_registry NODE_OPTIONS; do
    if grep -q "^$v=" "$C/np/npm-env"; then c_bad "npm got $v"; else c_ok; fi
  done
  if grep -qxF "PATH=$C/np/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$C/np/npm-env"; then c_ok; else c_bad "npm PATH: $(grep '^PATH=' "$C/np/npm-env")"; fi
  if grep -qxF "HOME=$PW_HOME" "$C/np/npm-env"; then c_ok; else c_bad "npm HOME: $(grep '^HOME=' "$C/np/npm-env")"; fi
  if grep -qxF "LANG=en_US.UTF-8" "$C/np/npm-env"; then c_ok; else c_bad "npm LANG (the caller's): $(grep '^LANG=' "$C/np/npm-env")"; fi
else
  c_bad "the stub npm never ran"
fi
case_end
new_case "install hijack"
make_npm "$C/np" 0
make_npm "$C/pathnpm" 0
rm -f "$HIJ_MARK"
run_w CWD="$HIJ" PATH=".:$C/pathnpm/bin:$WPATH" ENV:npm_config_registry=http://127.0.0.1:9 \
  -- --install --node "$C/np/bin/node" --dsh-dir "$C/inst2"
case_begin "install: the npm beside node runs, never one from PATH (relative or absolute)"
h_rc 0
h_path_present "$C/np/npm-argv" "the npm beside node did not run"
h_path_absent "$C/pathnpm/npm-argv" "the absolute-PATH npm ran"
h_path_absent "$HIJ_MARK" "the cwd's fake npm ran"
case_end
new_case "install failed"
make_npm "$C/np" 1
run_w ENV:npm_config_registry=http://127.0.0.1:9 -- --install --node "$C/np/bin/node" --dsh-dir "$C/inst3"
case_begin "install: npm failing is INSTALL_FAILED (exit 1)"
h_rc 1
h_stderr_has "deepseek-review: ERROR INSTALL_FAILED:"
h_path_present "$C/np/npm-argv" "the stub npm did not run"
case_end
new_case "install no npm"
make_npm "$C/np" 0
rm -f "$C/np/bin/npm"
run_w -- --install --node "$C/np/bin/node" --dsh-dir "$C/inst4"
case_begin "install: no npm beside node is INSTALL_FAILED, and the dsh dir is never created"
h_rc 1
h_stderr_has "deepseek-review: ERROR INSTALL_FAILED: no npm beside node"
h_path_absent "$C/inst4" "the dsh dir was created"
case_end
new_case "install unsafe dir"
make_npm "$C/np" 0
HOME_MODE="$(stat -f '%Lp' "$FAKEHOME")"
run_w -- --install --node "$C/np/bin/node" --dsh-dir "$FAKEHOME"
case_begin "install: --dsh-dir HOME is DSH_DIR_UNSAFE before anything is written"
h_setup DSH_DIR_UNSAFE
h_path_absent "$FAKEHOME/package.json" "package.json was copied into HOME"
h_path_absent "$C/np/npm-argv" "npm ran"
if [ "$(stat -f '%Lp' "$FAKEHOME")" = "$HOME_MODE" ]; then c_ok; else c_bad "HOME's mode changed to $(stat -f '%Lp' "$FAKEHOME")"; fi
case_end
new_case "install not empty"
make_npm "$C/np" 0
mkdir -p "$C/proj"; printf 'KEEP\n' > "$C/proj/package.json"; printf 'x\n' > "$C/proj/main.go"
run_w -- --install --node "$C/np/bin/node" --dsh-dir "$C/proj"
case_begin "install: a dir holding other files is INSTALL_DIR_NOT_EMPTY, and its package.json is untouched"
h_setup INSTALL_DIR_NOT_EMPTY
if printf '%s' "$STDERR" | grep "^deepseek-review: ERROR INSTALL_DIR_NOT_EMPTY:" | grep -qF main.go; then
  c_ok
else
  c_bad "the INSTALL_DIR_NOT_EMPTY line does not name main.go"
fi
if [ "$(cat "$C/proj/package.json")" = KEEP ]; then c_ok; else c_bad "package.json was replaced"; fi
h_path_absent "$C/np/npm-argv" "npm ran"
case_end
# Each install refusal and npm check on its own (tester round 8).
new_case "install dir is a file"
make_npm "$C/np" 0
printf 'x\n' > "$C/afile"
run_w -- --install --node "$C/np/bin/node" --dsh-dir "$C/afile"
case_begin "install: --dsh-dir naming a file is DSH_DIR_UNSAFE"
h_setup DSH_DIR_UNSAFE
h_stderr_has "exists and is not a dir"
h_path_absent "$C/np/npm-argv" "npm ran"
case_end
for mode in 770 702; do
  new_case "install dir mode $mode"
  make_npm "$C/np" 0
  mkdir -p "$C/inst-$mode"
  chmod "$mode" "$C/inst-$mode"
  run_w -- --install --node "$C/np/bin/node" --dsh-dir "$C/inst-$mode"
  case_begin "install: an existing dsh dir with mode $mode (group- or world-writable) is DSH_DIR_UNSAFE"
  h_setup DSH_DIR_UNSAFE
  h_stderr_has "must be owned by you and not group/world-writable"
  h_path_absent "$C/np/npm-argv" "npm ran"
  h_path_absent "$C/inst-$mode/package.json" "package.json was copied"
  case_end
done
new_case "install dir owned by root"
make_npm "$C/np" 0
run_w -- --install --node "$C/np/bin/node" --dsh-dir /usr/share
case_begin "install: --dsh-dir /usr/share (owned by root) is DSH_DIR_UNSAFE"
if [ "$(stat -f '%u' /usr/share)" = 0 ]; then c_ok; else c_bad "precondition: /usr/share is not owned by root"; fi
h_setup DSH_DIR_UNSAFE
h_stderr_has "must be owned by you"
h_path_absent "$C/np/npm-argv" "npm ran"
case_end
new_case "install npm not executable"
make_npm "$C/np" 0
chmod 644 "$C/np/bin/npm"
run_w -- --install --node "$C/np/bin/node" --dsh-dir "$C/inst5"
case_begin "install: an npm beside node that is not executable is INSTALL_FAILED, and the dsh dir is never created"
h_rc 1
h_stderr_has "deepseek-review: ERROR INSTALL_FAILED: no npm beside node"
h_no_traceback
h_path_absent "$C/inst5" "the dsh dir was created"
case_end
new_case "install npm is a dir"
make_npm "$C/np" 0
rm -f "$C/np/bin/npm"
mkdir -p "$C/np/bin/npm"
run_w -- --install --node "$C/np/bin/node" --dsh-dir "$C/inst6"
case_begin "install: an npm beside node that is a directory is INSTALL_FAILED, and the dsh dir is never created"
h_rc 1
h_stderr_has "deepseek-review: ERROR INSTALL_FAILED: no npm beside node"
h_no_traceback
h_path_absent "$C/inst6" "the dsh dir was created"
case_end
new_case "install npm outside the prefix"
make_npm "$C/np" 0
make_npm "$C/far" 0
rm -f "$C/np/bin/npm"
ln -s "$C/far/bin/npm" "$C/np/bin/npm"
run_w -- --install --node "$C/np/bin/node" --dsh-dir "$C/inst7"
case_begin "install: an npm beside node that resolves outside node's prefix is INSTALL_FAILED, and it never runs"
h_rc 1
h_stderr_has "deepseek-review: ERROR INSTALL_FAILED: no npm beside node"
h_path_absent "$C/far/npm-argv" "the npm outside node's prefix ran"
h_path_absent "$C/inst7" "the dsh dir was created"
case_end
# node's prefix is dirname(dirname(node)), nothing wider: an npm in a sibling prefix under the
# same parent is still outside it.
new_case "install npm in a sibling prefix"
make_npm "$C/pre/x" 0
make_npm "$C/pre/y" 0
rm -f "$C/pre/x/bin/npm"
ln -s "$C/pre/y/bin/npm" "$C/pre/x/bin/npm"
run_w -- --install --node "$C/pre/x/bin/node" --dsh-dir "$C/inst7b"
case_begin "install: an npm beside node that resolves into a sibling prefix (same parent dir) is INSTALL_FAILED, and it never runs"
h_rc 1
h_stderr_has "deepseek-review: ERROR INSTALL_FAILED: no npm beside node"
h_no_traceback
h_path_absent "$C/pre/y/npm-argv" "the npm in the sibling prefix ran"
h_path_absent "$C/inst7b" "the dsh dir was created"
case_end
new_case "install again"
make_npm "$C/np" 0
run_w -- --install --node "$C/np/bin/node" --dsh-dir "$C/inst8"
R1_RC=$RC
mkdir -p "$C/inst8/node_modules"
rm -f "$C/np/npm-argv"
run_w -- --install --node "$C/np/bin/node" --dsh-dir "$C/inst8"
case_begin "install: a second --install into the same dir runs (package.json, package-lock.json, node_modules are no other files)"
if [ "$R1_RC" = 0 ]; then c_ok; else c_bad "control: the first --install exit $R1_RC"; fi
h_rc 0
h_path_present "$C/np/npm-argv" "npm did not run the second time"
case_end

new_case "doctor"
make_dsh "$DSH" ok
run_w KEY=FAKE-doctor-key-0123456789 -- --doctor --dsh-dir "$DSH" --node "$NODEBIN/node"
case_begin "doctor: reports the key's presence and length, never its value"
if printf '%s%s' "$STDOUT" "$STDERR" | grep -qF 'key: present (length 26)'; then c_ok; else c_bad "no 'key: present (length 26)' — got: $(first_line "$STDOUT$STDERR")"; fi
h_text_lacks "doctor output" "FAKE-doctor-key" "$STDOUT$STDERR"
h_no_traceback
case_end
run_w NOKEY -- --doctor --dsh-dir "$DSH" --node "$NODEBIN/node"
case_begin "doctor: reports a missing key"
if printf '%s%s' "$STDOUT" "$STDERR" | grep -qF 'key: missing'; then c_ok; else c_bad "no 'key: missing' — got: $(first_line "$STDOUT$STDERR")"; fi
case_end
# The doctor's --version and --dump-config run the stub under the doctor's own fence. The stub
# answers --dump-config like a run: its scenario's stderr and exit code.
doctor_line() { # EXACT-LINE
  if printf '%s\n' "$STDOUT" | grep -qxF -- "$1"; then c_ok; else c_bad "no stdout line '$1' — got: $(first_line "$STDOUT")"; fi
}
doctor_starts() { # PREFIX (fixed string)
  local l
  while IFS= read -r l; do
    case "$l" in "$1"*) c_ok; return ;; esac
  done <<<"$STDOUT"
  c_bad "no stdout line starting '$1' — got: $(first_line "$STDOUT")"
}
new_case "doctor overlay"
make_dsh "$DSH" ok
run_w -- --doctor --dsh-dir "$DSH" --node "$NODEBIN/node"
case_begin "doctor: a clean --dump-config under the fence is OK (exit 0)"
h_rc 0
doctor_line "dsh: $(realp "$DSH") version $PINNED (pinned $PINNED) OK"
doctor_line "overlay: composes cleanly under the fence"
case_end
set_scenario exit1
run_w -- --doctor --dsh-dir "$DSH" --node "$NODEBIN/node"
case_begin "doctor: a failing --dump-config is an overlay PROBLEM (exit 1)"
h_rc 1
doctor_line "dsh: $(realp "$DSH") version $PINNED (pinned $PINNED) OK"
doctor_starts "overlay: PROBLEM: exit 1 "
case_end
set_scenario compose_activate
run_w -- --doctor --dsh-dir "$DSH" --node "$NODEBIN/node"
case_begin "doctor: a composition warning from --dump-config is an overlay PROBLEM (exit 1)"
h_rc 1
doctor_starts "overlay: PROBLEM: 1 entry did not activate "
case_end
set_scenario ok version=0.2.1-rc.4
run_w -- --doctor --dsh-dir "$DSH" --node "$NODEBIN/node"
case_begin "doctor: a dsh version other than the pin is a MISMATCH (exit 1)"
h_rc 1
doctor_starts "dsh: $(realp "$DSH") version 0.2.1-rc.4 (pinned $PINNED) MISMATCH ("
case_end

# ==============================================================================================
echo "== HIGH review findings H1-H12 (2026-11-02) and regressions of the refuted and medium findings"

# fake_tool DIR NAME MARKER -- an executable NAME in DIR that writes the NAMES of its env (never a
# value: the env may hold the key) to MARKER and exits 3.
fake_tool() {
  mkdir -p "$1"
  printf '#!/bin/sh\n/usr/bin/env | /usr/bin/cut -d= -f1 > "%s"\nexit 3\n' "$3" > "$1/$2"
  chmod 755 "$1/$2"
}
# h_marker_absent MARKER LABEL -- MARKER does not exist; if it does, say whether the key reached it.
h_marker_absent() {
  if [ ! -e "$1" ]; then
    c_ok
  elif grep -qx DEEPSEEK_API_KEY "$1" 2>/dev/null; then
    c_bad "$2 (its env held DEEPSEEK_API_KEY)"
  else
    c_bad "$2"
  fi
}
# h_record_glob -- like h_record, for an out path a line-based finder cannot carry (a newline).
h_record_glob() {
  local recs=("$OUT"/home/stub-record-*.json)
  if [ "${#recs[@]}" = 1 ] && [ -f "${recs[0]}" ]; then REC="${recs[0]}"; c_ok; else REC=""; c_bad "expected 1 stub record under <out>/home"; fi
}
h_verdict_stdout() {
  if printf '%s' "$STDOUT" | grep -q '^VERDICT-[0-9a-f]\{16\}: \(NO \)\{0,1\}FINDINGS$'; then c_ok; else c_bad "stdout lacks a VERDICT line: $(first_line "$STDOUT")"; fi
}
# wait_version SECS -- until the stub's --version record appears under OUT or the wrapper is gone.
wait_version() {
  [ -n "$SEL" ] || return 1
  local i=0 lim=$(($1 * 10))
  while [ "$i" -lt "$lim" ]; do
    [ -n "$(tl find-records version "$OUT")" ] && return 0
    kill -0 "$BGPID" 2>/dev/null || return 1
    psleep 0.1
    i=$((i + 1))
  done
  return 1
}
# fab_out OUT VARIANT REPO|- [fab-stream args...] -- a fabricated attempt-1 out dir for --check.
fab_out() {
  [ -n "$SEL" ] || return 0
  local o="$1" v="$2" r="$3" n
  shift 3
  n="$("$PY" -I "$FIX/tlib.py" nonce)"
  "$PY" -I "$FIX/tlib.py" fab-stream "$C/fab-$v.jsonl" "$n" "$v" "$@" || { echo "FATAL: fab-stream $v"; exit 1; }
  : > "$C/fab-$v.err"
  "$PY" -I "$FIX/tlib.py" fabricate "$o" "$C/fab-$v.jsonl" "$C/fab-$v.err" 0 "$n" "$r" || { echo "FATAL: fabricate $o"; exit 1; }
}

# --- H1: the wrapper's interpreter is never picked by the caller's PATH or PYTHONPATH -----------
new_case "H1 python3 on PATH"
make_dsh "$DSH" ok
fake_tool "$C/pybin" python3 "$C/fake-python-ran"
run_w PATH="$C/pybin:$WPATH" -- --dsh-dir "$DSH" --out "$OUT" "$PROMPT"
case_begin "H1: a python3 first on the caller's PATH is never the wrapper's interpreter"
h_marker_absent "$C/fake-python-ran" "the PATH's fake python3 ran the wrapper"
h_pass
if [ -n "$SEL" ]; then
  rm -f "$C/fake-python-ran"
  /usr/bin/env -i HOME="$FAKEHOME" PATH="$C/pybin:$WPATH" /usr/bin/env python3 -c 1 >/dev/null 2>&1
  h_path_present "$C/fake-python-ran" "control: the fake python3 did not run when PATH is followed"
fi
case_end

new_case "H1 python3 in the cwd"
make_dsh "$DSH" ok
fake_tool "$C/pycwd" python3 "$C/fake-python-ran"
run_w CWD="$C/pycwd" PATH=".:$WPATH" -- --dsh-dir "$DSH" --out "$OUT" "$PROMPT"
case_begin "H1: PATH starting with '.' and a python3 in the cwd: the cwd's python3 never runs"
h_marker_absent "$C/fake-python-ran" "the cwd's fake python3 ran the wrapper"
h_pass
case_end

new_case "H1 PYTHONPATH"
make_dsh "$DSH" ok
mkdir -p "$C/pypath"
printf 'open(%s, "w").write("fake json imported\\n")\nraise SystemExit(3)\n' "'$C/fake-json-ran'" > "$C/pypath/json.py"
run_w ENV:PYTHONPATH="$C/pypath" -- --dsh-dir "$DSH" --out "$OUT" "$PROMPT"
case_begin "H1: the caller's PYTHONPATH never loads a module into the wrapper"
h_path_absent "$C/fake-json-ran" "a json.py from the caller's PYTHONPATH was imported"
h_pass
if [ -n "$SEL" ]; then
  /usr/bin/env -i HOME="$FAKEHOME" PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$C/pypath" /usr/bin/python3 -c 'import json' >/dev/null 2>&1
  h_path_present "$C/fake-json-ran" "control: the fake json.py was not imported by plain python3"
fi
case_end

# --- H1b, H2, H2b: /usr/bin/python3, git and otool are xcrun shims that follow DEVELOPER_DIR ----
# With DEVELOPER_DIR=<dir> holding usr/bin/xcrun, each shim runs that program. The fake records
# which tool it was asked for (env NAMES only), then runs the real tool with the env unchanged,
# so the run itself still passes and each marker says exactly which shim followed the caller.
XC_PY="$(/usr/bin/xcrun -f python3 2>/dev/null)"
XC_GIT="$(/usr/bin/xcrun -f git 2>/dev/null)"
XC_OTOOL="$(/usr/bin/xcrun -f otool 2>/dev/null)"
# make_xdev -- XDEV=$C/xdev, a developer dir whose usr/bin/xcrun is the recording fake.
make_xdev() {
  XDEV="$C/xdev"
  mkdir -p "$XDEV/usr/bin"
  printf '#!/bin/sh\ntool="$1"\n/usr/bin/env | /usr/bin/cut -d= -f1 > "%s/xcrun-$tool-ran"\nshift\ncase "$tool" in\n  python3) exec "%s" "$@" ;;\n  git) exec "%s" "$@" ;;\n  otool) exec "%s" "$@" ;;\nesac\nexit 9\n' \
    "$C" "$XC_PY" "$XC_GIT" "$XC_OTOOL" > "$XDEV/usr/bin/xcrun"
  chmod 755 "$XDEV/usr/bin/xcrun"
}
new_case "H2 DEVELOPER_DIR"
make_repo "$REPO"
make_dsh "$DSH" ok read="$REPO/sentinel.txt"
make_xdev
run_w ENV:DEVELOPER_DIR="$XDEV" -- --dsh-dir "$DSH" --out "$OUT" --repo "$REPO" "$PROMPT"
case_begin "H2: the repo check's git ignores the caller's DEVELOPER_DIR (minimal env, no key)"
h_marker_absent "$C/xcrun-git-ran" "/usr/bin/git followed the caller's DEVELOPER_DIR into a fake xcrun"
h_pass
case_end
case_begin "H2b: otool (node's dylib scan) ignores the caller's DEVELOPER_DIR (beyond the planned H2 fix)"
h_marker_absent "$C/xcrun-otool-ran" "/usr/bin/otool followed the caller's DEVELOPER_DIR into a fake xcrun"
case_end
case_begin "H1b: the interpreter ignores the caller's DEVELOPER_DIR (beyond '#!/usr/bin/python3 -I')"
h_marker_absent "$C/xcrun-python3-ran" "/usr/bin/python3 followed the caller's DEVELOPER_DIR into a fake xcrun"
case_end
case_begin "H2 fixture: /usr/bin/git under DEVELOPER_DIR=<fake dev dir> runs the fake xcrun"
if [ -x "$XC_PY" ] && [ -x "$XC_GIT" ] && [ -x "$XC_OTOOL" ]; then c_ok; else c_bad "xcrun -f gave no real python3/git/otool ('$XC_PY' '$XC_GIT' '$XC_OTOOL')"; fi
if [ -n "$SEL" ]; then
  rm -f "$C/xcrun-git-ran"
  /usr/bin/env -i HOME="$FAKEHOME" DEVELOPER_DIR="$XDEV" PATH=/usr/bin:/bin /usr/bin/git --version >/dev/null 2>&1
fi
h_path_present "$C/xcrun-git-ran" "control: the fake xcrun did not run"
case_end

# The shebang's `env -u DEVELOPER_DIR` strips the variable before Python starts, so the case above
# cannot see git_env(). Here the real interpreter runs the wrapper directly (past the shebang),
# DEVELOPER_DIR reaches os.environ, and git_env() is the only layer between it and /usr/bin/git.
new_case "H2 git_env past the shebang"
make_repo "$REPO"
make_dsh "$DSH" ok read="$REPO/sentinel.txt"
make_xdev
W_BIN_SAVED="$BIN"
BIN="$XC_PY"
run_w ENV:DEVELOPER_DIR="$XDEV" -- -I "$W_BIN_SAVED" --dsh-dir "$DSH" --out "$OUT" --repo "$REPO" "$PROMPT"
BIN="$W_BIN_SAVED"
case_begin "H2: git_env() keeps the caller's DEVELOPER_DIR and key from git (wrapper run past its shebang)"
h_marker_absent "$C/xcrun-git-ran" "git_env() passed the caller's DEVELOPER_DIR to /usr/bin/git"
h_pass
if [ -n "$SEL" ]; then
  rm -f "$C/xcrun-git-ran"
  /usr/bin/env -i HOME="$FAKEHOME" DEVELOPER_DIR="$XDEV" PATH=/usr/bin:/bin /usr/bin/git --version >/dev/null 2>&1
  h_path_present "$C/xcrun-git-ran" "control: the fake xcrun did not run"
fi
case_end

# --- H2: the repo check never runs a git from the caller's PATH ---------------------------------
new_case "H2 git in <repo>/bin"
make_repo "$REPO"
make_dsh "$DSH" ok read="$REPO/sentinel.txt"
fake_tool "$REPO/bin" git "$C/fake-git-ran"
run_w PATH="$REPO/bin:$WPATH" -- --dsh-dir "$DSH" --out "$OUT" --repo "$REPO" "$PROMPT"
case_begin "H2: a git in <repo>/bin first on PATH never runs (the repo check uses /usr/bin/git)"
h_marker_absent "$C/fake-git-ran" "the repo's fake git ran"
h_pass
case_end
new_case "H2 git on PATH"
make_repo "$REPO"
make_dsh "$DSH" ok read="$REPO/sentinel.txt"
fake_tool "$C/gitbin" git "$C/fake-git-ran"
run_w PATH="$C/gitbin:$WPATH" -- --dsh-dir "$DSH" --out "$OUT" --repo "$REPO" "$PROMPT"
case_begin "H2: a git in an absolute dir outside the repo, first on PATH, never runs"
h_marker_absent "$C/fake-git-ran" "the PATH's fake git ran"
h_pass
case_end

# --- H3: a node under a home never widens the fence to the home ----------------------------------
new_case "H3 node under a home (fence_profile)"
H3H="$C/h3"
mkdir -p "$H3H/bin" "$H3H/lib" "$H3H/.local/bin" "$H3H/.local/lib"
case_begin "H3: node at <home>/bin or <home>/.local/bin never gets the home or ~/.local whole (fence_profile, HOME and pw_dir)"
if [ -n "$SEL" ]; then
  if o="$(/usr/bin/env -i HOME="$H3H" PATH=/usr/bin:/bin "$PY" -I -B -c '
import importlib.machinery, importlib.util, sys
ld = importlib.machinery.SourceFileLoader("dsr_wrapper", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("dsr_wrapper", ld))
ld.exec_module(m)
h, pw = sys.argv[2], sys.argv[3]
allow = lambda d: "(allow file-read* (subpath \"%s\"))" % d
p = []
for node, never, need in [
        (h + "/bin/node", [h], [h + "/bin", h + "/lib"]),
        (h + "/.local/bin/node", [h, h + "/.local"], [h + "/.local/bin"]),
        (pw + "/bin/node", [pw], []),
        (pw + "/.local/bin/node", [pw, pw + "/.local"], [])]:
    t = m.fence_profile("/x/out", None, "/x/dsh", node, 1)
    p += ["%s: the fence allows %s" % (node, d) for d in never if "(subpath \"%s\")" % d in t]
    p += ["%s: the fence lacks %s" % (node, d) for d in need if allow(d) not in t]
print("\n".join(p))
sys.exit(1 if p else 0)' "$BIN" "$H3H" "$PW_HOME" 2>&1)"; then c_ok; else c_bad "${o:-the check printed nothing}"; fi
fi
case_end

# The dylib dirs otool lists and Homebrew's OpenSSL etc/cert dirs pass the same unsafe-dir rule,
# with no direct-child exemption. otool is faked inside the wrapper module (no real binary lists
# such libs), and asked with the minimal env.
new_case "H3 dylib dirs (node_read_dirs, otool faked)"
H3O="$C/h3o"
mkdir -p "$H3O/home/.config/brew/etc/openssl@3" "$H3O/brew/etc/openssl@3"
printf 'cert\n' > "$H3O/home/cert.pem"
ln -s "$H3O/home/cert.pem" "$H3O/brew/etc/openssl@3/cert.pem"
case_begin "H3: otool-listed dylib dirs, the OpenSSL etc dir and its cert.pem dir under a home are never allowed (node_read_dirs)"
if [ -n "$SEL" ]; then
  if o="$(/usr/bin/env -i HOME="$H3O/home" PATH=/usr/bin:/bin "$PY" -I -B -c '
import importlib.machinery, importlib.util, sys, types
ld = importlib.machinery.SourceFileLoader("dsr_wrapper", sys.argv[1])
m = importlib.util.module_from_spec(importlib.util.spec_from_loader("dsr_wrapper", ld))
ld.exec_module(m)
b, h = sys.argv[2], sys.argv[2] + "/home"
libs = [b + "/libs/libsafe.dylib", h + "/libhome.dylib", h + "/.local/libx.dylib", h + "/.ssh/libz.dylib",
        b + "/brew/Cellar/openssl@3/3.1/lib/libssl.3.dylib",
        h + "/.config/brew/Cellar/openssl@3/3.1/lib/libcrypto.3.dylib"]
calls = []
def fake_run(argv, **kw):
    calls.append((list(argv), kw.get("env")))
    text = argv[-1] + ":\n" + "".join("\t%s (compatibility version 1.0.0, current version 1.0.0)\n" % x for x in libs)
    return types.SimpleNamespace(stdout=text, stderr="", returncode=0)
m.subprocess.run = fake_run
d = m.node_read_dirs(b + "/nb/bin/node")
p = []
if not calls or calls[0][0][:2] != ["/usr/bin/otool", "-L"]:
    p.append("otool was never asked (scenario not reproduced)")
elif calls[0][1] != {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin"}:
    p.append("otool env is not the minimal PATH-only env (names: %s)" % sorted((calls[0][1] or {}).keys()))
for want in (b + "/libs", b + "/brew/Cellar/openssl@3/3.1/lib", b + "/brew/etc/openssl@3"):
    if want not in d:
        p.append("lacks " + want)
for never in (h, h + "/.local", h + "/.ssh", h + "/.config/brew/Cellar/openssl@3/3.1/lib",
              h + "/.config/brew/etc/openssl@3"):
    if never in d:
        p.append("allows " + never)
print("\n".join(p))
sys.exit(1 if p else 0)' "$BIN" "$H3O" 2>&1)"; then c_ok; else c_bad "${o:-the check printed nothing}"; fi
fi
case_end

new_case "H3 node copied to <home>/bin"
H3E="$C/h3e"
copy_node_tree "$H3E"
mkdir -p "$H3E/.ssh"
printf 'H3-SSH-SENTINEL\n' > "$H3E/.ssh/id_test"
printf 'H3-HOME-NOTE\n' > "$H3E/note.txt"
make_dsh "$DSH" ok probe_read="$H3E/.ssh/id_test" probe_read="$H3E/note.txt" probe_read="$H3E/bin/node"
run_w HOME="$H3E" -- --dsh-dir "$DSH" --out "$OUT" --node "$H3E/bin/node" "$PROMPT"
case_begin "H3: node at <home>/bin/node (a copy, libnode in <home>/lib) runs; the fence still denies the home"
h_pass
h_rec_eq "execPath" execPath "\"$H3E/bin/node\""
h_probe read "$H3E/.ssh/id_test" EPERM
h_probe read "$H3E/note.txt" EPERM
h_probe read "$H3E/bin/node" OK
if [ ! -f "$OUT/fence-1.sb" ]; then c_bad "no fence-1.sb"
elif grep -qF "(subpath \"$H3E\")" "$OUT/fence-1.sb"; then c_bad "fence-1.sb allows the home $H3E"
else c_ok; fi
case_end

# A node directly in a home: its bin dir is the home and its prefix is above it, so the fence
# could only run it by allowing the home whole. Refused before anything runs.
new_case "H3 NODE_DIR_UNSAFE (node directly in HOME)"
make_dsh "$DSH" ok
mkdir -p "$C/nh"
printf '#!/bin/sh\nexit 0\n' > "$C/nh/node"
chmod 755 "$C/nh/node"
run_w HOME="$C/nh" -- --dsh-dir "$DSH" --out "$OUT" --node "$C/nh/node" "$PROMPT"
setup_end NODE_DIR_UNSAFE

# --- H4: HOME is not the only home: the account's pw_dir is protected too ------------------------
PWS="$PW_HOME/.ssh"
[ -d "$PWS" ] || PWS="$PW_HOME/Library"
new_case "H4 REPO_SECRET_OVERLAP (pw_dir's secret dir, HOME elsewhere)"
make_dsh "$DSH" ok
M0="$(stat -f %m "$PWS" 2>/dev/null)"
run_w -- --dsh-dir "$DSH" --out "$OUT" --repo "$PWS" "$PROMPT"
case_begin "H4: with HOME=<fake>, --repo <pw_dir>/$(basename "$PWS") is REPO_SECRET_OVERLAP"
h_setup REPO_SECRET_OVERLAP
h_no_stub "$OUT" "$C"
h_path_absent "$OUT" "out dir created"
if [ "$M0" = "$(stat -f %m "$PWS" 2>/dev/null)" ]; then c_ok; else c_bad "$PWS changed during the run"; fi
case_end
new_case "H4 REPO_HOME_OR_ABOVE (pw_dir, HOME elsewhere)"
make_dsh "$DSH" ok
run_w -- --dsh-dir "$DSH" --out "$OUT" --repo "$PW_HOME" "$PROMPT"
case_begin "H4: with HOME=<fake>, --repo <pw_dir> is REPO_HOME_OR_ABOVE"
h_setup REPO_HOME_OR_ABOVE
h_no_stub "$OUT" "$C"
h_path_absent "$OUT" "out dir created"
if ls -A "$PW_HOME" 2>/dev/null | grep -qE '^(deepseek-review|stub-)'; then c_bad "a deepseek-review or stub file appeared in $PW_HOME"; else c_ok; fi
case_end

# --- H5: the dsh dir is never a home-wide grant, and bin.js stays inside it ----------------------
for h5 in home child secret; do
  new_case "H5 DSH_DIR_UNSAFE (the dsh dir is the $h5 dir of HOME)"
  H5H="$C/h5"
  mkdir -p "$H5H"
  case "$h5" in home) H5D="$H5H" ;; child) H5D="$H5H/.local" ;; secret) H5D="$H5H/.config/dsh" ;; esac
  make_dsh "$H5D" ok
  run_w HOME="$H5H" -- --dsh-dir "$H5D" --out "$OUT" "$PROMPT"
  setup_end DSH_DIR_UNSAFE
done
new_case "H5 DSH_DIR_UNSAFE (bin.js is a symlink to a file in the repo)"
make_repo "$REPO"
mkdir -p "$REPO/tools"
cp "$FIX/stub-dsh.mjs" "$REPO/tools/bin.js"
printf '{"type":"module"}\n' > "$REPO/tools/package.json"
make_dsh "$DSH" ok read="$REPO/sentinel.txt"
rm -f "$DSH/node_modules/@deepseek-ai/dsh/lib/bin.js"
ln -s "$REPO/tools/bin.js" "$DSH/node_modules/@deepseek-ai/dsh/lib/bin.js"
run_w -- --dsh-dir "$DSH" --out "$OUT" --repo "$REPO" "$PROMPT"
setup_end DSH_DIR_UNSAFE
# The symlink walk below it would refuse this too: pin the bin.js check's own message.
case_begin "H5: a bin.js symlinked to a file in the repo is refused by the bin.js check itself"
h_stderr_has "dsh's bin.js resolves outside"
case_end
new_case "H5 DSH_DIR_UNSAFE (the dsh package dir is a symlink into the repo)"
make_repo "$REPO"
make_dsh "$DSH" ok read="$REPO/sentinel.txt"
if [ -n "$SEL" ]; then
  mv "$DSH/node_modules/@deepseek-ai/dsh" "$REPO/vendor-dsh"
  ln -s "$REPO/vendor-dsh" "$DSH/node_modules/@deepseek-ai/dsh"
fi
run_w -- --dsh-dir "$DSH" --out "$OUT" --repo "$REPO" "$PROMPT"
setup_end DSH_DIR_UNSAFE
case_begin "H5: a dsh package dir symlinked into the repo is refused by the bin.js check itself"
h_stderr_has "dsh's bin.js resolves outside"
case_end
# HOME's ~/.aws is a symlink into a store dir; a dsh dir that CONTAINS the store would let the
# fence read the real secret dir (only the realpath'd secret dir, overlap in both directions, sees it).
new_case "H5 DSH_DIR_UNSAFE (the dsh dir contains the realpath of HOME's ~/.aws)"
H5A="$C/h5a"
mkdir -p "$H5A/home" "$H5A/store/dotaws"
ln -s "$H5A/store/dotaws" "$H5A/home/.aws"
make_dsh "$H5A/store" ok
run_w HOME="$H5A/home" -- --dsh-dir "$H5A/store" --out "$OUT" "$PROMPT"
setup_end DSH_DIR_UNSAFE

# --- H6: every .env-like name in the repo is denied, at any depth --------------------------------
new_case "H6 env names"
make_repo "$REPO"
mkdir -p "$REPO/sub"
H6_DENY=(.envrc .env-prod .env_local .environment sub/.envrc prod.env sub/x.env)
H6_OK=(environment.md envoy.yaml src/env.ts x.env.example)
H6_PROBES=()
for f in "${H6_DENY[@]}" "${H6_OK[@]}"; do
  printf 'H6-SENTINEL %s\n' "$f" > "$REPO/$f"
  H6_PROBES+=("probe_read=$REPO/$f")
done
make_dsh "$DSH" ok read="$REPO/sentinel.txt" "${H6_PROBES[@]}"
wr --repo "$REPO" "$PROMPT"
case_begin "H6: .env-like names at any depth (.envrc .env-prod .env_local .environment sub/.envrc prod.env sub/x.env) are denied"
h_pass
for f in "${H6_DENY[@]}"; do h_probe read "$REPO/$f" EPERM; done
case_end
case_begin "H6 guard: names that only hold 'env' (environment.md envoy.yaml src/env.ts x.env.example) stay readable"
if [ -n "$REC" ]; then c_ok; else c_bad "no stub record"; fi
for f in "${H6_OK[@]}"; do h_probe read "$REPO/$f" OK; done
case_end
case_begin "H6: fence-1.sb's .env deny covers the new names, after the repo allow (fence-check)"
if [ -f "$OUT/fence-1.sb" ]; then
  c_tl "fence" fence-check "$OUT/fence-1.sb" "$REPO" "$OUT" "$DSH" "$NODE_REAL" "$FAKEHOME"
else
  c_bad "no fence-1.sb"
fi
case_end

# --- H7: --continue re-checks the recorded repo and the dsh dir against the out dir --------------
new_case "H7 continue: repo swapped for a symlink to ~/.ssh"
make_repo "$REPO"
make_dsh "$DSH" ok sid=session-h7 read="$REPO/sentinel.txt"
wr --repo "$REPO" "$PROMPT"
A1_RC=$RC
if [ -n "$SEL" ]; then mv "$REPO" "$REPO.orig" && ln -s "$FAKEHOME/.ssh" "$REPO"; fi
rm -f "$OUT"/home/stub-*.json
run_w -- --continue "$OUT" --dsh-dir "$DSH" "$PROMPT"
case_begin "H7: --continue after the recorded repo became a symlink to ~/.ssh is refused before anything runs"
if [ "$A1_RC" = 0 ]; then c_ok; else c_bad "attempt 1 exit $A1_RC"; fi
h_rc 2
h_stdout_empty
h_no_traceback
if printf '%s' "$STDERR" | grep -qE '^deepseek-review: ERROR (REPO_SECRET_OVERLAP|CONTINUE_REPO_MISMATCH):'; then c_ok; else c_bad "no ERROR REPO_SECRET_OVERLAP / CONTINUE_REPO_MISMATCH — got: $(first_line "$STDERR")"; fi
h_no_stub "$OUT"
if [ -z "$(ls "$OUT"/*-2.* 2>/dev/null)" ]; then c_ok; else c_bad "attempt 2 files exist: $(ls "$OUT"/*-2.* | tr '\n' ' ')"; fi
case_end
if [ -n "$SEL" ] && [ -L "$REPO" ]; then rm -f "$REPO" && mv "$REPO.orig" "$REPO"; fi

new_case "H7 continue: repo swapped for a symlink to another repo"
make_repo "$REPO"
make_repo "$C/other-repo"
make_dsh "$DSH" ok sid=session-h7b read="$REPO/sentinel.txt"
wr --repo "$REPO" "$PROMPT"
A1_RC=$RC
if [ -n "$SEL" ]; then mv "$REPO" "$REPO.orig" && ln -s "$C/other-repo" "$REPO"; fi
rm -f "$OUT"/home/stub-*.json
run_w -- --continue "$OUT" --dsh-dir "$DSH" "$PROMPT"
case_begin "H7: --continue after the recorded repo's realpath moved is CONTINUE_REPO_MISMATCH"
if [ "$A1_RC" = 0 ]; then c_ok; else c_bad "attempt 1 exit $A1_RC"; fi
h_setup CONTINUE_REPO_MISMATCH
h_no_stub "$OUT"
if [ -z "$(ls "$OUT"/*-2.* 2>/dev/null)" ]; then c_ok; else c_bad "attempt 2 files exist"; fi
case_end
if [ -n "$SEL" ] && [ -L "$REPO" ]; then rm -f "$REPO" && mv "$REPO.orig" "$REPO"; fi

new_case "H7 continue: dsh dir inside the out dir"
make_repo "$REPO"
make_dsh "$DSH" ok sid=session-h7c read="$REPO/sentinel.txt"
wr --repo "$REPO" "$PROMPT"
A1_RC=$RC
make_dsh "$OUT/xdsh" ok read="$REPO/sentinel.txt"
rm -f "$OUT"/home/stub-*.json
run_w -- --continue "$OUT" --dsh-dir "$OUT/xdsh" "$PROMPT"
case_begin "H7: --continue --dsh-dir <inside the out dir> is OUT_OVERLAP"
if [ "$A1_RC" = 0 ]; then c_ok; else c_bad "attempt 1 exit $A1_RC"; fi
h_setup OUT_OVERLAP
h_no_stub "$OUT"
case_end

# --- H8: the version check: no key, bounded by --timeout, cancellable, group killed --------------
new_case "H8 version check hangs (--timeout 3s)"
H8M="$RUNID-vgc-$CASE_N"
make_dsh "$DSH" version_hang vmarker="$H8M"
t0="$(now)"
run_w ALARM=25 -- --dsh-dir "$DSH" --out "$OUT" --timeout 3s "$PROMPT"
t1="$(now)"
case_begin "H8: a hanging --version is bounded by --timeout 3s: DSH_VERSION_MISMATCH naming the timeout, group killed"
h_setup DSH_VERSION_MISMATCH
if printf '%s' "$STDERR" | grep '^deepseek-review: ERROR DSH_VERSION_MISMATCH:' | grep -qi 'tim'; then c_ok; else c_bad "the DSH_VERSION_MISMATCH line does not name the timeout"; fi
if "$PY" -c "import sys; d=$t1-$t0; sys.exit(0 if d <= 15 else 1)"; then c_ok; else c_bad "wall $(echo "$t1 - $t0" | bc)s (exit $RC), expected <= 15 s"; fi
VR="$(tl find-records version "$OUT" | head -1)"
if [ -n "$VR" ] && [ "$(tl rec "$VR" grandchild_pid 2>/dev/null)" != null ]; then c_ok; else c_bad "the --version grandchild never started (scenario not reproduced)"; fi
if [ -z "$(tl find-records record "$OUT")" ]; then c_ok; else c_bad "the review ran after a hung --version"; fi
h_path_absent "$OUT/prompt-1.txt" "a prompt was written"
h_gone "$H8M" 10
case_end
pkill -9 -f "$H8M" 2>/dev/null
for sig in TERM INT HUP; do
  new_case "H8 version check cancelled by SIG$sig"
  H8M="$RUNID-vgc-$CASE_N"
  make_dsh "$DSH" version_hang vmarker="$H8M"
  run_w_bg ALARM=40 -- --dsh-dir "$DSH" --out "$OUT" --timeout 120 "$PROMPT"
  STARTED=""
  wait_version 20 && STARTED=1
  if [ -n "$STARTED" ]; then psleep 0.3; kill -"$sig" "$BGPID" 2>/dev/null; fi
  bg_wait 25
  case_begin "H8: SIG$sig during the --version check: ERROR CANCELLED (exit 2), group killed, nothing sent"
  [ -n "$STARTED" ] || c_bad "the --version stub never started, so no SIG$sig was sent"
  [ -z "$BG_HUNG" ] || c_bad "wrapper still running 25 s after SIG$sig"
  h_setup CANCELLED
  if [ -z "$(tl find-records record "$OUT")" ]; then c_ok; else c_bad "the review ran"; fi
  h_path_absent "$OUT/prompt-1.txt" "a prompt was written"
  h_gone "$H8M" 10
  case_end
  pkill -9 -f "$H8M" 2>/dev/null
done
# A --version that answers but leaves a grandchild in its group: the check's group is killed
# even when the check itself finished.
new_case "H8 version check leaves a grandchild"
H8M="$RUNID-vgc-$CASE_N"
make_dsh "$DSH" ok vmarker="$H8M"
wr "$PROMPT"
case_begin "H8: a grandchild the --version check leaves behind is killed with its group (the review still runs)"
h_pass
VR="$(tl find-records version "$OUT" | head -1)"
if [ -n "$VR" ] && [ "$(tl rec "$VR" grandchild_pid 2>/dev/null)" != null ]; then c_ok; else c_bad "the --version grandchild never started (scenario not reproduced)"; fi
h_gone "$H8M" 5
case_end
pkill -9 -f "$H8M" 2>/dev/null
# The doctor's --version check is trapped the same way. Its out dir is a temp dir the case cannot
# name, so the start is seen through the marker grandchild's process.
new_case "H8 doctor version check cancelled by SIGTERM"
H8M="$RUNID-vgc-$CASE_N"
make_dsh "$DSH" version_hang vmarker="$H8M"
run_w_bg ALARM=40 -- --doctor --dsh-dir "$DSH" --node "$NODEBIN/node"
STARTED=""
if [ -n "$SEL" ]; then
  for _ in $(seq 200); do
    if pgrep -f "$H8M" >/dev/null 2>&1; then STARTED=1; break; fi
    kill -0 "$BGPID" 2>/dev/null || break
    psleep 0.1
  done
fi
if [ -n "$STARTED" ]; then psleep 0.3; kill -TERM "$BGPID" 2>/dev/null; fi
bg_wait 25
case_begin "H8: SIGTERM during the doctor's --version check: ERROR CANCELLED (exit 2), group killed"
[ -n "$STARTED" ] || c_bad "the doctor's --version stub never started, so no SIGTERM was sent"
[ -z "$BG_HUNG" ] || c_bad "doctor still running 25 s after SIGTERM"
h_rc 2
h_stderr_has "deepseek-review: ERROR CANCELLED:"
h_no_traceback
h_gone "$H8M" 10
case_end
pkill -9 -f "$H8M" 2>/dev/null

# --- H9: one final event; a tool_result counts only after its tool_call ---------------------------
new_case "H9 two finals"
make_dsh "$DSH" two_finals
wr "$PROMPT"
case_begin "H9: two final events are FINAL_NOT_UNIQUE (live run; --check agrees)"
h_fail_codes FINAL_NOT_UNIQUE exact
h_record
h_status 1
h_check_agrees
case_end
new_case "H9 result before call"
make_repo "$REPO"
repo_case "H9: a tool_result before its tool_call is not a read" result_before_call \
  "REPO_NOT_READ RESULT_WITHOUT_CALL" exact \
  read="$REPO/sentinel.txt" --
case_end
new_case "H9 fabricated"
make_repo "$REPO"
fab_out "$C/o-ok" ok "$REPO" read="$REPO/sentinel.txt" cwd="$REPO"
OUT="$C/o-ok"
run_w -- --check "$OUT"
case_begin "H9 control: a fabricated valid stream with one in-repo read passes --check"
h_rc 0
h_verdict_stdout
case_end
fab_out "$C/o-2f" two_finals "$REPO" read="$REPO/sentinel.txt" cwd="$REPO"
OUT="$C/o-2f"
run_w -- --check "$OUT"
case_begin "H9: --check on a fabricated stream with two final events is FINAL_NOT_UNIQUE"
h_fail_codes FINAL_NOT_UNIQUE exact
case_end
fab_out "$C/o-rbc" result_before_call "$REPO" read="$REPO/sentinel.txt" cwd="$REPO"
OUT="$C/o-rbc"
run_w -- --check "$OUT"
case_begin "H9: --check on a fabricated stream whose read result precedes its call is REPO_NOT_READ"
h_fail_codes "REPO_NOT_READ RESULT_WITHOUT_CALL" exact
case_end

# --- H10: --check needs the attempt's three files and keeps a FAIL status's reasons ---------------
new_case "H10 --check without err-1.txt"
make_dsh "$DSH" compose_activate
wr "$PROMPT"
L_RC=$RC
L_ERR="$STDERR"
if [ -n "$SEL" ]; then
  cp -Rp "$OUT" "$C/o-noerr" && rm -f "$C/o-noerr/err-1.txt"
  cp -Rp "$OUT" "$C/o-emptyerr" && : > "$C/o-emptyerr/err-1.txt"
fi
case_begin "H10 control: the live run failed COMPOSE_WARNING"
if [ "$L_RC" = 1 ] && printf '%s' "$L_ERR" | grep -q '^deepseek-review: FAIL COMPOSE_WARNING:'; then c_ok; else c_bad "live run exit $L_RC: $(first_line "$L_ERR")"; fi
case_end
OUT="$C/o-noerr"
run_w -- --check "$OUT"
case_begin "H10: --check with err-1.txt deleted is ATTEMPT_INCOMPLETE naming it, and keeps the recorded COMPOSE_WARNING"
h_fail_codes "ATTEMPT_INCOMPLETE COMPOSE_WARNING" contains
h_fail_line_has ATTEMPT_INCOMPLETE err-1.txt
case_end
OUT="$C/o-emptyerr"
run_w -- --check "$OUT"
case_begin "H10: --check with err-1.txt emptied still reports the recorded COMPOSE_WARNING"
h_fail_codes COMPOSE_WARNING exact
case_end
new_case "H10 --check without status or stream"
make_dsh "$DSH" ok
wr "$PROMPT"
L_RC=$RC
if [ -n "$SEL" ]; then
  cp -Rp "$OUT" "$C/o-nostatus" && rm -f "$C/o-nostatus/status-1.json"
  cp -Rp "$OUT" "$C/o-nostream" && rm -f "$C/o-nostream/run-1.jsonl"
fi
case_begin "H10 control: the live run passed"
if [ "$L_RC" = 0 ]; then c_ok; else c_bad "live run exit $L_RC"; fi
case_end
OUT="$C/o-nostatus"
run_w -- --check "$OUT"
case_begin "H10: --check with run-1.jsonl but no status-1.json (a SIGKILLed wrapper) is ATTEMPT_INCOMPLETE, exit 1"
h_fail_codes ATTEMPT_INCOMPLETE contains
h_fail_line_has ATTEMPT_INCOMPLETE status-1.json
case_end
OUT="$C/o-nostream"
run_w -- --check "$OUT"
case_begin "H10: --check with run-1.jsonl deleted is ATTEMPT_INCOMPLETE naming it"
h_fail_codes ATTEMPT_INCOMPLETE contains
h_fail_line_has ATTEMPT_INCOMPLETE run-1.jsonl
case_end
H10_N=0
new_case "H10 status not an object"
make_repo "$REPO"
fab_out "$C/o-base" ok "$REPO" read="$REPO/sentinel.txt" cwd="$REPO"
h10s() { # LABEL CONTENT -- status-1.json replaced by CONTENT
  H10_N=$((H10_N + 1))
  OUT="$C/o-h10s-$H10_N"
  if [ -n "$SEL" ]; then cp -Rp "$C/o-base" "$OUT" && printf '%s\n' "$2" > "$OUT/status-1.json"; fi
  run_w -- --check "$OUT"
  case_begin "H10: --check on a status-1.json that is $1 is STATUS_INVALID"
  h_fail_codes STATUS_INVALID exact
  case_end
}
h10s "a JSON list, not an object" '[1]'
h10s "not JSON" '{"verdict":'
new_case "H10 recorded reasons"
make_repo "$REPO"
fab_out "$C/o-base" ok "$REPO" read="$REPO/sentinel.txt" cwd="$REPO"
h10r() { # LABEL "CODES" key=json... -- --check on the fabricated PASS out with status-1 edited
  local label="$1" want="$2"
  shift 2
  H10_N=$((H10_N + 1))
  OUT="$C/o-h10r-$H10_N"
  if [ -n "$SEL" ]; then cp -Rp "$C/o-base" "$OUT" && tl status-set "$OUT/status-1.json" "$@"; fi
  run_w -- --check "$OUT"
  case_begin "H10: --check on a status recording $label is FAIL $want"
  h_fail_codes "$want" exact
  case_end
}
h10r "verdict FAIL with no reasons" RECORDED_FAIL verdict='"FAIL"' reasons='[]'
h10r "verdict FAIL with reasons that are no codes (lower case, a number, a space)" RECORDED_FAIL \
  verdict='"FAIL"' reasons='["lower", 5, "A B"]'
h10r "verdict FAIL with reasons as a string, not a list" RECORDED_FAIL verdict='"FAIL"' reasons='"VERDICT_MISSING"'
h10r "verdict FAIL with two recorded codes" "TURN_NOT_COMPLETED VERDICT_MISSING" \
  verdict='"FAIL"' reasons='["VERDICT_MISSING", "TURN_NOT_COMPLETED"]'
h10r "cancelled (verdict PASS, reasons empty)" CANCELLED cancelled=true cancel_reason='"SIGTERM"'
OUT="$C/o-h10r-dup"
if [ -n "$SEL" ]; then
  cp -Rp "$C/o-base" "$OUT" && tl status-set "$OUT/status-1.json" verdict='"FAIL"' \
    reasons='["VERDICT_MISSING", "VERDICT_MISSING"]'
fi
run_w -- --check "$OUT"
case_begin "H10: --check prints a code recorded twice once"
h_fail_codes VERDICT_MISSING exact
h_fail_once VERDICT_MISSING
case_end
fab_out "$C/o-h10r-2f" two_finals "$REPO" read="$REPO/sentinel.txt" cwd="$REPO"
OUT="$C/o-h10r-2f"
[ -z "$SEL" ] || tl status-set "$OUT/status-1.json" verdict='"FAIL"' reasons='["FINAL_NOT_UNIQUE"]'
run_w -- --check "$OUT"
case_begin "H10: --check prints a recorded code that the stream also fails once"
h_fail_codes FINAL_NOT_UNIQUE exact
h_fail_once FINAL_NOT_UNIQUE
case_end

# --- H11: a status whose repo fields have the wrong shape is STATUS_INVALID -----------------------
new_case "H11 status sanity"
make_repo "$REPO"
fab_out "$C/o-base" ok "$REPO" read="$REPO/sentinel.txt" cwd="$REPO"
OUT="$C/o-base"
run_w -- --check "$OUT"
case_begin "H11 control: the unmodified fabricated out passes --check"
h_rc 0
h_verdict_stdout
case_end
H11_N=0
h11() { # LABEL key=json...
  local label="$1"
  shift
  H11_N=$((H11_N + 1))
  OUT="$C/o-h11-$H11_N"
  if [ -n "$SEL" ]; then cp -Rp "$C/o-base" "$OUT" && tl status-set "$OUT/status-1.json" "$@"; fi
  run_w -- --check "$OUT"
  case_begin "H11: --check on a status with $label is STATUS_INVALID"
  h_fail_codes STATUS_INVALID exact
  case_end
}
h11 "repo_mode true and repo null" repo=null
h11 "repo_mode \"true\" (a string)" repo_mode='"true"'
h11 "repo_mode 1 (a number)" repo_mode=1
h11 "repo_mode null" repo_mode=null
h11 "repo_mode true and repo \"\"" repo='""'
h11 "repo_mode true and a relative repo" repo='"relative/repo"'
h11 "repo_mode true and repo 5" repo=5
h11 "expect_read \"x\" (a string)" expect_read='"x"'
h11 "expect_read [1]" expect_read='[1]'
BSL="$(printf '\134')"   # a backslash: the JSON escape for NUL is built here, never typed
h11 "repo_mode true and a repo holding NUL" repo="\"/x${BSL}u0000y\""
h11 "expect_read holding a path with NUL" expect_read="[\"/x${BSL}u0000y\"]"
new_case "H11 continue on a malformed status-1"
make_repo "$REPO"
make_dsh "$DSH" ok read="$REPO/sentinel.txt"
fab_out "$C/o-cont" ok "$REPO" read="$REPO/sentinel.txt" cwd="$REPO"
OUT="$C/o-cont"
tl status-set "$OUT/status-1.json" repo_mode=null
run_w -- --continue "$OUT" --dsh-dir "$DSH" "$PROMPT"
case_begin "H11: --continue on a status-1.json with repo_mode null is STATUS_INVALID, before anything runs"
h_setup STATUS_INVALID
h_no_stub "$OUT"
h_path_absent "$OUT/prompt-2.txt" "a 2nd attempt was started"
case_end

# --- H12: in-repo reads of earlier PASSed attempts count for a follow-up -------------------------
h12_two() { # ATTEMPT1-KIND [--continue args...] -- attempt 1 reads src/a.txt; attempt 2 reads nothing
  local k1="$1"
  shift
  make_repo "$REPO"
  make_dsh "$DSH" "$k1" sid=session-h12 read="$REPO/src/a.txt"
  wr --repo "$REPO" "$PROMPT"
  A1_RC=$RC
  rm -f "$OUT"/home/stub-record-*.json
  set_scenario ok sid=session-h12
  run_w -- --continue "$OUT" --dsh-dir "$DSH" "$@" "$PROMPT"
}
new_case "H12 earlier PASS read counts"
h12_two ok
case_begin "H12: attempt 2 that reads nothing passes on attempt 1's (PASS) read of src/a.txt; --check agrees"
if [ "$A1_RC" = 0 ]; then c_ok; else c_bad "attempt 1 exit $A1_RC"; fi
h_pass
h_status 2
h_check_agrees
case_end
if [ -n "$SEL" ]; then
  cp -Rp "$OUT" "$C/o-tamper" && tl status-set "$C/o-tamper/status-1.json" verdict='"FAIL"' reasons='["VERDICT_MISSING"]'
fi
OUT="$C/o-tamper"
run_w -- --check "$OUT" --attempt 2
case_begin "H12 guard: --check --attempt 2 stops counting attempt 1's read once status-1 says FAIL"
h_fail_codes REPO_NOT_READ exact
case_end
if [ -n "$SEL" ]; then
  cp -Rp "$C/out" "$C/o-badst" && tl status-set "$C/o-badst/status-1.json" expect_read='"x"'
fi
OUT="$C/o-badst"
run_w -- --check "$OUT" --attempt 2
case_begin "H12 guard: --check --attempt 2 stops counting attempt 1's read once status-1 is malformed (expect_read a string)"
h_fail_codes REPO_NOT_READ exact
case_end
# Attempt 1 (read src/a.txt) and attempt 2 (read nothing) swapped: attempt 1 is now the one that
# read nothing, and a LATER attempt's read must not count for it.
if [ -n "$SEL" ]; then
  cp -Rp "$C/out" "$C/o-swap"
  for f in status-%s.json run-%s.jsonl err-%s.txt prompt-%s.txt fence-%s.sb run-%s.patch.yml; do
    f1="$(printf "$f" 1)"; f2="$(printf "$f" 2)"
    mv "$C/o-swap/$f1" "$C/o-swap/swap.tmp" && mv "$C/o-swap/$f2" "$C/o-swap/$f1" && mv "$C/o-swap/swap.tmp" "$C/o-swap/$f2"
  done
fi
OUT="$C/o-swap"
run_w -- --check "$OUT" --attempt 1
case_begin "H12 guard: --check --attempt 1 never counts a later attempt's read (attempts 1 and 2 swapped)"
h_fail_codes REPO_NOT_READ exact
case_end
new_case "H12 expect-read across attempts"
h12_two ok --expect-read "$REPO/src/a.txt"
case_begin "H12: --continue --expect-read <the file attempt 1 (PASS) read> passes"
if [ "$A1_RC" = 0 ]; then c_ok; else c_bad "attempt 1 exit $A1_RC"; fi
h_pass
c_tl "status-2" status-check "$OUT/status-2.json" expect_read="[\"$REPO/src/a.txt\"]"
h_status 2
h_check_agrees
case_end
new_case "H12 expect-read never read"
h12_two ok --expect-read "$REPO/sentinel.txt"
case_begin "H12: an --expect-read file no attempt read is EXPECTED_READ_MISSING alone (attempt 1's read still counts as a repo read)"
if [ "$A1_RC" = 0 ]; then c_ok; else c_bad "attempt 1 exit $A1_RC"; fi
h_fail_codes EXPECTED_READ_MISSING exact
h_check_agrees
case_end
new_case "H12 failed attempt reads do not count"
h12_two verdict_missing
case_begin "H12 guard: reads of a FAILed attempt 1 do not count: attempt 2 that reads nothing is REPO_NOT_READ"
if [ "$A1_RC" = 1 ]; then c_ok; else c_bad "attempt 1 exit $A1_RC, expected 1 (VERDICT_MISSING)"; fi
h_fail_codes REPO_NOT_READ exact
h_status 2
h_check_agrees
case_end

# --- Regressions: refuted claims, pinned as attack inputs ------------------------------------------
new_case "R env spellings"
make_repo "$REPO"
printf 'LOCAL-ENV-SENTINEL\n' > "$REPO/.env.local"
make_dsh "$DSH" ok read="$REPO/sentinel.txt" probe_read="$REPO/.ENV" probe_read="$REPO/.Env.local" \
  probe_read="$REPO/.env.LOCAL" probe_read="$REPO/.env"
wr --repo "$REPO" "$PROMPT"
case_begin "R: .ENV, .Env.local and .env.LOCAL (other spellings of .env and .env.local on APFS) are denied"
h_pass
for f in .ENV .Env.local .env.LOCAL .env; do h_probe read "$REPO/$f" EPERM; done
case_end

new_case "R repo with a backslash"
REPO="$FAKEHOME/src/back\\slash$CASE_N"
make_repo "$REPO"
make_dsh "$DSH" ok read="$REPO/sentinel.txt" probe_read="$REPO/.env" probe_read="$REPO/sentinel.txt"
wr --repo "$REPO" "$PROMPT"
case_begin "R: a repo path holding a backslash: .env is denied, sentinel.txt readable"
h_pass
h_probe read "$REPO/.env" EPERM
h_probe read "$REPO/sentinel.txt" OK
case_end

new_case "R out with a double quote"
OUT="$C/o\"ut"
make_dsh "$DSH" ok probe_read="$OUTSIDE/secret.txt" probe_read="$FAKEHOME/.ssh/id_test"
wr "$PROMPT"
case_begin "R: an out path holding a double quote: the fence parses and still denies outside files"
h_rc 0
h_verdict_stdout
h_record_glob
h_probe read "$OUTSIDE/secret.txt" EPERM
h_probe read "$FAKEHOME/.ssh/id_test" EPERM
case_end

new_case "R out with a newline"
OUT="$C/o"$'\n''(allow file-read*)'
make_dsh "$DSH" ok probe_read="$OUTSIDE/secret.txt" probe_read="$FAKEHOME/.ssh/id_test"
wr "$PROMPT"
case_begin "R: an out path holding a newline and '(allow file-read*)': the fence parses and still denies outside files"
h_rc 0
h_verdict_stdout
h_record_glob
h_probe read "$OUTSIDE/secret.txt" EPERM
h_probe read "$FAKEHOME/.ssh/id_test" EPERM
case_end

# --- Regressions: the medium fixes ------------------------------------------------------------------
new_case "R odd stream fields"
make_repo "$REPO"
for v in input_str cwd_int nul_path list_callid; do
  fab_out "$C/o-$v" "$v" "$REPO" target="$REPO/sentinel.txt"
  OUT="$C/o-$v"
  run_w -- --check "$OUT"
  # Round 3: a malformed session cwd is SESSION_INVALID, an invalid callId CALL_ID_INVALID.
  case "$v" in
    cwd_int) want="REPO_NOT_READ SESSION_INVALID" ;;
    list_callid) want="CALL_ID_INVALID REPO_NOT_READ" ;;
    *) want="REPO_NOT_READ" ;;
  esac
  case_begin "R: --check on a stream with $v is a FAIL verdict (exit 1, its own codes), never an internal error"
  h_fail_codes "$want" exact
  h_text_lacks "stderr" "internal error" "$STDERR"
  case_end
done

new_case "R OUT_PARENT_MISSING"
make_dsh "$DSH" ok
run_w -- --dsh-dir "$DSH" --out "$C/no-such-parent/out" "$PROMPT"
setup_end OUT_PARENT_MISSING

new_case "R continue setup"
make_dsh "$DSH" ok
printf '{"type":"session","sessionId":"session-fab-1","cwd":"/x"}\n{"type":"final","text":"x"}\n' > "$C/fab-s.jsonl"
: > "$C/fab.err"
OUT="$C/out-norun1"
tl fabricate "$OUT" "$C/fab-s.jsonl" "$C/fab.err" 0 0123456789abcdef -
cp "$PLUGIN/dsh/review.patch.yml" "$OUT/review.patch.yml"
rm -f "$OUT/run-1.jsonl"
run_w -- --continue "$OUT" --dsh-dir "$DSH" "$PROMPT"
case_begin "R: --continue with run-1.jsonl deleted is CONTINUE_NO_SESSION"
h_setup CONTINUE_NO_SESSION
h_no_stub "$OUT"
h_path_absent "$OUT/prompt-2.txt" "a 2nd attempt was started"
case_end
OUT="$C/out-patch-edited"
tl fabricate "$OUT" "$C/fab-s.jsonl" "$C/fab.err" 0 0123456789abcdef -
cp "$PLUGIN/dsh/review.patch.yml" "$OUT/review.patch.yml"
printf '# edited after attempt 1\n' >> "$OUT/review.patch.yml"
run_w -- --continue "$OUT" --dsh-dir "$DSH" "$PROMPT"
case_begin "R: --continue with <out>/review.patch.yml edited is CONTINUE_PATCH_CHANGED"
h_setup CONTINUE_PATCH_CHANGED
h_no_stub "$OUT"
h_path_absent "$OUT/prompt-2.txt" "a 2nd attempt was started"
case_end
OUT="$C/out-patch-hash"
tl fabricate "$OUT" "$C/fab-s.jsonl" "$C/fab.err" 0 0123456789abcdef -
cp "$PLUGIN/dsh/review.patch.yml" "$OUT/review.patch.yml"
tl status-set "$OUT/status-1.json" patch_sha256='{"review.patch.yml": "0000000000000000000000000000000000000000000000000000000000000000"}'
run_w -- --continue "$OUT" --dsh-dir "$DSH" "$PROMPT"
case_begin "R: --continue when status-1.json recorded another review.patch.yml hash is CONTINUE_PATCH_CHANGED"
h_setup CONTINUE_PATCH_CHANGED
h_no_stub "$OUT"
h_path_absent "$OUT/prompt-2.txt" "a 2nd attempt was started"
case_end

new_case "R doctor invalid key"
make_dsh "$DSH" ok
run_w KEY=$'FAKEbad\nkey' -- --doctor --dsh-dir "$DSH" --node "$NODEBIN/node"
case_begin "R: --doctor with a key holding a newline: 'key: invalid (length 11, bad positions [7])', exit 1, value absent"
h_rc 1
doctor_line "key: invalid (length 11, bad positions [7])"
h_text_lacks "doctor output" "FAKEbad" "$STDOUT$STDERR"
h_no_traceback
case_end

new_case "R key scrubbed from what the wrapper prints"
make_dsh "$DSH" leak_key denied="/x/{KEY}/f"
wr "$PROMPT"
case_begin "R: a key dsh echoes into an error event, a composition warning and a denied path is [REDACTED] on stderr"
h_fail_codes "COMPOSE_WARNING ERROR_EVENT" exact
h_stderr_has "[REDACTED]"
h_fail_line_has ERROR_EVENT "[REDACTED]"
h_fail_line_has COMPOSE_WARNING "[REDACTED]"
h_stderr_has "denied: read /x/[REDACTED]/f"
h_text_lacks "stderr" "$FAKEKEY" "$STDERR"
# The stub echoed the key into its error event (the scenario reproduced), and the wrapper replaced
# it in the files dsh wrote.
if [ -n "$SEL" ] && ! grep -qF "provider rejected key [REDACTED]" "$OUT/run-1.jsonl" 2>/dev/null; then
  c_bad "run-1.jsonl lacks 'provider rejected key [REDACTED]': the stub did not echo the key, or it was not replaced"
else
  c_ok
fi
for f in run-1.jsonl err-1.txt; do
  if [ -n "$SEL" ] && grep -qF "$FAKEKEY" "$OUT/$f" 2>/dev/null; then c_bad "$f still holds the key"; else c_ok; fi
done
case_end
new_case "R key scrubbed from the answer"
make_dsh "$DSH" leak_key_final
wr "$PROMPT"
case_begin "R: a key dsh echoes into the final answer is [REDACTED] on stdout"
h_rc 0
if printf '%s' "$STDOUT" | grep -qxF "Key seen: [REDACTED]"; then c_ok; else c_bad "stdout lacks 'Key seen: [REDACTED]' — got: $(first_line "$STDOUT")"; fi
h_verdict_stdout
h_text_lacks "stdout" "$FAKEKEY" "$STDOUT"
h_text_lacks "stderr" "$FAKEKEY" "$STDERR"
case_end
# A wrapper killed between dsh's exit and scrub_file leaves the key in the files dsh wrote; a
# later --check (the key in its env) must still print [REDACTED]: report() scrubs what it prints.
# The fixture puts the key back where the run's scrub replaced it.
new_case "R2 --check scrubs a key left in a run's files"
make_dsh "$DSH" leak_key denied="/x/{KEY}/f"
wr "$PROMPT"
if [ -n "$SEL" ]; then
  perl -pi -e 's/\[REDACTED\]/'"$FAKEKEY"'/g' "$OUT/run-1.jsonl" "$OUT/err-1.txt"
fi
run_w -- --check "$OUT"
case_begin "R2: --check with the key in its env prints [REDACTED] for a key left in run-1.jsonl and err-1.txt"
for f in run-1.jsonl err-1.txt; do
  if [ -n "$SEL" ] && ! grep -qF "$FAKEKEY" "$OUT/$f" 2>/dev/null; then c_bad "fixture: $f does not hold the key"; else c_ok; fi
done
h_fail_codes "COMPOSE_WARNING ERROR_EVENT" exact
h_fail_line_has ERROR_EVENT "[REDACTED]"
h_fail_line_has COMPOSE_WARNING "[REDACTED]"
h_stderr_has "denied: read /x/[REDACTED]/f"
h_text_lacks "stderr" "$FAKEKEY" "$STDERR"
h_text_lacks "stdout" "$FAKEKEY" "$STDOUT"
case_end
new_case "R2 --check scrubs a key left in a run's answer"
make_dsh "$DSH" leak_key_final
wr "$PROMPT"
if [ -n "$SEL" ]; then
  perl -pi -e 's/\[REDACTED\]/'"$FAKEKEY"'/g' "$OUT/run-1.jsonl"
fi
run_w -- --check "$OUT"
case_begin "R2: --check with the key in its env prints [REDACTED] for a key left in the answer in run-1.jsonl"
if [ -n "$SEL" ] && ! grep -qF "$FAKEKEY" "$OUT/run-1.jsonl" 2>/dev/null; then c_bad "fixture: run-1.jsonl does not hold the key"; else c_ok; fi
h_rc 0
if printf '%s' "$STDOUT" | grep -qxF "Key seen: [REDACTED]"; then c_ok; else c_bad "stdout lacks 'Key seen: [REDACTED]' — got: $(first_line "$STDOUT")"; fi
h_text_lacks "stdout" "$FAKEKEY" "$STDOUT"
h_text_lacks "stderr" "$FAKEKEY" "$STDERR"
case_end

# ==============================================================================================
echo "== CI: refusals match paths as APFS and Seatbelt do (case- and normalization-insensitive)"
# Python's realpath keeps the caller's spelling (<home>/.SSH stays upper case) while Seatbelt
# matches a subpath case-insensitively on this volume. A refusal that compares strings exactly
# lets a case variant of a home, a secret dir, the repo or the dsh dir through, and the fence
# then allows the real dir. Every variant changes case only at or below a per-case dir's own
# basename (never /private, /var or the temp prefix); each case first checks that the variant is
# the same file and SKIPS on a case-sensitive volume. The CI G cases pin the strict side: where
# being inside a dir ALLOWS something, a variant spelling stays outside.

# ci_pre VARIANT STORED -- 0 when VARIANT is another spelling of the same existing file.
# In a deselected block it returns 0: every helper is a no-op there and case_end prints the
# case's own verdict name as DESEL (the mutation harness lists cases from those lines).
ci_pre() {
  if [ -z "$SEL" ]; then return 0; fi
  if [ "$1" != "$2" ] && [ -e "$2" ] && [ "$1" -ef "$2" ]; then return 0; fi
  note_skip "$CNAME: $1 is not the same file as $2 (a case-sensitive volume): not reproducible here"
  return 1
}
# h_err_line_has CODE TEXT -- the ERROR line for CODE carries TEXT.
h_err_line_has() {
  if printf '%s' "$STDERR" | grep "^deepseek-review: ERROR $1:" | grep -qF -- "$2"; then
    c_ok
  else
    c_bad "the ERROR $1 line does not say '$2' — got: $(first_line "$STDERR")"
  fi
}
# h_err_names_symlink CODE COMP -- the ERROR line for CODE says "symlink" and names COMP itself,
# not only a longer path running through it (COMP followed by anything but '/').
h_err_names_symlink() {
  local line
  line="$(printf '%s\n' "$STDERR" | grep "^deepseek-review: ERROR $1:" | head -n 1)"
  if [ -z "$line" ]; then c_bad "no 'deepseek-review: ERROR $1:' line — got: $(first_line "$STDERR")"; return; fi
  case "$line" in *symlink*) c_ok ;; *) c_bad "the ERROR $1 line does not say 'symlink': $line" ;; esac
  if "$PY" -I -c '
import re, sys
line, comp = sys.argv[1], sys.argv[2]
sys.exit(0 if any(line[m.end():m.end() + 1] != "/" for m in re.finditer(re.escape(comp), line)) else 1)' "$line" "$2"; then
    c_ok
  else
    c_bad "the ERROR $1 line does not name the symlink $2 itself: $line"
  fi
}

# ci_setup_end CODE TEXT -- setup error CODE whose line says TEXT; nothing ran.
ci_setup_end() {
  case_begin "setup: $CNAME"
  h_setup "$1"
  h_err_line_has "$1" "$2"
  h_no_stub "$OUT" "$C"
  case_end
}
# c_ci_fence FENCE HOME -- no subpath read allow of FENCE folds (NFD, casefold, NFD) to HOME
# or a dir above it.
c_ci_fence() {
  if [ ! -f "$1" ]; then c_bad "no $(basename "$1")"; return; fi
  local o
  if o="$("$PY" -I -c '
import re, sys, unicodedata
def fold(p):
    return unicodedata.normalize("NFD", unicodedata.normalize("NFD", p).casefold())
text = open(sys.argv[1], encoding="utf-8").read()
pat = r"\(allow file-read\* \(subpath \"((?:[^\"\\]|\\.)*)\"\)\)"
allows = [re.sub(r"\\(.)", r"\1", a) for a in re.findall(pat, text)]
h = fold(sys.argv[2]).rstrip("/")
p = []
if not allows:
    p.append("no subpath read allow parsed: the checker cannot see this fence")
for a in allows:
    f = fold(a).rstrip("/")
    if f == h or f == "" or h.startswith(f + "/"):
        p.append("allows (subpath %s), which folds to the home %s or a dir above it" % (a, sys.argv[2]))
print("\n".join(p))
sys.exit(1 if p else 0)' "$1" "$2" 2>&1)"; then c_ok; else c_bad "fence: ${o:-the check printed nothing}"; fi
}

new_case "CI R1 --node under a case variant of HOME"
CIH="$C/cihome"
copy_node_tree "$CIH"
mkdir -p "$CIH/.ssh"
printf 'CI-SSH-SENTINEL\n' > "$CIH/.ssh/id_test"
printf 'CI-HOME-NOTE\n' > "$CIH/note.txt"
make_dsh "$DSH" ok probe_read="$CIH/.ssh/id_test" probe_read="$CIH/note.txt" probe_read="$CIH/bin/node"
if ci_pre "$C/CIHOME" "$CIH"; then
  run_w HOME="$CIH" -- --dsh-dir "$DSH" --out "$OUT" --node "$C/CIHOME/bin/node" "$PROMPT"
  case_begin "CI R1: --node <HOME variant>/bin/node runs, and the fence allows neither the home nor a dir above it"
  h_pass
  h_probe read "$CIH/.ssh/id_test" EPERM
  h_probe read "$CIH/note.txt" EPERM
  h_probe read "$CIH/bin/node" OK
  c_ci_fence "$OUT/fence-1.sb" "$CIH"
  case_end
fi

new_case "CI R2 --dsh-dir <HOME variant>/.local"
CIH="$C/cihome"
make_dsh "$CIH/.local" ok
if ci_pre "$C/CIHOME/.local" "$CIH/.local"; then
  run_w HOME="$CIH" -- --dsh-dir "$C/CIHOME/.local" --out "$OUT" "$PROMPT"
  ci_setup_end DSH_DIR_UNSAFE "directly under"
fi

new_case "CI R3 --dsh-dir <HOME>/.SSH/dsh"
CIH="$C/cihome"
make_dsh "$CIH/.ssh/dsh" ok
if ci_pre "$CIH/.SSH/dsh" "$CIH/.ssh/dsh"; then
  run_w HOME="$CIH" -- --dsh-dir "$CIH/.SSH/dsh" --out "$OUT" "$PROMPT"
  ci_setup_end DSH_DIR_UNSAFE "a secret dir"
fi
new_case "CI R3 --dsh-dir <HOME variant>/.ssh/dsh"
CIH="$C/cihome"
make_dsh "$CIH/.ssh/dsh" ok
if ci_pre "$C/CIHOME/.ssh/dsh" "$CIH/.ssh/dsh"; then
  run_w HOME="$CIH" -- --dsh-dir "$C/CIHOME/.ssh/dsh" --out "$OUT" "$PROMPT"
  ci_setup_end DSH_DIR_UNSAFE "a secret dir"
fi

new_case "CI R4 --repo <HOME>/.SSH/r"
CIH="$C/cihome"
make_repo "$CIH/.ssh/r"
make_dsh "$DSH" ok read="$CIH/.ssh/r/sentinel.txt"
if ci_pre "$CIH/.SSH/r" "$CIH/.ssh/r"; then
  run_w HOME="$CIH" -- --dsh-dir "$DSH" --out "$OUT" --repo "$CIH/.SSH/r" "$PROMPT"
  ci_setup_end REPO_SECRET_OVERLAP "--repo overlaps"
fi
# canon() respells only what it can open: a dir with no read bit (0311) or an execute-only
# file (0111) keeps the caller's letter case, so only the folded compare sees the overlap.
new_case "CI R4b --repo <HOME>/.SSH/r, r a git repo with mode 0311"
CIH="$C/cihome"
make_repo "$CIH/.ssh/r"
chmod 0311 "$CIH/.ssh/r"
make_dsh "$DSH" ok read="$CIH/.ssh/r/sentinel.txt"
if ci_pre "$CIH/.SSH/r" "$CIH/.ssh/r"; then
  run_w HOME="$CIH" -- --dsh-dir "$DSH" --out "$OUT" --repo "$CIH/.SSH/r" "$PROMPT"
  ci_setup_end REPO_SECRET_OVERLAP "--repo overlaps"
fi
chmod 0755 "$CIH/.ssh/r" 2>/dev/null || true

# HOME is two levels down so the out and dsh dirs are not inside either repo. HOME's parent is a
# git work tree, so without the home check both variants pass the git check and the run starts
# (the fence would then allow the whole home).
new_case "CI R5 --repo <HOME variant>"
CIH="$C/cip/cihome"
mkdir -p "$CIH"
git -C "$C/cip" init -q
make_dsh "$DSH" ok
if ci_pre "$C/cip/CIHOME" "$CIH"; then
  run_w HOME="$CIH" -- --dsh-dir "$DSH" --out "$OUT" --repo "$C/cip/CIHOME" "$PROMPT"
  ci_setup_end REPO_HOME_OR_ABOVE "must not be HOME or above it"
fi
new_case "CI R5 --repo <variant of HOME's parent>"
CIH="$C/cip/cihome"
mkdir -p "$CIH"
git -C "$C/cip" init -q
make_dsh "$DSH" ok
if ci_pre "$C/CIP" "$C/cip"; then
  run_w HOME="$CIH" -- --dsh-dir "$DSH" --out "$OUT" --repo "$C/CIP" "$PROMPT"
  ci_setup_end REPO_HOME_OR_ABOVE "must not be HOME or above it"
fi

# Green on the wrapper before the fold fix too (git prints the work tree root in its stored
# case): kept as a regression of REPO_DOTFILES under a case variant.
new_case "CI R6 --repo <variant of a dotfiles HOME>/projects/sub"
CIH="$C/dothome"
mkdir -p "$CIH/projects/sub"
git -C "$CIH" init -q
make_dsh "$DSH" ok
if ci_pre "$C/DOTHOME/projects/sub" "$CIH/projects/sub"; then
  run_w HOME="$CIH" -- --dsh-dir "$DSH" --out "$OUT" --repo "$C/DOTHOME/projects/sub" "$PROMPT"
  ci_setup_end REPO_DOTFILES "a git work tree rooted at HOME"
fi
# canon() respells only what it can open: a dir with no read bit (0311) or an execute-only
# file (0111) keeps the caller's letter case, so only the folded compare sees the overlap.
new_case "CI R6b --repo <dotfiles HOME>/projects/sub, HOME a 0311 dir spelled in another case"
CIH="$C/dothome"
mkdir -p "$CIH/projects/sub"
git -C "$CIH" init -q
chmod 0311 "$CIH"
make_dsh "$DSH" ok
if ci_pre "$C/DOTHOME" "$CIH"; then
  run_w HOME="$C/DOTHOME" -- --dsh-dir "$DSH" --out "$OUT" --repo "$CIH/projects/sub" "$PROMPT"
  ci_setup_end REPO_DOTFILES "a git work tree rooted at HOME"
fi
chmod 0755 "$CIH" 2>/dev/null || true

new_case "CI R7 --out <repo variant>/o"
CIR="$C/cirepo"
make_repo "$CIR"
make_dsh "$DSH" ok read="$CIR/sentinel.txt"
if ci_pre "$C/CIREPO" "$CIR"; then
  run_w -- --dsh-dir "$DSH" --out "$C/CIREPO/o" --repo "$CIR" "$PROMPT"
  ci_setup_end OUT_OVERLAP "inside, or contain, the repo"
  case_begin "CI R7: nothing was written into the repo"
  h_path_absent "$CIR/o" "out dir inside the repo"
  case_end
fi
# canon() respells only what it can open: a dir with no read bit (0311) or an execute-only
# file (0111) keeps the caller's letter case, so only the folded compare sees the overlap.
new_case "CI R7c --out <repo variant>/<a 0311 dir>/o"
CIR="$C/cirepo"
make_repo "$CIR"
mkdir -p "$CIR/locked"
chmod 0311 "$CIR/locked"
make_dsh "$DSH" ok read="$CIR/sentinel.txt"
if ci_pre "$C/CIREPO" "$CIR"; then
  run_w -- --dsh-dir "$DSH" --out "$C/CIREPO/locked/o" --repo "$CIR" "$PROMPT"
  ci_setup_end OUT_OVERLAP "inside, or contain, the repo"
  case_begin "CI R7c: nothing was written into the repo"
  h_path_absent "$CIR/locked/o" "out dir inside the repo"
  case_end
fi
chmod 0755 "$CIR/locked" 2>/dev/null || true

new_case "CI R8 --out <dsh dir variant>/o"
CID="$C/cidsh"
make_dsh "$CID" ok
if ci_pre "$C/CIDSH" "$CID"; then
  run_w -- --dsh-dir "$CID" --out "$C/CIDSH/o" "$PROMPT"
  ci_setup_end OUT_OVERLAP "inside, or contain, the dsh dir"
fi

# A node tree (bin + lib) copied into the repo, so without the scope check node starts and the
# run goes through.
new_case "CI R9 --node <repo variant>/bin/node"
CIR="$C/cirepo"
make_repo "$CIR"
copy_node_tree "$CIR"
make_dsh "$DSH" ok read="$CIR/sentinel.txt"
if ci_pre "$C/CIREPO/bin/node" "$CIR/bin/node"; then
  run_w -- --dsh-dir "$DSH" --out "$OUT" --repo "$CIR" --node "$C/CIREPO/bin/node" "$PROMPT"
  ci_setup_end NODE_IN_SCOPE "node resolves inside"
fi
# canon() respells only what it can open: a dir with no read bit (0311) or an execute-only
# file (0111) keeps the caller's letter case, so only the folded compare sees the overlap.
new_case "CI R9b --node <repo variant>/bin/node, the node copy execute-only (0111)"
CIR="$C/cirepo"
make_repo "$CIR"
copy_node_tree "$CIR"
chmod 0111 "$CIR/bin/node"
make_dsh "$DSH" ok read="$CIR/sentinel.txt"
if ci_pre "$C/CIREPO/bin/node" "$CIR/bin/node"; then
  run_w -- --dsh-dir "$DSH" --out "$OUT" --repo "$CIR" --node "$C/CIREPO/bin/node" "$PROMPT"
  ci_setup_end NODE_IN_SCOPE "node resolves inside"
fi
chmod 0755 "$CIR/bin/node" 2>/dev/null || true

new_case "CI R10 --dsh-dir <repo variant>/dsh"
CIR="$C/cirepo"
make_repo "$CIR"
make_dsh "$CIR/dsh" ok read="$CIR/sentinel.txt"
if ci_pre "$C/CIREPO/dsh" "$CIR/dsh"; then
  run_w -- --dsh-dir "$C/CIREPO/dsh" --out "$OUT" --repo "$CIR" "$PROMPT"
  ci_setup_end DSH_DIR_UNSAFE "must not overlap the repo"
fi
# canon() respells only what it can open: a dir with no read bit (0311) or an execute-only
# file (0111) keeps the caller's letter case, so only the folded compare sees the overlap.
# Without the folded overlap check the bin.js check refuses next, with its own message.
new_case "CI R10b --dsh-dir <repo variant>/dsh, the dsh dir with mode 0311"
CIR="$C/cirepo"
make_repo "$CIR"
make_dsh "$CIR/dsh" ok read="$CIR/sentinel.txt"
chmod 0311 "$CIR/dsh"
if ci_pre "$C/CIREPO/dsh" "$CIR/dsh"; then
  run_w -- --dsh-dir "$C/CIREPO/dsh" --out "$OUT" --repo "$CIR" "$PROMPT"
  ci_setup_end DSH_DIR_UNSAFE "must not overlap the repo"
fi
chmod 0755 "$CIR/dsh" 2>/dev/null || true

# R11: unsafe_dir, node_read_dirs and check_repo called directly (mode = broad | home | nfd | usr |
# nfdorder | dotfiles). In usr,
# the "/usr/lib" assertion pins the prefix test of node_read_dirs (a fix that folds unsafe_dir
# only would add /USR/lib); before any fold the wrapper allowed /USR whole, which the second
# assertion (no broad dir whole) catches.
CI_UNIT_PY='
import contextlib, importlib.machinery, importlib.util, io, os, sys, unicodedata
mode, bin_path, base = sys.argv[1], sys.argv[2], sys.argv[3]
def fold(p):
    return unicodedata.normalize("NFD", unicodedata.normalize("NFD", p).casefold())
saved = list(sys.argv)
sys.argv = ["deepseek-review"]
o, e = io.StringIO(), io.StringIO()
try:
    with contextlib.redirect_stdout(o), contextlib.redirect_stderr(e):
        ld = importlib.machinery.SourceFileLoader("dsr_wrapper", bin_path)
        m = importlib.util.module_from_spec(importlib.util.spec_from_loader("dsr_wrapper", ld))
        ld.exec_module(m)
except SystemExit as x:
    print("importing the wrapper ran main (SystemExit %r)" % (x.code,))
    sys.exit(1)
sys.argv = saved
sys.excepthook = sys.__excepthook__
if o.getvalue() or e.getvalue():
    print("importing the wrapper printed something (main ran?): %r" % (o.getvalue() + e.getvalue())[:200])
    sys.exit(1)
if not (callable(getattr(m, "unsafe_dir", None)) and callable(getattr(m, "node_read_dirs", None))):
    print("the wrapper has no unsafe_dir / node_read_dirs")
    sys.exit(1)
BROAD = {"/", "/usr", "/usr/local", "/opt", "/opt/homebrew", "/Users", "/private", "/var", "/tmp",
         "/etc", "/private/var", "/private/tmp", "/private/etc"} | set(getattr(m, "BROAD", ()))
SECRETS = {".ssh", ".gnupg", ".aws", ".config", ".dsh", ".claude", ".codex", ".gemini",
           ".kimi-code", "Library"} | set(getattr(m, "SECRET_DIRS", ()))
p, skips, ran = [], [], [0]
def same(v, s):
    try:
        ok = v != s and os.path.samefile(v, s)
    except OSError:
        ok = False
    if not ok:
        skips.append("%s is not the same file as %s (case-sensitive here)" % (v, s))
    return ok
def want(cond, text):
    ran[0] += 1
    if not cond:
        p.append(text)
if mode == "broad":
    for b in sorted(BROAD):
        v = b.upper()
        if v == b or not same(v, b):
            continue
        want(m.unsafe_dir(v), "unsafe_dir(%r) is False (the broad dir %s)" % (v, b))
        want(m.unsafe_dir(v, home_child_ok=True), "unsafe_dir(%r, home_child_ok=True) is False" % v)
elif mode == "home":
    h = os.environ["HOME"]
    hv = os.path.join(os.path.dirname(h), os.path.basename(h).upper())
    os.makedirs(os.path.join(h, ".local"), exist_ok=True)
    for s in sorted(SECRETS):
        os.makedirs(os.path.join(h, s), exist_ok=True)
    if same(hv, h):
        want(m.unsafe_dir(hv), "unsafe_dir(%r) is False (a variant of the home %s)" % (hv, h))
        want(m.unsafe_dir(hv, home_child_ok=True), "unsafe_dir(%r, home_child_ok=True) is False" % hv)
        want(m.unsafe_dir(hv + "/.local"), "unsafe_dir(%r) is False (a direct child of the home)" % (hv + "/.local"))
    for s in sorted(SECRETS):
        sv = os.path.join(h, s.upper())
        if s.upper() == s or not same(sv, os.path.join(h, s)):
            continue
        # home_child_ok=True and a dir below: the direct-child rule cannot make these vacuous.
        want(m.unsafe_dir(sv, home_child_ok=True), "unsafe_dir(%r, home_child_ok=True) is False (secret dir %s)" % (sv, s))
        want(m.unsafe_dir(sv + "/x"), "unsafe_dir(%r) is False (below secret dir %s)" % (sv + "/x", s))
        hsv = os.path.join(hv, s)
        if same(hsv, os.path.join(h, s)):
            want(m.unsafe_dir(hsv + "/x"), "unsafe_dir(%r) is False (secret dir %s under a home variant)" % (hsv + "/x", s))
elif mode == "nfd":
    name = "hi" + chr(0x1EBF) + "u"
    nfc = os.path.join(base, unicodedata.normalize("NFC", name))
    nfd = os.path.join(base, unicodedata.normalize("NFD", name))
    os.makedirs(os.path.join(nfc, ".ssh"), exist_ok=True)
    os.environ["HOME"] = nfc
    if same(nfd, nfc):
        want(m.unsafe_dir(nfd), "unsafe_dir(<NFD spelling>) is False for the NFC home %r" % nfc)
        want(m.unsafe_dir(nfd + "/.local"), "unsafe_dir(<NFD spelling>/.local) is False (a direct child of the home)")
        want(m.unsafe_dir(nfd + "/.ssh/x"), "unsafe_dir(<NFD spelling>/.ssh/x) is False (below the home secret dir)")
elif mode == "usr":
    if same("/USR", "/usr"):
        d = m.node_read_dirs("/USR/bin/node")
        fb = {fold(b) for b in BROAD}
        want(not any(fold(x) == fold("/usr/lib") for x in d), "node_read_dirs(/USR/bin/node) has an entry folding to /usr/lib: %r" % d)
        want(not any(fold(x).rstrip("/") in fb or fold(x) == "/" for x in d),
             "node_read_dirs(/USR/bin/node) allows a broad dir whole: %r" % d)
elif mode == "nfdorder":
    # Two canonically equivalent spellings whose marks come in another order: only the NFD
    # BEFORE casefold makes them equal (U+0345 casefolds to a base letter, U+03B9).
    h = os.path.join(base, "ca" + chr(0x300) + chr(0x345) + "t")
    v = os.path.join(base, "ca" + chr(0x345) + chr(0x300) + "t")
    os.makedirs(h, exist_ok=True)
    os.environ["HOME"] = h
    if same(v, h):
        want(m.unsafe_dir(v), "unsafe_dir(<home with its marks reordered>) is False")
        want(m.unsafe_dir(v + "/.local"), "unsafe_dir(<home with its marks reordered>/.local) is False")
elif mode == "dotfiles":
    # REPO_DOTFILES compares the work-tree root git prints with the homes, folded. Real git
    # prints the stored case, so git is faked here to print the home in another case.
    import types
    h = os.environ["HOME"]
    hv = os.path.join(os.path.dirname(h), os.path.basename(h).upper())
    sub = os.path.join(h, "projects", "sub")
    os.makedirs(sub, exist_ok=True)
    if same(hv, h):
        calls = []
        def run_with(top):
            def fake_run(argv, **kw):
                calls.append(list(argv))
                return types.SimpleNamespace(stdout=top + "\n", stderr="", returncode=0)
            m.subprocess.run = fake_run
            try:
                m.check_repo(sub)
            except m.SetupError as x:
                return x.code
            return None
        other = os.path.join(base, "elsewhere")
        os.makedirs(other, exist_ok=True)
        want(run_with(other) is None, "control: a work tree rooted elsewhere was refused")
        want(calls and calls[-1][:2] == [m.GIT, "-C"] and calls[-1][-2:] == ["rev-parse", "--show-toplevel"],
             "git was never asked for the work-tree root (scenario not reproduced): %r" % calls)
        want(run_with(h) == "REPO_DOTFILES", "control: a work tree rooted at HOME (stored case) is not REPO_DOTFILES")
        got = run_with(hv)
        want(got == "REPO_DOTFILES", "a work tree rooted at %s (HOME in another case) gave %r, not REPO_DOTFILES" % (hv, got))
elif mode == "canon":
    # canon() may only change the case or normalization of a path. F_GETPATH is faked: the same
    # path in another case is taken (control), another name (a hard link) or a relative answer is not.
    import types
    f = os.path.join(base, "canon-file.txt")
    open(f, "w").close()
    real_fcntl = m.fcntl
    def answer(got):
        def fake(fd, op, buf):
            if op != real_fcntl.F_GETPATH:
                raise OSError("unexpected fcntl op %r" % (op,))
            b = got.encode()
            return b + bytes(len(buf) - len(b))
        m.fcntl = types.SimpleNamespace(F_GETPATH=real_fcntl.F_GETPATH, fcntl=fake)
        try:
            return m.canon(f)
        finally:
            m.fcntl = real_fcntl
    sw = os.path.join(base, "CANON-FILE.txt")
    want(answer(sw) == sw, "control: canon did not take the answer %r (the same path in another case): the fake was not used" % sw)
    other = os.path.join(base, "other-name.txt")
    got = answer(other)
    want(got == f, "canon(%r) took the answer %r (another name, a hard link): got %r" % (f, other, got))
    got = answer("canon-file.txt")
    want(got == f, "canon(%r) took the relative answer canon-file.txt: got %r" % (f, got))
elif mode == "roots":
    # A node found through PATH must resolve under Homebrew or a version manager dir of the
    # ACCOUNT home (faked here; HOME points elsewhere).
    ah = os.path.join(base, "acct")
    os.makedirs(ah, exist_ok=True)
    m.account_home = lambda: ah
    want(os.environ["HOME"] != ah, "control: HOME is the faked account home")
    exp = ["/opt/homebrew", "/usr/local", ah + "/.nvm/versions", ah + "/.volta", ah + "/.asdf/installs"]
    got = m.node_roots()
    want(got == exp, "node_roots() is %r, expected %r" % (got, exp))
    def from_path(bindir):
        os.makedirs(bindir, exist_ok=True)
        n = os.path.join(bindir, "node")
        with open(n, "w") as fh:
            fh.write("#!/bin/sh\nexit 0\n")
        os.chmod(n, 0o755)
        os.environ["PATH"] = bindir
        try:
            return m.resolve_node(None, [])
        except m.SetupError as x:
            return x.code
    for rel in (".nvm/versions/node/v1/bin", ".volta/tools/image/node/1/bin", ".asdf/installs/nodejs/1/bin"):
        b = os.path.join(ah, rel)
        got = from_path(b)
        want(got == os.path.realpath(os.path.join(b, "node")), "a PATH node under <account home>/%s gave %r" % (rel, got))
    got = from_path(os.path.join(ah, "tools", "bin"))
    want(got == "NODE_UNTRUSTED", "a PATH node under <account home>/tools/bin gave %r, not NODE_UNTRUSTED" % (got,))
elif mode == "secret":
    # The prompt check refuses a file in a secret dir reached through its realpath too (~/.aws a
    # symlink to a dir elsewhere).
    h = os.path.join(base, "sechome")
    tgt = os.path.join(base, "aws-data")
    os.makedirs(os.path.join(h, ".ssh"), exist_ok=True)
    os.makedirs(tgt, exist_ok=True)
    os.symlink(tgt, os.path.join(h, ".aws"))
    pf = os.path.join(tgt, "prompt.txt")
    open(pf, "w").close()
    os.environ["HOME"] = h
    other = os.path.join(base, "elsewhere.txt")
    open(other, "w").close()
    want(m.in_secret_dir(m.real(other)) is None, "control: a file outside every secret dir was refused")
    want(m.in_secret_dir(m.real(os.path.join(h, ".ssh", "x"))), "control: a path in <HOME>/.ssh was not refused")
    want(m.in_secret_dir(m.real(pf)), "a file in the realpath of <HOME>/.aws (a symlink) was not refused")
elif mode == "doctor":
    # mode_doctor with node, dsh and the version check faked and run_group answering as told.
    import argparse
    d = os.path.join(base, "dsh")
    os.makedirs(d, exist_ok=True)
    os.environ["DEEPSEEK_API_KEY"] = "FAKE-unit-key-0123456789"
    m.resolve_node = lambda arg, scopes: "/usr/bin/true"
    m.check_dsh = lambda dd, repo: (dd, os.path.join(dd, "bin.js"))
    m.version_ok = lambda *a, **k: (m.PINNED_VERSION, "")
    def doctor(ans):
        def fake_rg(argv, cwd, env, limit):
            if "--dump-config" not in argv:
                raise OSError("run_group called without --dump-config: %r" % (argv,))
            if ans == "signal":
                m.Cancel.reason = "SIGTERM"
                return False, None, b"", b""
            return ans
        m.run_group = fake_rg
        o = io.StringIO()
        try:
            with contextlib.redirect_stdout(o):
                rc = m.mode_doctor(argparse.Namespace(node=None, dsh_dir=d))
        except m.SetupError as x:
            rc = "SetupError " + x.code
        return rc, o.getvalue()
    TMO = "overlay: PROBLEM: --dump-config timed out after 120s; its process group was killed"
    rc, out = doctor((True, 0, b"", b""))
    want(rc == 0 and "overlay: composes cleanly under the fence" in out.splitlines(),
         "control: a finished clean --dump-config gave %r: %r" % (rc, out[-300:]))
    rc, out = doctor((False, 0, b"", b""))
    want(rc == 1 and TMO in out.splitlines(),
         "a --dump-config past its limit whose exit read 0 gave %r: %r" % (rc, out[-300:]))
    rc, out = doctor((False, None, b"", b""))
    want(rc == 1 and TMO in out.splitlines(), "a --dump-config past its limit gave %r: %r" % (rc, out[-300:]))
    rc, out = doctor("signal")
    want(rc == "SetupError CANCELLED", "a signal during --dump-config gave %r, not CANCELLED: %r" % (rc, out[-300:]))
elif mode == "roots3":
    # Round 3 #11: node_roots() takes each root where it leads. A symlinked ~/.nvm counts at its
    # target; a root that resolves to / (~/.volta -> /) or to a home (~/.asdf/installs -> HOME)
    # is dropped, so a node anywhere else stays NODE_UNTRUSTED.
    ah = os.path.join(base, "acct3")
    nvm = os.path.join(base, "nvm-real")
    os.makedirs(os.path.join(nvm, "versions"), exist_ok=True)
    os.makedirs(os.path.join(ah, ".asdf"), exist_ok=True)
    os.symlink(nvm, os.path.join(ah, ".nvm"))
    os.symlink("/", os.path.join(ah, ".volta"))
    os.symlink(os.environ["HOME"], os.path.join(ah, ".asdf", "installs"))
    m.account_home = lambda: ah
    exp = [m.real("/opt/homebrew"), m.real("/usr/local"), os.path.realpath(os.path.join(nvm, "versions"))]
    got = m.node_roots()
    want(got == exp, "node_roots() is %r, expected %r" % (got, exp))
    def from_path3(bindir):
        os.makedirs(bindir, exist_ok=True)
        n = os.path.join(bindir, "node")
        with open(n, "w") as fh:
            fh.write("#!/bin/sh\nexit 0\n")
        os.chmod(n, 0o755)
        os.environ["PATH"] = bindir
        try:
            return m.resolve_node(None, [])
        except m.SetupError as x:
            return x.code
    b = os.path.join(ah, ".nvm", "versions", "node", "v1", "bin")
    got = from_path3(b)
    want(got == os.path.realpath(os.path.join(b, "node")), "a PATH node under the symlinked <account home>/.nvm gave %r" % (got,))
    got = from_path3(os.path.join(base, "elsewhere3", "bin"))
    want(got == "NODE_UNTRUSTED", "a PATH node outside every root gave %r, not NODE_UNTRUSTED (~/.volta -> / kept?)" % (got,))
    got = from_path3(os.path.join(os.environ["HOME"], "tools", "bin"))
    want(got == "NODE_UNTRUSTED", "a PATH node under HOME/tools/bin gave %r, not NODE_UNTRUSTED (~/.asdf/installs -> HOME kept?)" % (got,))
elif mode == "cancel":
    # Round 3 #8: a signal while validate() runs cancels the attempt (FAIL CANCELLED, exit 1,
    # nothing on stdout); one after that checkpoint waits until the answer is printed. dsh is
    # /usr/bin/true; validate and report are wrapped.
    import json, signal, threading
    d = os.path.join(base, "udsh")
    os.makedirs(d, exist_ok=True)
    os.environ["DEEPSEEK_API_KEY"] = "FAKE-unit-key-0123456789"
    m.fence_profile = lambda *a, **k: "(version 1)\n"
    m.version_ok = lambda *a, **k: (m.PINNED_VERSION, "")
    m.launch_argv = lambda *a, **k: ["/usr/bin/true"]
    ORIG_REPORT = m.report
    ANSWER = "THE UNIT ANSWER\n"
    def attempt(tag, fake_validate, fake_report):
        out = os.path.join(base, "uout-" + tag)
        for s in ("home", "tmp", "work"):
            os.makedirs(os.path.join(out, s), exist_ok=True)
        with open(os.path.join(out, "review.patch.yml"), "w") as fh:
            fh.write("x: 1\n")
        m.validate = fake_validate
        m.report = fake_report
        o, e = io.StringIO(), io.StringIO()
        try:
            with contextlib.redirect_stdout(o), contextlib.redirect_stderr(e):
                rc = m.run_attempt(out=out, n=1, prompt="p", repo=None, expect=[], model="deepseek-chat",
                                   model_source="default", effort="high", max_tokens=1000,
                                   node="/usr/bin/true", dsh_dir=d, binjs=os.path.join(d, "bin.js"),
                                   key="FAKE-unit-key-0123456789", timeout=30, session_id=None)
        except Exception as x:
            rc = "raised %s: %s" % (type(x).__name__, x)
        try:
            with open(os.path.join(out, "status-1.json")) as fh:
                st = json.load(fh)
        except (OSError, ValueError):
            st = {}
        return rc, o.getvalue(), e.getvalue(), st
    def v_clean(*a):
        return [], ANSWER, [], {}
    def v_signal(*a):
        m.Cancel.reason = "SIGTERM"  # what Cancel.handler records for a SIGTERM during validate
        return [], ANSWER, [], {}
    rc, so, se, st = attempt("control", v_clean, ORIG_REPORT)
    want(rc == 0 and so == ANSWER and st.get("verdict") == "PASS",
         "control: a clean attempt gave %r, stdout %r, status %r: %s" % (rc, so, st.get("verdict"), se[-300:]))
    rc, so, se, st = attempt("cancel", v_signal, ORIG_REPORT)
    want(rc == 1, "a signal during validate gave exit %r, not 1: %s" % (rc, se[-300:]))
    want(so == "", "a signal during validate still printed the answer: %r" % (so,))
    want(st.get("cancelled") is True and "CANCELLED" in (st.get("reasons") or []),
         "a signal during validate: status-1 says cancelled %r, reasons %r" % (st.get("cancelled"), st.get("reasons")))
    want("deepseek-review: FAIL CANCELLED:" in se, "a signal during validate: no FAIL CANCELLED line: %r" % (se[-300:],))
    seen = []
    def r_signal(fails, final_text, denied):
        signal.pthread_kill(threading.main_thread().ident, signal.SIGTERM)
        for _ in range(2000):
            pass  # bytecodes in which a pending Python handler would run
        seen.append(m.Cancel.reason)
        return ORIG_REPORT(fails, final_text, denied)
    rc, so, se, st = attempt("held", v_clean, r_signal)
    want(seen == [None], "a SIGTERM sent while the answer is printed reached the handler before it was printed: %r" % (seen,))
    want(rc == 0 and so == ANSWER, "a SIGTERM after the checkpoint changed the outcome: exit %r, stdout %r" % (rc, so))
    want(m.Cancel.reason == "SIGTERM", "the held SIGTERM never reached the handler (scenario not reproduced): %r" % (m.Cancel.reason,))
for s in skips:
    print("SKIP " + s)
print("\n".join(p))
print("CHECKS %d" % ran[0])
if not ran[0]:
    sys.exit(3 if skips else 1)  # 3: every check skipped (a case-sensitive volume)
sys.exit(1 if p else 0)
'
# ci_unit MODE HOME -- one R11 mode. SKIP lines become skips; a run whose every check skipped
# prints no verdict of its own (never a pass); exit 0 needs a CHECKS line above zero.
ci_unit() {
  if [ -z "$SEL" ]; then note_desel "$CNAME"; return; fi
  local o rc line n
  o="$(/usr/bin/env -i HOME="$2" PATH=/usr/bin:/bin /usr/bin/python3 -I -B -c "$CI_UNIT_PY" "$1" "$BIN" "$C" 2>&1)"
  rc=$?
  while IFS= read -r line; do
    case "$line" in "SKIP "*) note_skip "$CNAME: ${line#SKIP }" ;; esac
  done <<< "$o"
  [ "$rc" = 3 ] && return
  n="$(printf '%s\n' "$o" | sed -n 's/^CHECKS \([0-9]*\)$/\1/p')"
  case_begin "$CNAME"
  if [ "$rc" = 0 ] && [ "${n:-0}" -gt 0 ]; then
    c_ok
  else
    c_bad "exit $rc, ${n:-no} checks, $(printf '%s\n' "$o" | grep -cv '^SKIP \|^CHECKS \|^$') problems: $(printf '%s\n' "$o" | grep -v '^SKIP \|^CHECKS ' | head -c 6000)"
  fi
  case_end
}
new_case "CI R11 unsafe_dir: upper-cased broad dirs"
mkdir -p "$C/cihome"
ci_unit broad "$C/cihome"
new_case "CI R11 unsafe_dir: variants of a home, its direct child and its secret dirs"
mkdir -p "$C/cihome"
ci_unit home "$C/cihome"
new_case "CI R11 unsafe_dir: an NFC home given in NFD"
mkdir -p "$C/cihome"
ci_unit nfd "$C/cihome"
new_case "CI R11 node_read_dirs: /USR/bin/node"
mkdir -p "$C/cihome"
ci_unit usr "$C/cihome"
new_case "CI R11 unsafe_dir: a home spelled with its combining marks reordered"
mkdir -p "$C/cihome"
ci_unit nfdorder "$C/cihome"
new_case "CI R6u check_repo: REPO_DOTFILES when git prints HOME in another case"
mkdir -p "$C/cihome"
ci_unit dotfiles "$C/cihome"

# --out may hold HOME only while neither exists yet; ciprobe proves the volume folds case.
new_case "CI R12 --out <variant of a dir holding HOME>"
make_dsh "$DSH" ok
mkdir -p "$C/ciprobe"
if ci_pre "$C/CIPROBE" "$C/ciprobe"; then
  run_w HOME="$C/hh/home" ENV:PYTHONDONTWRITEBYTECODE=1 -- --dsh-dir "$DSH" --out "$C/HH" "$PROMPT"
  ci_setup_end OUT_OVERLAP "must not be HOME or above it"
fi
# realpath and canon() respell only a path that exists: a HOME not created yet keeps the
# caller's spelling, so only a folded compare sees it under the repo.
new_case "CI R5b --repo <dir>, HOME=<that dir in another case>/home (not created)"
CIR="$C/cihr"
make_repo "$CIR"
make_dsh "$DSH" ok read="$CIR/sentinel.txt"
if ci_pre "$C/CIHR" "$CIR"; then
  run_w HOME="$C/CIHR/home" ENV:PYTHONDONTWRITEBYTECODE=1 -- --dsh-dir "$DSH" --out "$OUT" --repo "$CIR" "$PROMPT"
  ci_setup_end REPO_HOME_OR_ABOVE "must not be HOME or above it"
fi
# The out-dir overlap check runs before check_dsh, so the dsh dir may not exist yet and keeps
# the caller's spelling: OUT_OVERLAP must win over DSH_MISSING.
new_case "CI R8b --out <dir>, --dsh-dir <that dir in another case>/dsh, neither created"
make_dsh "$DSH" ok
mkdir -p "$C/ciprobe"
if ci_pre "$C/CIPROBE" "$C/ciprobe"; then
  run_w -- --dsh-dir "$C/CIO8/dsh" --out "$C/cio8" "$PROMPT"
  ci_setup_end OUT_OVERLAP "inside, or contain, the dsh dir"
fi

new_case "CI G1 --expect-read <repo variant>/sentinel.txt"
CIR="$C/cirepo"
make_repo "$CIR"
make_dsh "$DSH" ok read="$CIR/sentinel.txt"
if ci_pre "$C/CIREPO/sentinel.txt" "$CIR/sentinel.txt"; then
  run_w -- --dsh-dir "$DSH" --out "$OUT" --repo "$CIR" --expect-read "$C/CIREPO/sentinel.txt" "$PROMPT"
  case_begin "CI G1: --expect-read <repo variant>/x names the stored file: the run passes and records it as stored"
  h_pass
  c_tl "status" status-check "$OUT/status-1.json" expect_read="[\"$CIR/sentinel.txt\"]"
  case_end
fi

new_case "CI G2 bin.js is a symlink into a case variant of the dsh dir"
CID="$C/cidsh"
make_dsh "$CID" ok
CIL="$CID/node_modules/@deepseek-ai/dsh/lib"
mv "$CIL/bin.js" "$CIL/bin-real.js"
ln -s "$C/CIDSH/node_modules/@deepseek-ai/dsh/lib/bin-real.js" "$CIL/bin.js"
if ci_pre "$C/CIDSH" "$CID"; then
  run_w -- --dsh-dir "$CID" --out "$OUT" "$PROMPT"
  case_begin "CI G2: a bin.js symlink into a case variant of the dsh dir stays inside it: the run passes"
  h_pass
  case_end
fi

# Every existing path is respelled as stored (F_GETPATH), so a variant spelling of the repo is the
# same repo for --continue, and a read reported under it is a repo read.
new_case "CI G3 --continue --repo <variant of the recorded repo>"
make_repo "$REPO"
RV="$FAKEHOME/src/R$CASE_N"
make_dsh "$DSH" ok read="$REPO/sentinel.txt"
if ci_pre "$RV" "$REPO"; then
  wr --repo "$REPO" "$PROMPT"
  G3_RC=$RC
  rm -f "$OUT"/home/stub-record-*.json
  run_w -- --continue "$OUT" --repo "$RV" --dsh-dir "$DSH" "$PROMPT"
  case_begin "CI G3: --continue --repo <variant of the recorded repo> is the same repo: attempt 2 runs"
  if [ "$G3_RC" = 0 ]; then c_ok; else c_bad "control: attempt 1 exit $G3_RC"; fi
  h_pass
  h_path_present "$OUT/prompt-2.txt" "no 2nd attempt was started"
  case_end
fi
new_case "CI G4 a read under a case variant of the repo"
make_repo "$REPO"
RV="$FAKEHOME/src/R$CASE_N"
if ci_pre "$RV" "$REPO"; then
  repo_case "CI G4: a read reported under a case variant of the repo is a repo read" ok PASS - \
    read="$RV/sentinel.txt" --
  case_end
  # agy round 2 #5: --repo given in another case records the stored spelling, which is what dsh
  # reports as its cwd, so the run's reads count.
  make_dsh "$DSH" ok read=sentinel.txt
  OUT="$C/out-g4b"
  wr --repo "$RV" "$PROMPT"
  case_begin "CI G4b: --repo <variant> records the stored repo, and a relative read under dsh's cwd counts"
  h_pass
  c_tl "status" status-check "$OUT/status-1.json" repo="\"$REPO\""
  h_rec_eq "stub cwd" cwd "\"$REPO\""
  case_end
fi
new_case "CI G5 an --expect-read file read only under a case variant"
make_repo "$REPO"
RV="$FAKEHOME/src/R$CASE_N"
if ci_pre "$RV" "$REPO"; then
  repo_case "CI G5: an --expect-read file read under a case variant of its path is read" ok \
    PASS - read="$REPO/sentinel.txt" read="$RV/src/a.txt" -- --expect-read "$REPO/src/a.txt"
  case_end
fi
# The recorded repo is compared exactly with what it resolves to now: a rename that changes only
# the letter case moves the stored spelling, and --continue refuses rather than guess.
new_case "CI G6 --continue after a case-only rename of the recorded repo"
make_repo "$REPO"
RV="$FAKEHOME/src/R$CASE_N"
make_dsh "$DSH" ok read="$REPO/sentinel.txt"
if ci_pre "$RV" "$REPO"; then
  wr --repo "$REPO" "$PROMPT"
  G6_RC=$RC
  [ -z "$SEL" ] || mv "$REPO" "$RV"
  rm -f "$OUT"/home/stub-record-*.json
  run_w -- --continue "$OUT" --dsh-dir "$DSH" "$PROMPT"
  case_begin "setup: CI G6 --continue after a case-only rename of the recorded repo is CONTINUE_REPO_MISMATCH"
  if [ "$G6_RC" = 0 ]; then c_ok; else c_bad "control: attempt 1 exit $G6_RC"; fi
  if [ -z "$SEL" ] || [ "$(ls "$FAKEHOME/src" | grep -cx "R$CASE_N")" = 1 ]; then c_ok; else c_bad "the rename to R$CASE_N did not happen"; fi
  h_setup CONTINUE_REPO_MISMATCH
  h_err_line_has CONTINUE_REPO_MISMATCH "now resolves to"
  h_path_absent "$OUT/prompt-2.txt" "a 2nd attempt was started"
  case_end
fi

# ==============================================================================================
echo "== R2: review round 2 (Codex gpt-6.1-sol xhigh, Antigravity gemini-4-argon medium)"

new_case "R2 prompt symlink"
make_dsh "$DSH" ok
ln -s "$PROMPT" "$C/link-prompt.txt"
run_w -- --dsh-dir "$DSH" --out "$OUT" "$C/link-prompt.txt"
case_begin "setup: R2 a PROMPT_FILE that is a symlink is PROMPT_UNSAFE"
h_setup PROMPT_UNSAFE
h_err_line_has PROMPT_UNSAFE "is a symlink"
h_no_stub "$OUT" "$C"
case_end
new_case "R2 prompt in a secret dir"
make_dsh "$DSH" ok
printf 'PROMPT-IN-SSH-SENTINEL\n' > "$FAKEHOME/.ssh/prompt.txt"
ln -s "$FAKEHOME/.ssh" "$C/review-dir"
run_w -- --dsh-dir "$DSH" --out "$OUT" "$C/review-dir/prompt.txt"
# Round 3: the user-symlink check runs first, so this is refused for the symlink it runs through.
case_begin "setup: R2 a PROMPT_FILE reached through a symlinked dir into ~/.ssh is PROMPT_UNSAFE"
h_setup PROMPT_UNSAFE
h_err_names_symlink PROMPT_UNSAFE "$C/review-dir"
h_text_lacks "stderr" "PROMPT-IN-SSH-SENTINEL" "$STDERR"
h_no_stub "$OUT" "$C"
case_end
# Passed directly (no symlink): refused for the opened file's own path, after the open.
new_case "R2 prompt in a secret dir passed directly"
make_dsh "$DSH" ok
run_w -- --dsh-dir "$DSH" --out "$OUT" "$FAKEHOME/.ssh/prompt.txt"
case_begin "setup: R2 a PROMPT_FILE in ~/.ssh passed directly is PROMPT_UNSAFE (resolves into the secret dir)"
h_setup PROMPT_UNSAFE
h_err_line_has PROMPT_UNSAFE "resolves into"
if printf '%s' "$STDERR" | grep "^deepseek-review: ERROR PROMPT_UNSAFE:" | grep -q symlink; then
  c_bad "the PROMPT_UNSAFE line blames a symlink: no symlink is involved"
else
  c_ok
fi
h_text_lacks "stderr" "PROMPT-IN-SSH-SENTINEL" "$STDERR"
h_no_stub "$OUT" "$C"
case_end
rm -f "$FAKEHOME/.ssh/prompt.txt"

new_case "R2 short key"
make_dsh "$DSH" ok
run_w KEY=Ab3dE6g -- --dsh-dir "$DSH" --out "$OUT" "$PROMPT"
case_begin "setup: R2 a key shorter than 8 characters is KEY_INVALID, never printed"
h_setup KEY_INVALID
h_err_line_has KEY_INVALID "shorter than 8"
h_text_lacks "stderr" "Ab3dE6g" "$STDERR"
h_no_stub "$OUT" "$C"
case_end

new_case "R2 dsh symlink outside"
make_dsh "$DSH" ok
ln -s "$OUTSIDE" "$DSH/node_modules/evil-pkg"
run_w -- --dsh-dir "$DSH" --out "$OUT" "$PROMPT"
case_begin "setup: R2 a symlink in the dsh dir that resolves outside it is DSH_DIR_UNSAFE"
h_setup DSH_DIR_UNSAFE
h_err_line_has DSH_DIR_UNSAFE "is a symlink that resolves outside"
h_no_stub "$OUT" "$C"
case_end

new_case "R2 env dirs"
make_repo "$REPO"
mkdir -p "$REPO/.env.d" "$REPO/cfg/.env"
printf 'ENVD-SENTINEL\n' > "$REPO/.env.d/cred"
printf 'ENVDIR-SENTINEL\n' > "$REPO/cfg/.env/prod"
printf 'KEEP\n' > "$REPO/src/keep.txt"
make_dsh "$DSH" ok read="$REPO/sentinel.txt" probe_read="$REPO/.env.d/cred" \
  probe_read="$REPO/cfg/.env/prod" probe_read="$REPO/src/keep.txt"
wr --repo "$REPO" "$PROMPT"
case_begin "R2: files under a dir named like .env (.env.d/cred, cfg/.env/prod) are denied; others stay readable"
h_pass
h_probe read "$REPO/.env.d/cred" EPERM
h_probe read "$REPO/cfg/.env/prod" EPERM
h_probe read "$REPO/src/keep.txt" OK
case_end

new_case "R2 continue keeps expect-read"
make_repo "$REPO"
make_dsh "$DSH" ok sid=session-r2 read="$REPO/sentinel.txt"
wr --repo "$REPO" --expect-read "$REPO/src/a.txt" "$PROMPT"
A1_RC=$RC
rm -f "$OUT"/home/stub-record-*.json
set_scenario ok sid=session-r2 read="$REPO/sentinel.txt"
run_w -- --continue "$OUT" --dsh-dir "$DSH" "$PROMPT"
case_begin "R2: --continue keeps attempt 1's --expect-read: a follow-up that never reads it is EXPECTED_READ_MISSING"
if [ "$A1_RC" = 1 ]; then c_ok; else c_bad "attempt 1 exit $A1_RC, expected 1 (EXPECTED_READ_MISSING)"; fi
h_fail_codes EXPECTED_READ_MISSING exact
c_tl "status-2" status-check "$OUT/status-2.json" expect_read="[\"$REPO/src/a.txt\"]"
h_status 2
h_check_agrees
case_end

new_case "R2 continue bad max_tokens"
make_repo "$REPO"
make_dsh "$DSH" ok sid=session-r2m read="$REPO/sentinel.txt"
wr --repo "$REPO" "$PROMPT"
[ -z "$SEL" ] || tl status-set "$OUT/status-1.json" max_tokens='-1'
rm -f "$OUT"/home/stub-record-*.json
run_w -- --continue "$OUT" --dsh-dir "$DSH" "$PROMPT"
case_begin "setup: R2 --continue on a status-1.json with max_tokens -1 is STATUS_INVALID before attempt 2"
h_setup STATUS_INVALID
h_err_line_has STATUS_INVALID "max_tokens"
h_path_absent "$OUT/prompt-2.txt" "a 2nd attempt was started"
case_end

new_case "R2 status fields"
make_repo "$REPO"
fab_out "$C/o-base" ok "$REPO" read="$REPO/sentinel.txt" cwd="$REPO"
OUT="$C/o-base"
run_w -- --check "$OUT"
case_begin "R2 control: the unmodified fabricated out passes --check"
h_rc 0
h_verdict_stdout
case_end
R2_N=0
r2s() { # LABEL TEXT key=json... -- --check on the fabricated out with status-1 edited: STATUS_INVALID naming TEXT
  local label="$1" text="$2"
  shift 2
  R2_N=$((R2_N + 1))
  OUT="$C/o-r2s-$R2_N"
  if [ -n "$SEL" ]; then cp -Rp "$C/o-base" "$OUT" && tl status-set "$OUT/status-1.json" "$@"; fi
  run_w -- --check "$OUT"
  case_begin "R2: --check on a status whose $label is FAIL STATUS_INVALID (exit 1, no traceback)"
  h_fail_codes STATUS_INVALID contains
  h_fail_line_has STATUS_INVALID "$text"
  case_end
}
r2s "nonce is a number" nonce nonce='123'
r2s "nonce is not 16 hex digits" nonce nonce='"foo"'
r2s "exit_code is false" exit_code exit_code='false'
r2s "signal is a string" signal signal='"KILL"'
r2s "cancelled is a string" cancelled cancelled='"no"'
r2s "model is a number" model model='123'
r2s "effort is xhigh" effort effort='"xhigh"'
r2s "max_tokens is -1" max_tokens max_tokens='-1'
r2s "max_tokens is past the cap" max_tokens max_tokens='393217'
r2s "max_tokens is true" max_tokens max_tokens='true'
r2s "model is not a model id" model model='"Not A Model"'
r2x() { # LABEL "CODES" key=json... -- --check on the fabricated out with status-1 edited: exactly CODES
  local label="$1" codes="$2"
  shift 2
  R2_N=$((R2_N + 1))
  OUT="$C/o-r2s-$R2_N"
  if [ -n "$SEL" ]; then cp -Rp "$C/o-base" "$OUT" && tl status-set "$OUT/status-1.json" "$@"; fi
  run_w -- --check "$OUT"
  case_begin "R2: --check on a status whose $label fails exactly $codes"
  h_fail_codes "$codes" exact
  case_end
}
# validate's own exit check does not lean on status_problem; a nonce that is no 16 hex digits
# never goes into the VERDICT regex (here it is a regex that would match any nonce).
r2x "exit_code is false" "DSH_EXIT_NONZERO STATUS_INVALID" exit_code='false'
r2x "nonce is a regex" "STATUS_INVALID VERDICT_MISSING" nonce='"[0-9a-f]{16}"'

new_case "R2 stream bytes"
make_repo "$REPO"
fab_out "$C/o-null" ok "$REPO" read="$REPO/sentinel.txt" cwd="$REPO"
fab_out "$C/o-utf" ok "$REPO" read="$REPO/sentinel.txt" cwd="$REPO"
R2_EDIT_OK=1
if [ -n "$SEL" ]; then
  "$PY" -I - "$C/o-null/run-1.jsonl" "$C/o-utf/run-1.jsonl" <<'PYEOF' || R2_EDIT_OK=""
import json, sys
null_p, utf_p = sys.argv[1], sys.argv[2]
out = []
for line in open(null_p, encoding="utf-8").read().splitlines():
    e = json.loads(line)
    if e.get("type") == "tool_result":
        e["result"] = None
    out.append(json.dumps(e))
open(null_p, "w", encoding="utf-8").write("\n".join(out) + "\n")
data = open(utf_p, "rb").read()
lines = data.split(b"\n")
hit = 0
for i, ln in enumerate(lines):
    if b'"final"' in ln:
        for pat in (b'"text": "', b'"text":"'):
            if pat in ln:
                lines[i] = ln.replace(pat, pat + b"\xff", 1)
                hit += 1
                break
if hit != 1:
    sys.exit(f"no final text to corrupt (hits {hit})")
open(utf_p, "wb").write(b"\n".join(lines))
PYEOF
fi
OUT="$C/o-null"
run_w -- --check "$OUT"
case_begin "R2: a completed read whose result is null is no read (REPO_NOT_READ)"
if [ -n "$R2_EDIT_OK" ]; then c_ok; else c_bad "the stream edit failed"; fi
h_fail_codes REPO_NOT_READ exact
case_end
OUT="$C/o-utf"
run_w -- --check "$OUT"
case_begin "R2: a byte that is not UTF-8 in the stream is STREAM_NOT_JSON, never a repaired answer"
if [ -n "$R2_EDIT_OK" ]; then c_ok; else c_bad "the stream edit failed"; fi
h_fail_codes STREAM_NOT_JSON exact
h_fail_line_has STREAM_NOT_JSON "not valid UTF-8"
case_end

new_case "R2 blank result"
make_repo "$REPO"
fab_out "$C/o-blank" ok "$REPO" read="$REPO/sentinel.txt" cwd="$REPO"
R2B_OK=1
if [ -n "$SEL" ]; then
  "$PY" -I - "$C/o-blank/run-1.jsonl" <<'PYEOF' || R2B_OK=""
import json, sys
p = sys.argv[1]
out, hit = [], 0
for line in open(p, encoding="utf-8").read().splitlines():
    e = json.loads(line)
    if e.get("type") == "tool_result":
        e["result"] = " \n "
        hit += 1
    out.append(json.dumps(e))
if not hit:
    sys.exit("no tool_result to blank")
open(p, "w", encoding="utf-8").write("\n".join(out) + "\n")
PYEOF
fi
OUT="$C/o-blank"
run_w -- --check "$OUT"
case_begin "R2: a completed read whose result is blank (whitespace only) is no read (REPO_NOT_READ)"
if [ -n "$R2B_OK" ]; then c_ok; else c_bad "the stream edit failed"; fi
h_fail_codes REPO_NOT_READ exact
case_end

new_case "R2 continue keeps the model"
make_repo "$REPO"
make_dsh "$DSH" ok sid=session-r2k read="$REPO/sentinel.txt"
wr --repo "$REPO" --model deepseek-v4-pro --effort high --max-tokens 1000 "$PROMPT"
A1_RC=$RC
rm -f "$OUT"/home/stub-record-*.json
run_w -- --continue "$OUT" --dsh-dir "$DSH" "$PROMPT"
case_begin "R2: --continue runs attempt 2 with attempt 1's model, effort and max_tokens"
if [ "$A1_RC" = 0 ]; then c_ok; else c_bad "control: attempt 1 exit $A1_RC"; fi
h_pass
c_tl "status-2" status-check "$OUT/status-2.json" model='"deepseek-v4-pro"' effort='"high"' max_tokens=1000
case_end

# Round 3 #10: a key is letters, digits, '.', '_' and '-' only (DeepSeek's are sk- and hex), so
# no escaped form of it can exist. A quote, a backslash, a space or a '+' is KEY_INVALID, named by
# length and positions only.
new_case "R2 key scrub forms"
R2KEY='FAKE"a\b c+d-0123456789'
make_dsh "$DSH" leak_key denied="/x/{KEY}/f"
run_w KEY="$R2KEY" -- --dsh-dir "$DSH" --out "$OUT" "$PROMPT"
case_begin "R2: a key holding a quote, a backslash, a space or a '+' is KEY_INVALID by length and positions; its value is printed nowhere and dsh never starts"
h_setup KEY_INVALID
h_err_line_has KEY_INVALID "length 23, bad positions [4, 6, 8, 10]"
h_text_lacks "stderr" "0123456789" "$STDERR"
h_text_lacks "stdout" "0123456789" "$STDOUT"
h_no_stub "$OUT" "$C"
case_end

# Unit cases (the wrapper loaded as a module; CI_UNIT_PY modes).
new_case "R2u canon: F_GETPATH answering another name or a relative path keeps the path as given"
mkdir -p "$C/cihome"
ci_unit canon "$C/cihome"
new_case "R2u node_roots: Homebrew and the account home's version managers, nothing else through PATH"
mkdir -p "$C/cihome"
ci_unit roots "$C/cihome"
new_case "R2u in_secret_dir: a file in the realpath of a symlinked ~/.aws"
mkdir -p "$C/cihome"
ci_unit secret "$C/cihome"
new_case "R2u doctor: a --dump-config past its limit or cancelled never composes cleanly"
mkdir -p "$C/cihome"
ci_unit doctor "$C/cihome"

new_case "R2 relative session cwd"
make_repo "$REPO"
fab_out "$C/o-rel" ok "$REPO" read=sentinel.txt cwd=.
OUT="$C/o-rel"
run_w CWD="$REPO" -- --check "$OUT"
case_begin "R2: a session cwd that is not absolute is ignored: a relative read is no read, even run from inside the repo"
h_fail_codes "REPO_NOT_READ SESSION_INVALID" exact
case_end

new_case "R2 earlier PASS attempt revalidated"
h12_two ok
P_RC=$RC
[ -z "$SEL" ] || printf 'dsh: [/x/run-1.patch.yml] patch: entry "tool-x" not found\n' >> "$OUT/err-1.txt"
run_w -- --check "$OUT" --attempt 2
case_begin "R2: attempt 1's reads stop counting once its files fail (a composition warning in err-1.txt) though status-1 says PASS"
if [ "$P_RC" = 0 ]; then c_ok; else c_bad "control: attempt 2 exit $P_RC before the edit"; fi
h_fail_codes REPO_NOT_READ exact
case_end

# prior_reads re-validates attempt k WITH the reads of the attempts before it. Attempt 2 expects
# the file only attempt 1 read and reads src/b.txt itself; attempt 3 expects src/b.txt and reads
# nothing: it passes only if attempt 2, which passes only on attempt 1's read, counts.
new_case "R2 three-attempt chain"
make_repo "$REPO"
printf 'b\n' > "$REPO/src/b.txt"
make_dsh "$DSH" ok sid=session-h12 read="$REPO/src/a.txt"
wr --repo "$REPO" "$PROMPT"
A1_RC=$RC
rm -f "$OUT"/home/stub-record-*.json
set_scenario ok sid=session-h12 read="$REPO/src/b.txt"
run_w -- --continue "$OUT" --dsh-dir "$DSH" --expect-read "$REPO/src/a.txt" "$PROMPT"
A2_RC=$RC
rm -f "$OUT"/home/stub-record-*.json
set_scenario ok sid=session-h12
run_w -- --continue "$OUT" --dsh-dir "$DSH" --expect-read "$REPO/src/b.txt" "$PROMPT"
case_begin "R2: attempt 3 counts attempt 2's read, which counts only through attempt 1's (prior reads chain)"
if [ "$A1_RC" = 0 ]; then c_ok; else c_bad "attempt 1 exit $A1_RC"; fi
if [ "$A2_RC" = 0 ]; then c_ok; else c_bad "attempt 2 exit $A2_RC"; fi
h_pass
h_status 3
h_check_agrees
case_end

# A NUL in the session cwd drops it like a relative one; joined to a read, it would reach
# os.stat() in canon() and raise ValueError. The fixture writes the JSON escape for U+0000.
new_case "R2 session cwd holding NUL"
make_repo "$REPO"
fab_out "$C/o-nul" ok "$REPO" read=sentinel.txt cwd=/x/NULCWD
[ -z "$SEL" ] || perl -pi -e 's{/x/NULCWD}{/x/\x5cu0000}g' "$C/o-nul/run-1.jsonl"
OUT="$C/o-nul"
run_w CWD="$REPO" -- --check "$OUT"
case_begin "R2: a session cwd holding NUL is ignored: a relative read is no read (REPO_NOT_READ), never an internal error"
if [ -z "$SEL" ] || ! grep -qF NULCWD "$OUT/run-1.jsonl"; then c_ok; else c_bad "fixture: the cwd placeholder was not replaced"; fi
h_fail_codes "REPO_NOT_READ SESSION_INVALID" exact
h_no_traceback
case_end

# A relative "~/..." read is joined to the session cwd as written; expanded, it would name
# <HOME>/src/rN/sentinel.txt, the repo's sentinel and the --expect-read file.
new_case "R2 tilde read"
make_repo "$REPO"
fab_out "$C/o-tilde" ok "$REPO" read="~/src/r$CASE_N/sentinel.txt" cwd=/x
[ -z "$SEL" ] || tl status-set "$C/o-tilde/status-1.json" expect_read="[\"$REPO/sentinel.txt\"]"
OUT="$C/o-tilde"
run_w -- --check "$OUT"
case_begin "R2: a relative read of ~/<path> is joined to the session cwd, never expanded to HOME (EXPECTED_READ_MISSING)"
if [ "$FAKEHOME/src/r$CASE_N" = "$REPO" ]; then c_ok; else c_bad "fixture: <HOME>/src/r$CASE_N is not the repo"; fi
h_fail_codes "EXPECTED_READ_MISSING REPO_NOT_READ" exact
case_end

# check_dsh's walk refuses a dir it cannot list (its symlinks would go unchecked).
new_case "R2 unlistable dir in the dsh dir"
make_dsh "$DSH" ok
mkdir -p "$DSH/locked"
chmod 0311 "$DSH/locked"
wr "$PROMPT"
case_begin "setup: R2 a dir in the dsh dir that cannot be listed is DSH_DIR_UNSAFE (cannot list), never an internal error"
h_setup DSH_DIR_UNSAFE
h_stderr_has "cannot list"
h_no_stub "$OUT" "$C"
case_end
chmod 0755 "$DSH/locked" 2>/dev/null || true

# canon() opens only a dir or a regular file: an open of a FIFO, even O_NONBLOCK, releases a
# writer blocked on it. The writer stamps the moment its open returns; after the wrapper exits a
# control reader releases it, so the case never waits on a timeout. A stamp from before the
# wrapper exited means the wrapper opened the FIFO.
new_case "R2 FIFO repo"
make_dsh "$DSH" ok
FW=""
if [ -n "$SEL" ]; then
  mkfifo "$C/fifo"
  perl -MTime::HiRes=time -e 'open(my $m, ">", "$ARGV[1].ready") or die; close $m;
    open(my $f, ">", $ARGV[0]) or exit 3; my $t = time;
    open($m, ">", "$ARGV[1].tmp") or die; printf $m "%.6f\n", $t; close $m;
    rename("$ARGV[1].tmp", $ARGV[1]); sleep 30' "$C/fifo" "$C/released" &
  FW=$!
  i=0; while [ ! -e "$C/released.ready" ] && [ "$i" -lt 50 ]; do psleep 0.1; i=$((i + 1)); done
fi
wr --repo "$C/fifo" "$PROMPT"
T_EXIT="$(perl -MTime::HiRes=time -e 'printf "%.6f", time')"
if [ -n "$SEL" ]; then
  perl -e 'alarm 5; open(my $r, "<", $ARGV[0]) or exit 1' "$C/fifo"
  i=0; while [ ! -e "$C/released" ] && [ "$i" -lt 50 ]; do psleep 0.1; i=$((i + 1)); done
fi
case_begin "setup: R2 --repo naming a FIFO is REPO_NOT_DIR, and the wrapper never opens it (a writer blocked on it stays blocked)"
h_setup REPO_NOT_DIR
if [ -z "$SEL" ]; then c_ok
elif [ ! -s "$C/released" ]; then c_bad "fixture: the writer was never released (the control reader failed)"
elif perl -e 'exit($ARGV[0] > $ARGV[1] ? 0 : 1)' "$(cat "$C/released")" "$T_EXIT"; then c_ok
else c_bad "the wrapper opened the FIFO: the blocked writer was released at $(cat "$C/released"), before the wrapper exited at $T_EXIT"; fi
case_end
[ -z "$FW" ] || { kill "$FW" 2>/dev/null; wait "$FW" 2>/dev/null; }

new_case "R2 run_group limit"
RG_OUT=""
if [ -n "$SEL" ]; then
  # A deadline of its own: a run_group that never kills the group would wait on the sleeps.
  RG_OUT="$(perl -e 'alarm 60; exec @ARGV' /usr/bin/env -i HOME="$FAKEHOME" PATH=/usr/bin:/bin /usr/bin/python3 -I -B - "$BIN" <<'PYEOF' 2>&1
import importlib.machinery, importlib.util, os, sys, time
loader = importlib.machinery.SourceFileLoader("dsr", sys.argv[1])
spec = importlib.util.spec_from_loader("dsr", loader)
m = importlib.util.module_from_spec(spec)
loader.exec_module(m)
m.trap_signals()
procs = []
class P(m.subprocess.Popen):
    def __init__(self, *a, **k):
        super().__init__(*a, **k)
        procs.append(self)
m.subprocess.Popen = P
t = time.monotonic()
done, rc, so, se = m.run_group(["/bin/sh", "-c", "sleep 3071 & exec sleep 3072"], "/", {"PATH": "/usr/bin:/bin"}, 1)
print(f"done={done} secs={round(time.monotonic() - t)}")
try:
    os.waitpid(procs[0].pid, os.WNOHANG)
    print("reaped=no")
except ChildProcessError:
    print("reaped=yes")
PYEOF
)"
fi
case_begin "R2: run_group (the doctor's --dump-config runner) stops at its limit and kills the whole group"
if [ -z "$SEL" ]; then c_ok
elif [ "$(printf '%s\n' "$RG_OUT" | sed -n 1p)" = "done=False secs=1" ]; then c_ok
else c_bad "run_group: $(first_line "$RG_OUT")"; fi
if [ -n "$SEL" ] && pgrep -f 'sleep 307[12]' >/dev/null; then
  c_bad "a sleep of the group survived"; pkill -9 -f 'sleep 307[12]'
else
  c_ok
fi
case_end
case_begin "R2: run_group reaps the child it killed at its limit (no zombie left)"
if [ -z "$SEL" ]; then c_ok
elif [ "$(printf '%s\n' "$RG_OUT" | sed -n 2p)" = "reaped=yes" ] && [ "$(printf '%s\n' "$RG_OUT" | wc -l | tr -d ' ')" = 2 ]; then c_ok
else c_bad "run_group left its child unreaped: $(first_line "$RG_OUT")"; fi
case_end

# ==============================================================================================
echo "== R3: review round 3 (Codex gpt-6.1-sol xhigh, Antigravity gemini-4-argon high)"

# #1a: real() resolves .. after a symlink the way the kernel does (no abspath before realpath).
new_case "R3 repo through a symlink and dot-dot"
make_repo "$REPO"
mkdir -p "$FAKEHOME/.ssh/sub"
ln -s "$FAKEHOME/.ssh/sub" "$REPO/jump"
make_dsh "$DSH" ok read="$REPO/sentinel.txt"
wr --repo "$REPO/jump/.." "$PROMPT"
case_begin "setup: R3 --repo <repo>/jump/.. with jump -> ~/.ssh/sub is REPO_SECRET_OVERLAP (.. taken after the symlink, as the kernel does)"
if [ -z "$SEL" ] || [ "$(realp "$REPO/jump/..")" = "$FAKEHOME/.ssh" ]; then c_ok; else c_bad "fixture: $REPO/jump/.. resolves to $(realp "$REPO/jump/.."), not ~/.ssh"; fi
h_setup REPO_SECRET_OVERLAP
h_err_line_has REPO_SECRET_OVERLAP "$FAKEHOME/.ssh"
h_no_stub "$OUT" "$C"
case_end
rm -f "$REPO/jump"; rmdir "$FAKEHOME/.ssh/sub" 2>/dev/null

# #1b: a PROMPT_FILE whose path as given runs through a symlink the user owns is PROMPT_UNSAFE,
# and the message names that symlink. Root-owned system links (/tmp, /var) stay fine.
new_case "R3 prompt through a symlink and dot-dot into ssh"
R3R="$C/R"; mkdir -p "$R3R"
printf 'SSH-KEY-PROMPT-SENTINEL\n' > "$FAKEHOME/.ssh/id_ed25519"
ln -s "$FAKEHOME/.ssh" "$R3R/jump"
make_dsh "$DSH" ok
wr "$R3R/jump/../.ssh/id_ed25519"
case_begin "setup: R3 PROMPT_FILE <R>/jump/../.ssh/id_ed25519 (jump -> ~/.ssh) is PROMPT_UNSAFE naming the symlink <R>/jump"
if [ -z "$SEL" ] || [ "$(cat "$R3R/jump/../.ssh/id_ed25519" 2>/dev/null)" = SSH-KEY-PROMPT-SENTINEL ]; then c_ok; else c_bad "fixture: the path does not open the ~/.ssh file"; fi
h_setup PROMPT_UNSAFE
h_err_names_symlink PROMPT_UNSAFE "$R3R/jump"
h_no_stub "$OUT" "$C"
c_tl "the ssh file never reached <out>" grep-absent SSH-KEY-PROMPT-SENTINEL "$OUT"
case_end
rm -f "$FAKEHOME/.ssh/id_ed25519"

new_case "R3 prompt through a symlinked dir into HOME"
R3R="$C/R"; mkdir -p "$R3R"
printf 'NETRC-PROMPT-SENTINEL\n' > "$FAKEHOME/.netrc"
ln -s "$FAKEHOME" "$R3R/prompts"
make_dsh "$DSH" ok
wr "$R3R/prompts/.netrc"
case_begin "setup: R3 PROMPT_FILE <R>/prompts/.netrc (prompts -> HOME) is PROMPT_UNSAFE naming the symlink <R>/prompts"
h_setup PROMPT_UNSAFE
h_err_names_symlink PROMPT_UNSAFE "$R3R/prompts"
h_no_stub "$OUT" "$C"
c_tl "the .netrc never reached <out>" grep-absent NETRC-PROMPT-SENTINEL "$OUT"
case_end
rm -f "$FAKEHOME/.netrc"

new_case "R3 prompt through a symlinked dir to a harmless file"
mkdir -p "$OUTSIDE/r3p$CASE_N"
printf '%s' "$PROMPT_TEXT" > "$OUTSIDE/r3p$CASE_N/prompt.txt"
ln -s "$OUTSIDE/r3p$CASE_N" "$C/pdir"
make_dsh "$DSH" ok
wr "$C/pdir/prompt.txt"
case_begin "setup: R3 PROMPT_FILE through a user's symlinked dir is PROMPT_UNSAFE even when its target is harmless"
h_setup PROMPT_UNSAFE
h_err_names_symlink PROMPT_UNSAFE "$C/pdir"
h_no_stub "$OUT" "$C"
case_end

# Controls (green now and after the fix): the root-owned /tmp and /var links are not refused.
new_case "R3 control prompt under slash-tmp"
if [ -n "$SEL" ]; then
  R3_TMPDIR="$(mktemp -d /tmp/dsr-r3.XXXXXX)" || { echo "FATAL: mktemp -d /tmp/dsr-r3.XXXXXX failed"; exit 1; }
  printf '%s' "$PROMPT_TEXT" > "$R3_TMPDIR/prompt.txt"
fi
make_dsh "$DSH" ok
wr "${R3_TMPDIR:-/tmp/x}/prompt.txt"
case_begin "R3 control: a PROMPT_FILE under /tmp (a root-owned symlink to /private/tmp) is accepted: the run passes"
if [ -z "$SEL" ] || { [ -L /tmp ] && [ "$(stat -f %Su /tmp)" = root ]; }; then c_ok; else c_bad "fixture: /tmp is not a root-owned symlink here"; fi
h_pass
case_end
case "${R3_TMPDIR:-}" in /tmp/dsr-r3.?*) rm -rf "$R3_TMPDIR" ;; esac
R3_TMPDIR=""

new_case "R3 control prompt under slash-var"
R3V="/var${TMP_REAL#/private/var}/c/$CASE_N/prompt.txt"
make_dsh "$DSH" ok
wr "$R3V"
case_begin "R3 control: a PROMPT_FILE spelled through /var (a root-owned symlink to /private/var) is accepted: the run passes"
if [ -z "$SEL" ] || { [ -L /var ] && [ "$(stat -f %Su /var)" = root ] && [ "$R3V" -ef "$PROMPT" ] && [ "$R3V" != "$PROMPT" ]; }; then c_ok; else c_bad "fixture: $R3V is not the case's prompt through the /var link"; fi
h_pass
case_end

# #1c: after the open, the opened file's own path (F_GETPATH) is checked: a home's secret dir, a
# dotfile directly in a home, or a component matching the repo .env pattern (.env*, *.env).
r3_prompt_kind() { # NAME FILE PHRASE SENTINEL
  local name="$1" file="$2" phrase="$3" sent="$4"
  mkdir -p "$(dirname "$file")"
  printf '%s\n' "$sent" > "$file"
  make_dsh "$DSH" ok
  wr "$file"
  case_begin "setup: R3 $name is PROMPT_UNSAFE after the open (no symlink involved)"
  h_setup PROMPT_UNSAFE
  h_err_line_has PROMPT_UNSAFE "$phrase"
  h_err_line_has PROMPT_UNSAFE "$file"
  if printf '%s' "$STDERR" | grep "^deepseek-review: ERROR PROMPT_UNSAFE:" | grep -q symlink; then
    c_bad "the PROMPT_UNSAFE line blames a symlink: no symlink is involved"
  else
    c_ok
  fi
  h_no_stub "$OUT" "$C"
  c_tl "the file never reached <out>" grep-absent "$sent" "$OUT"
  case_end
}
new_case "R3 prompt is a dot-env file"
r3_prompt_kind "PROMPT_FILE <R>/.env" "$C/R/.env" ".env pattern" "ENV-PROMPT-SENTINEL"
new_case "R3 prompt is under a dot-env dir"
r3_prompt_kind "PROMPT_FILE <R>/.env.d/cred" "$C/R/.env.d/cred" ".env pattern" "ENVD-PROMPT-SENTINEL"
new_case "R3 prompt is a star-dot-env file"
r3_prompt_kind "PROMPT_FILE <R>/prod.env" "$C/R/prod.env" ".env pattern" "PRODENV-PROMPT-SENTINEL"
new_case "R3 prompt is a dotfile in HOME"
r3_prompt_kind "PROMPT_FILE <HOME>/.netrc" "$FAKEHOME/.netrc" "dotfile" "NETRC-DIRECT-SENTINEL"
rm -f "$FAKEHOME/.netrc"

# #2a: after dsh exits, every regular file under <out> has the key replaced, raw and JSON-escaped
# (dsh's session store, its logs and temp files included), and no symlink is followed. The key
# uses only [A-Za-z0-9._-]: round 3 #10 makes the wrapper refuse any other character (KEY_INVALID).
R3KEY="FAKE-r3.key_0123456789"
r3_scrub_case() { # NAME HOW(run|timeout|TERM) KIND CODES|PASS
  local name="$1" how="$2" kind="$3" codes="$4" sha0="" sha1="" f started=""
  new_case "R3 scrub after $name"
  printf 'outside copy %s\n' "$R3KEY" > "$C/outside-key.txt"
  sha0="$(shasum -a 256 < "$C/outside-key.txt")"
  make_dsh "$DSH" "$kind" plant_key=1 echo_key=1 link_out="$C/outside-key.txt"
  case "$how" in
    run) run_w KEY="$R3KEY" -- --dsh-dir "$DSH" --out "$OUT" "$PROMPT" ;;
    timeout) run_w KEY="$R3KEY" ALARM=40 -- --dsh-dir "$DSH" --out "$OUT" --timeout 3s "$PROMPT" ;;
    TERM)
      run_w_bg KEY="$R3KEY" ALARM=60 -- --dsh-dir "$DSH" --out "$OUT" --timeout 120 "$PROMPT"
      wait_stub 20 && started=1
      [ -n "$started" ] && kill -TERM "$BGPID" 2>/dev/null
      bg_wait 30
      ;;
  esac
  case_begin "R3: after $name, no file under <out> holds the key (dsh's sessions, logs and temp files too), and a symlink out of <out> is never followed"
  if [ "$how" = TERM ] && [ -n "$SEL" ] && [ -z "$started" ]; then c_bad "the stub never started, so no SIGTERM was sent"; fi
  if [ "$codes" = PASS ]; then h_rc 0; else h_fail_codes "$codes" contains; fi
  h_record
  for f in home/sessions/x.jsonl home/logs/startup-x.log tmp/dsh-x/cache.txt; do
    if [ -z "$SEL" ] || { [ -f "$OUT/$f" ] && [ ! -L "$OUT/$f" ]; }; then c_ok; else c_bad "scenario not reproduced: the stub did not write $f"; fi
  done
  if [ -z "$SEL" ] || [ "$(readlink "$OUT/home/link-out" 2>/dev/null)" = "$C/outside-key.txt" ]; then c_ok; else c_bad "scenario not reproduced: no home/link-out -> outside-key.txt"; fi
  c_tl "key scrub" key-absent "$R3KEY" "$OUT"
  for f in home/sessions/x.jsonl home/logs/startup-x.log tmp/dsh-x/cache.txt; do
    if [ -z "$SEL" ] || grep -qF '[REDACTED]' "$OUT/$f" 2>/dev/null; then c_ok; else c_bad "$f lacks [REDACTED] (the key was not replaced in place)"; fi
  done
  sha1="$(shasum -a 256 < "$C/outside-key.txt" 2>/dev/null)"
  if [ "$sha0" = "$sha1" ] && [ -f "$C/outside-key.txt" ] && [ ! -L "$C/outside-key.txt" ]; then c_ok; else c_bad "the symlink's target outside <out> changed (the scrub followed the link)"; fi
  # A symlink is skipped, never tried (an O_NOFOLLOW open of it would fail with a WARNING).
  h_text_lacks "stderr" "WARNING: could not scrub" "$STDERR"
  case_end
}
r3_scrub_case "a PASS" run ok PASS
r3_scrub_case "a FAIL (dsh exit 1)" run exit1 DSH_EXIT_NONZERO
r3_scrub_case "dsh killed by SIGKILL" run killed DSH_EXIT_NONZERO
r3_scrub_case "a --timeout 3s" timeout hang CANCELLED
r3_scrub_case "SIGTERM to the wrapper" TERM hang CANCELLED

# #2b: --continue scrubs what an earlier attempt left under <out> (a wrapper SIGKILLed before its
# scrub leaves the key there) BEFORE it starts dsh.
new_case "R3 continue scrubs before dsh starts"
make_dsh "$DSH" ok sid=session-r3
wr "$PROMPT"
A1_RC=$RC
R3_FIX=""
if [ -n "$SEL" ]; then
  mkdir -p "$OUT/home/logs"
  printf 'startup failed: auth header %s\n' "$FAKEKEY" > "$OUT/home/logs/startup-1.log"
  grep -qF "$FAKEKEY" "$OUT/home/logs/startup-1.log" && R3_FIX=1
fi
rm -f "$OUT"/home/stub-record-*.json
set_scenario ok sid=session-r3 key_scan=1
run_w -- --continue "$OUT" --dsh-dir "$DSH" "$PROMPT"
case_begin "R3: --continue scrubs the key attempt 1 left under <out> before it starts dsh: attempt 2's dsh finds none at startup"
if [ "$A1_RC" = 0 ] || [ -z "$SEL" ]; then c_ok; else c_bad "control: attempt 1 exit $A1_RC"; fi
if [ -n "$R3_FIX" ] || [ -z "$SEL" ]; then c_ok; else c_bad "fixture: home/logs/startup-1.log does not hold the key"; fi
h_pass
if [ -z "$SEL" ] || { [ -n "$REC" ] && tl rec "$REC" key_scan.seen | grep -qF "$OUT/home/logs/startup-1.log"; }; then c_ok; else c_bad "the stub's startup scan never saw home/logs/startup-1.log"; fi
h_rec_eq "dsh found the key at startup" key_scan.hits '[]'
if [ -z "$SEL" ] || grep -qF '[REDACTED]' "$OUT/home/logs/startup-1.log" 2>/dev/null; then c_ok; else c_bad "home/logs/startup-1.log lacks [REDACTED] after attempt 2"; fi
case_end

# ==============================================================================================
# R3b: one case per guard of the round-3 fix (wrapper b1b51970), each the only case its mutant
# in mutants.py (W113 on) turns red.
R3S200="$(printf 'd%.0s' $(seq 200))"

# #1 the prompt file: a path the helper cannot lstat (longer than PATH_MAX under a deep cwd) is
# refused, never taken as "no symlink". bash cannot cd to a path over 1024 bytes, and the kernel
# expands a symlink's target plus the rest of the path in one 1024-byte buffer, so the run enters
# the deep cwd through a chain of one-letter links (l -> the next 200-byte dir, relative), each
# with a short rest; getcwd() is still the long real path.
new_case "R3b prompt beyond PATH_MAX through a link"
R3CWD="$C/l/l/l/l/l/l"
if [ -n "$SEL" ]; then
  mkdir -p "$C/tgt"
  printf 'DEEP-LINK-SENTINEL\n' > "$C/tgt/p.txt"
  "$PY" -I -c 'import os, sys
os.chdir(sys.argv[1])
for i in range(6):
    os.makedirs(sys.argv[2], exist_ok=True)
    os.symlink(sys.argv[2], "l")
    os.chdir(sys.argv[2])
os.symlink(sys.argv[3], "lnk")' "$C" "$R3S200" "$C/tgt" || { echo "FATAL: cannot build the deep dirs"; exit 1; }
fi
make_dsh "$DSH" ok
run_w CWD="$R3CWD" -- --dsh-dir "$DSH" --out "$OUT" lnk/p.txt
case_begin "setup: R3 PROMPT_FILE lnk/p.txt under a cwd longer than PATH_MAX (lnk a symlink) is PROMPT_UNSAFE: its path cannot be checked"
R3LEN="$( [ -z "$SEL" ] || (cd "$R3CWD" && "$PY" -I -c 'import os; print(len(os.getcwd() + "/lnk/p.txt"))') )"
if [ -z "$SEL" ] || [ "${R3LEN:-0}" -gt 1024 ]; then c_ok; else c_bad "fixture: the prompt's absolute path is ${R3LEN:-?} bytes, not over 1024"; fi
h_setup PROMPT_UNSAFE
h_err_line_has PROMPT_UNSAFE "cannot check the prompt file's path"
if printf '%s' "$STDERR" | grep "^deepseek-review: ERROR PROMPT_UNSAFE:" | grep -q symlink; then
  c_bad "the PROMPT_UNSAFE line blames a symlink: the refusal is that the path cannot be checked"
else
  c_ok
fi
h_no_stub "$OUT" "$C"
c_tl "the prompt never reached <out>" grep-absent DEEP-LINK-SENTINEL "$OUT"
case_end

# The F_GETPATH-failed branch: a cwd under 1024 bytes (every dir component checks) and a long
# last component (the helper skips it), so the opened file's path is over 1024 bytes.
new_case "R3b prompt whose opened path F_GETPATH cannot give"
R3FD="$C/fg"
while [ "${#R3FD}" -lt 780 ]; do R3FD="$R3FD/$R3S200"; done
R3FN="$(printf 'p%.0s' $(seq $((1030 - ${#R3FD} - 1))))"
if [ -n "$SEL" ]; then
  mkdir -p "$R3FD"
  (cd "$R3FD" && printf 'FGP-SENTINEL\n' > "$R3FN") || { echo "FATAL: cannot write the long-named prompt"; exit 1; }
fi
make_dsh "$DSH" ok
run_w CWD="$R3FD" -- --dsh-dir "$DSH" --out "$OUT" "$R3FN"
case_begin "setup: R3 a PROMPT_FILE whose opened path is over 1024 bytes (F_GETPATH fails) is PROMPT_UNSAFE: it cannot be located"
if [ -z "$SEL" ] || { [ "${#R3FD}" -lt 1024 ] && [ $(( ${#R3FD} + 1 + ${#R3FN} )) -gt 1024 ] && [ "${#R3FN}" -le 255 ]; }; then c_ok; else c_bad "fixture: cwd ${#R3FD}, name ${#R3FN} bytes"; fi
h_setup PROMPT_UNSAFE
h_err_line_has PROMPT_UNSAFE "cannot be located (F_GETPATH failed)"
h_no_stub "$OUT" "$C"
c_tl "the prompt never reached <out>" grep-absent FGP-SENTINEL "$OUT"
case_end

# prompt_target_problem judges the opened file: a relative name in ~/.ssh resolves into it.
new_case "R3b prompt named relative to a cwd in ssh"
mkdir -p "$FAKEHOME/.ssh"
printf 'REL-SSH-SENTINEL\n' > "$FAKEHOME/.ssh/id_r3b"
make_dsh "$DSH" ok
run_w CWD="$FAKEHOME/.ssh" -- --dsh-dir "$DSH" --out "$OUT" id_r3b
case_begin "setup: R3 PROMPT_FILE id_r3b run from ~/.ssh is PROMPT_UNSAFE (the opened file resolves into the secret dir)"
h_setup PROMPT_UNSAFE
h_err_line_has PROMPT_UNSAFE "resolves into"
h_no_stub "$OUT" "$C"
c_tl "the ssh file never reached <out>" grep-absent REL-SSH-SENTINEL "$OUT"
case_end
rm -f "$FAKEHOME/.ssh/id_r3b"

new_case "R3b prompt is an upper-case dot-env file"
r3_prompt_kind "PROMPT_FILE <R>/.ENV (the pattern ignores case)" "$C/R/.ENV" ".env pattern" "UPPER-ENV-SENTINEL"

# Controls: the dotfile rule needs both halves (a dotfile, directly in a home).
new_case "R3b control plain file directly in HOME"
printf '%s' "$PROMPT_TEXT" > "$FAKEHOME/r3b-plain-prompt.txt"
make_dsh "$DSH" ok
wr "$FAKEHOME/r3b-plain-prompt.txt"
case_begin "R3 control: a PROMPT_FILE directly in HOME that is not a dotfile is accepted: the run passes"
h_pass
case_end
rm -f "$FAKEHOME/r3b-plain-prompt.txt"

new_case "R3b control dotfile outside every home"
mkdir -p "$C/R"
printf '%s' "$PROMPT_TEXT" > "$C/R/.review-prompt"
make_dsh "$DSH" ok
wr "$C/R/.review-prompt"
case_begin "R3 control: a dotfile PROMPT_FILE not directly in a home (<R>/.review-prompt) is accepted: the run passes"
h_pass
case_end

# #1 --node and --out keep "link/.." as the kernel reads it (as_given, no abspath).
new_case "R3b node through a symlink and dot-dot"
if [ -n "$SEL" ]; then
  copy_node_tree "$C/np"
  mkdir -p "$C/np/sub" "$C/d"
  ln -s "$C/np/sub" "$C/d/link"
fi
make_dsh "$DSH" ok
wr --node "$C/d/link/../bin/node" "$PROMPT"
case_begin "R3: --node <d>/link/../bin/node (link -> <np>/sub) is <np>/bin/node, as the kernel opens it: the run passes"
if [ -z "$SEL" ] || { [ -x "$C/d/link/../bin/node" ] && [ ! -e "$C/d/bin/node" ]; }; then c_ok; else c_bad "fixture: the path does not reach <np>/bin/node only through the link"; fi
h_pass
case_end

new_case "R3b out through a symlink and dot-dot"
mkdir -p "$C/el/sub" "$C/d2"
ln -s "$C/el/sub" "$C/d2/link"
make_dsh "$DSH" ok
run_w -- --dsh-dir "$DSH" --out "$C/d2/link/../o" "$PROMPT"
OUT="$C/el/o"
case_begin "R3: --out <d2>/link/../o (link -> <el>/sub) is created at <el>/o, where the kernel puts it, never at <d2>/o"
h_pass
h_path_absent "$C/d2/o" "an out dir at the textual <d2>/o"
case_end

new_case "R3b out named dot"
make_dsh "$DSH" ok
wr_out() { run_w -- --dsh-dir "$DSH" --out "$1" "$PROMPT"; }
wr_out "$C/newdir/."
case_begin "setup: R3 --out <C>/newdir/. is OUT_EXISTS: it must name a new directory"
h_setup OUT_EXISTS
h_err_line_has OUT_EXISTS "must name a new directory"
h_no_stub "$OUT" "$C"
h_path_absent "$C/newdir" "a dir created for --out <C>/newdir/."
case_end
wr_out "$C/.."
case_begin "setup: R3 --out <C>/.. is OUT_EXISTS: it must name a new directory"
h_setup OUT_EXISTS
h_err_line_has OUT_EXISTS "must name a new directory"
case_end
wr_out "/"
case_begin "setup: R3 --out / is OUT_EXISTS: it must name a new directory"
h_setup OUT_EXISTS
h_err_line_has OUT_EXISTS "must name a new directory"
case_end

new_case "R3b out with a trailing slash"
make_dsh "$DSH" ok
run_w -- --dsh-dir "$DSH" --out "$C/newo/" "$PROMPT"
OUT="$C/newo"
case_begin "R3: --out <C>/newo/ (a trailing slash) names <C>/newo: the run passes there"
h_pass
case_end

# #2 the scrub: a file dsh left mode 0000 is made readable and scrubbed; a symlink to a dir
# outside <out> is never entered; no WARNING when every file could be scrubbed.
new_case "R3b scrub of a locked file and a linked dir"
mkdir -p "$C/outside-dir"
printf 'outside dir copy %s\n' "$R3KEY" > "$C/outside-dir/k.txt"
R3SHA0="$(shasum -a 256 < "$C/outside-dir/k.txt")"
make_dsh "$DSH" ok lock_key=1 link_dir="$C/outside-dir"
run_w KEY="$R3KEY" -- --dsh-dir "$DSH" --out "$OUT" "$PROMPT"
case_begin "R3: a key file dsh left mode 0000 is scrubbed, a symlink to a dir outside <out> is never entered, and no scrub WARNING is printed"
h_pass
if [ -z "$SEL" ] || { [ -n "$REC" ] && tl rec "$REC" planted.locked | grep -qF '"OK"'; }; then c_ok; else c_bad "scenario not reproduced: the stub did not make home/locked/k.log mode 0000"; fi
if [ -z "$SEL" ] || [ "$(readlink "$OUT/home/link-dir" 2>/dev/null)" = "$C/outside-dir" ]; then c_ok; else c_bad "scenario not reproduced: no home/link-dir -> outside-dir"; fi
c_tl "key scrub" key-absent "$R3KEY" "$OUT"
if [ -z "$SEL" ] || grep -qF '[REDACTED]' "$OUT/home/locked/k.log" 2>/dev/null; then c_ok; else c_bad "home/locked/k.log lacks [REDACTED]"; fi
if [ "$(shasum -a 256 < "$C/outside-dir/k.txt" 2>/dev/null)" = "$R3SHA0" ]; then c_ok; else c_bad "a file in the dir outside <out> changed (the scrub entered home/link-dir)"; fi
h_text_lacks "stderr" "WARNING: could not scrub" "$STDERR"
case_end

# r3b_cont_setup SID -- attempt 1 (PASS) in $OUT, then the stub records cleared for attempt 2.
r3b_cont_setup() {
  make_dsh "$DSH" ok sid="$1"
  wr "$PROMPT"
  A1_RC=$RC
  rm -f "$OUT"/home/stub-record-*.json
  set_scenario ok sid="$1"
}

# A file that cannot be replaced (uchg: rename over it is EPERM) is named in a WARNING, its temp
# copy is removed, and the run goes on.
new_case "R3b continue with an immutable key file"
r3b_cont_setup session-r3u
R3_FIX=""
if [ -n "$SEL" ]; then
  mkdir -p "$OUT/home/logs"
  printf 'startup failed: auth header %s\n' "$FAKEKEY" > "$OUT/home/logs/uchg.log"
  chflags uchg "$OUT/home/logs/uchg.log" && R3_FIX=1
fi
run_w -- --continue "$OUT" --dsh-dir "$DSH" "$PROMPT"
case_begin "R3: a key file under <out> that cannot be replaced is named in a scrub WARNING, leaves no .scrub-* temp file, and the run goes on"
if [ "$A1_RC" = 0 ] || [ -z "$SEL" ]; then c_ok; else c_bad "control: attempt 1 exit $A1_RC"; fi
if [ -n "$R3_FIX" ] || [ -z "$SEL" ]; then c_ok; else c_bad "fixture: chflags uchg failed"; fi
h_pass
if [ -z "$SEL" ] || grep -qF "$FAKEKEY" "$OUT/home/logs/uchg.log" 2>/dev/null; then c_ok; else c_bad "scenario not reproduced: uchg.log was rewritten"; fi
if [ -z "$SEL" ] || printf '%s' "$STDERR" | grep -qF "deepseek-review: WARNING: could not scrub $OUT/home/logs/uchg.log: "; then c_ok; else c_bad "no WARNING line names home/logs/uchg.log: $(printf '%s' "$STDERR" | grep -F WARNING | head -c 300)"; fi
R3N="$( [ -z "$SEL" ] || find "$OUT" -name '.scrub-*' | wc -l | tr -d ' ')"
if [ -z "$SEL" ] || [ "$R3N" = 0 ]; then c_ok; else c_bad "$R3N .scrub-* temp files left under <out>"; fi
case_end
[ -z "$SEL" ] || chflags -R nouchg "$C" 2>/dev/null

# A hard link from <out> to a file outside keeps the outside bytes: the scrub writes a new file.
new_case "R3b continue with a hard-linked key file"
r3b_cont_setup session-r3h
if [ -n "$SEL" ]; then
  printf 'outside hard link %s\n' "$FAKEKEY" > "$C/outside-hl.txt"
  ln "$C/outside-hl.txt" "$OUT/home/hl.txt"
fi
R3SHA0="$(shasum -a 256 < "$C/outside-hl.txt" 2>/dev/null)"
run_w -- --continue "$OUT" --dsh-dir "$DSH" "$PROMPT"
case_begin "R3: a file under <out> hard-linked to one outside is scrubbed as a new file: the outside file keeps its bytes"
if [ "$A1_RC" = 0 ] || [ -z "$SEL" ]; then c_ok; else c_bad "control: attempt 1 exit $A1_RC"; fi
h_pass
if [ -z "$SEL" ] || { grep -qF '[REDACTED]' "$OUT/home/hl.txt" && ! grep -qF "$FAKEKEY" "$OUT/home/hl.txt"; }; then c_ok; else c_bad "home/hl.txt was not scrubbed"; fi
if [ "$(shasum -a 256 < "$C/outside-hl.txt" 2>/dev/null)" = "$R3SHA0" ]; then c_ok; else c_bad "the outside file changed through the hard link"; fi
case_end

# #3 #4 #5 #6 stream shapes, through --check on fabricated outs (each next to its PASS control).
new_case "R3b stream shapes"
make_repo "$REPO"
for v in ok result_bad_callid dup_call dup_result plain_read dir_envelope envelope_tail error_envelope sid_int; do
  fab_out "$C/o-$v" "$v" "$REPO" read="$REPO/sentinel.txt" cwd="$REPO"
  OUT="$C/o-$v"
  run_w -- --check "$OUT"
  case "$v" in
    ok) want="" ;;
    result_bad_callid) want="CALL_ID_INVALID REPO_NOT_READ" ;;
    dup_call|dup_result) want="CALL_ID_INVALID" ;;
    sid_int) want="SESSION_INVALID" ;;
    *) want="REPO_NOT_READ" ;;
  esac
  if [ -z "$want" ]; then
    case_begin "R3 control: --check on a stream with one enveloped read of the sentinel passes"
    h_rc 0
    h_no_traceback
  else
    case_begin "R3: --check on a stream with $v is FAIL $want"
    h_fail_codes "$want" exact
  fi
  case_end
done
i=0
for s in "bad id!" "-lead" "$(printf 'a%.0s' $(seq 201))" "$(printf 'a%.0s' $(seq 200))" "A0._:-z9"; do
  i=$((i + 1))
  fab_out "$C/o-sid$i" sid "$REPO" read="$REPO/sentinel.txt" cwd="$REPO" sid="$s"
  OUT="$C/o-sid$i"
  run_w -- --check "$OUT"
  case "$i" in
    1) d="'bad id!'" ;; 2) d="'-lead'" ;; 3) d="201 characters long" ;; 4) d="200 characters long" ;; 5) d="'A0._:-z9'" ;;
  esac
  if [ "$i" -le 3 ]; then
    case_begin "R3: --check on a stream whose sessionId is $d is FAIL SESSION_INVALID"
    h_fail_codes SESSION_INVALID exact
  else
    case_begin "R3 control: --check on a stream whose sessionId is $d passes"
    h_rc 0
    h_no_traceback
  fi
  case_end
done

new_case "R3b continue on an invalid session id"
r3b_cont_setup "bad id!"
run_w -- --continue "$OUT" --dsh-dir "$DSH" "$PROMPT"
case_begin "R3: --continue after an attempt whose sessionId is invalid ('bad id!') is CONTINUE_NO_SESSION"
if [ "$A1_RC" = 1 ] || [ -z "$SEL" ]; then c_ok; else c_bad "control: attempt 1 exit $A1_RC, expected 1 (SESSION_INVALID)"; fi
h_setup CONTINUE_NO_SESSION
h_path_absent "$OUT/prompt-2.txt" "a 2nd attempt was started"
case_end

# #7 --continue carries every earlier attempt's --expect-read, refuses a malformed status-k and
# skips a missing one.
r3b_two() { # attempt 1 then attempt 2 (args after --continue OUT), both with the sentinel read
  make_repo "$REPO"
  make_dsh "$DSH" ok sid=session-r3s read="$REPO/sentinel.txt"
  wr --repo "$REPO" "$PROMPT"
  A1_RC=$RC
  rm -f "$OUT"/home/stub-record-*.json
  run_w -- --continue "$OUT" --dsh-dir "$DSH" "$@" "$PROMPT"
  A2_RC=$RC
  rm -f "$OUT"/home/stub-record-*.json
}
new_case "R3b continue carries attempt 2's expect-read"
r3b_two --expect-read "$REPO/src/a.txt"
run_w -- --continue "$OUT" --dsh-dir "$DSH" "$PROMPT"
case_begin "R3: --continue carries attempt 2's --expect-read into attempt 3: a follow-up that never reads it is EXPECTED_READ_MISSING"
if [ -z "$SEL" ] || { [ "$A1_RC" = 0 ] && [ "$A2_RC" = 1 ]; }; then c_ok; else c_bad "control: attempts 1 and 2 exit $A1_RC $A2_RC, expected 0 1"; fi
h_fail_codes EXPECTED_READ_MISSING exact
c_tl "status-3" status-check "$OUT/status-3.json" expect_read="[\"$REPO/src/a.txt\"]"
h_status 3
case_end

new_case "R3b continue with a malformed status-2"
r3b_two
[ -z "$SEL" ] || tl status-set "$OUT/status-2.json" expect_read=5
run_w -- --continue "$OUT" --dsh-dir "$DSH" "$PROMPT"
case_begin "setup: R3 --continue with status-2.json malformed (expect_read 5) is STATUS_INVALID naming status-2.json"
if [ -z "$SEL" ] || { [ "$A1_RC" = 0 ] && [ "$A2_RC" = 0 ]; }; then c_ok; else c_bad "control: attempts 1 and 2 exit $A1_RC $A2_RC"; fi
h_setup STATUS_INVALID
h_err_line_has STATUS_INVALID "status-2.json"
h_path_absent "$OUT/prompt-3.txt" "a 3rd attempt was started"
case_end

new_case "R3b continue with status-2 missing"
r3b_two
rm -f "$OUT/status-2.json"
run_w -- --continue "$OUT" --dsh-dir "$DSH" "$PROMPT"
case_begin "R3: --continue with status-2.json missing (attempt 2 killed before its record) skips it: attempt 3 runs and passes"
if [ -z "$SEL" ] || { [ "$A1_RC" = 0 ] && [ "$A2_RC" = 0 ]; }; then c_ok; else c_bad "control: attempts 1 and 2 exit $A1_RC $A2_RC"; fi
h_pass
h_status 3
case_end

# #8 the cancel checkpoint (a unit test: validate and report wrapped).
new_case "CI R3 cancel: a signal during validate, and one after the checkpoint"
mkdir -p "$C/cihome"
ci_unit cancel "$C/cihome"

# #9 a repo the user cannot list.
new_case "R3b repo not listable"
make_repo "$REPO"
make_dsh "$DSH" ok
[ -z "$SEL" ] || chmod 0311 "$REPO"
wr --repo "$REPO" "$PROMPT"
[ -z "$SEL" ] || chmod 0755 "$REPO"
case_begin "setup: R3 --repo with mode 0311 (not listable, not in a secret dir) is REPO_UNREADABLE"
h_setup REPO_UNREADABLE
h_err_line_has REPO_UNREADABLE "not a directory you can list"
h_no_stub "$OUT" "$C"
case_end

# #11 node_roots resolved.
new_case "CI R3 node_roots: realpath'd, and never / or a home"
mkdir -p "$C/cihome"
ci_unit roots3 "$C/cihome"

# #12 the out dir must not be in a dir the fence lets node read.
new_case "R3b out inside node's prefix"
mkdir -p "$C/np/bin" "$C/np/lib"
printf '#!/bin/sh\nexit 0\n' > "$C/np/bin/node"
chmod 755 "$C/np/bin/node"
make_dsh "$DSH" ok
run_w -- --dsh-dir "$DSH" --node "$C/np/bin/node" --out "$C/np/lib/o" "$PROMPT"
case_begin "setup: R3 --out <np>/lib/o with --node <np>/bin/node is OUT_OVERLAP (the fence lets node read its prefix)"
h_setup OUT_OVERLAP
h_err_line_has OUT_OVERLAP "which the fence lets node read"
h_no_stub "$OUT" "$C"
h_path_absent "$C/np/lib/o" "the out dir"
case_end

new_case "R3b continue with the out inside node's prefix"
mkdir -p "$C/np/bin"
printf '#!/bin/sh\nexit 0\n' > "$C/np/bin/node"
chmod 755 "$C/np/bin/node"
make_dsh "$DSH" ok
printf '{"type":"session","sessionId":"session-fab-1","cwd":"/x"}\n{"type":"final","text":"x"}\n' > "$C/fab-s.jsonl"
: > "$C/fab.err"
OUT="$C/np/o"
[ -z "$SEL" ] || tl fabricate "$OUT" "$C/fab-s.jsonl" "$C/fab.err" 0 0123456789abcdef -
[ -z "$SEL" ] || cp "$PLUGIN/dsh/review.patch.yml" "$OUT/review.patch.yml"
run_w -- --continue "$OUT" --dsh-dir "$DSH" --node "$C/np/bin/node" "$PROMPT"
case_begin "setup: R3 --continue on an out inside the prefix of --node is OUT_OVERLAP"
h_setup OUT_OVERLAP
h_err_line_has OUT_OVERLAP "which the fence lets node read"
h_path_absent "$OUT/prompt-2.txt" "a 2nd attempt was started"
case_end

# The auto out dir (under getconf DARWIN_USER_TEMP_DIR) with a node directly in that dir: its
# prefix holds the temp dir. Only this run's own out dir, named on stderr, is ever removed.
new_case "R3b auto out inside node's prefix"
# HOME is a fake one under /tmp: the harness's own fake home sits in the temp dir, which would
# make that dir "above a home" and node's dir NODE_DIR_UNSAFE before the out dir is made.
R3_TDNODE=""
if [ -n "$SEL" ]; then
  R3_TMPDIR="$(mktemp -d /tmp/dsr-r3.XXXXXX)" || { echo "FATAL: mktemp -d /tmp/dsr-r3.XXXXXX failed"; exit 1; }
  mkdir -p "$R3_TMPDIR/home"
  R3TD="$(realp "$(getconf DARWIN_USER_TEMP_DIR)")"
  R3_TDNODE="$R3TD/dsr-node-$RUNID"
  printf '#!/bin/sh\nexit 0\n' > "$R3_TDNODE"
  chmod 755 "$R3_TDNODE"
fi
make_dsh "$DSH" ok
run_w HOME="${R3_TMPDIR:-/x}/home" -- --dsh-dir "$DSH" --node "${R3_TDNODE:-/x/node}" "$PROMPT"
if [ -n "$SEL" ]; then
  rm -f "$R3_TDNODE"
  # A run that got past make_out (a mutant) left its out dir there: it is the one whose fence
  # names this case's dsh dir, a path unique to this run.
  for f in "$R3TD"/deepseek-review-*/fence-1.sb; do
    [ -f "$f" ] && grep -qF "(subpath \"$DSH\")" "$f" || continue
    d="$(dirname "$f")"
    case "$d" in "$R3TD"/deepseek-review-?*) chmod -R u+rwx "$d" 2>/dev/null; rm -rf "$d" ;; esac
  done
fi
case_begin "setup: R3 no --out with --node directly in the per-user temp dir is OUT_OVERLAP (the auto out dir would be in node's prefix)"
h_setup OUT_OVERLAP
h_err_line_has OUT_OVERLAP "which the fence lets node read"
h_text_lacks "stderr" "out: " "$STDERR"
case_end
R3_TDNODE=""
case "${R3_TMPDIR:-}" in /tmp/dsr-r3.?*) rm -rf "$R3_TMPDIR" ;; esac
R3_TMPDIR=""

# #13 limits and the error paths that must stay setup errors.
new_case "R3b timeout limit"
make_dsh "$DSH" ok
wr --timeout 25h "$PROMPT"
case_begin "usage: R3 --timeout 25h (over 24h) is a usage error"
h_rc 2
h_stderr_has "deepseek-review: usage error: --timeout must be at most 24h"
h_no_stub "$OUT" "$C"
case_end
wr --timeout 24h "$PROMPT"
case_begin "R3 control: --timeout 24h (the limit itself) is accepted: the run passes"
h_pass
case_end

new_case "R3b continue with a non-UTF-8 review patch"
make_dsh "$DSH" ok
printf '{"type":"session","sessionId":"session-fab-1","cwd":"/x"}\n{"type":"final","text":"x"}\n' > "$C/fab-s.jsonl"
: > "$C/fab.err"
[ -z "$SEL" ] || tl fabricate "$OUT" "$C/fab-s.jsonl" "$C/fab.err" 0 0123456789abcdef -
[ -z "$SEL" ] || { cp "$PLUGIN/dsh/review.patch.yml" "$OUT/review.patch.yml" && printf '# \377\376\n' >> "$OUT/review.patch.yml"; }
run_w -- --continue "$OUT" --dsh-dir "$DSH" "$PROMPT"
case_begin "setup: R3 --continue with <out>/review.patch.yml no longer UTF-8 is CONTINUE_PATCH_CHANGED"
h_setup CONTINUE_PATCH_CHANGED
h_path_absent "$OUT/prompt-2.txt" "a 2nd attempt was started"
case_end

new_case "R3b out under an unwritable parent"
mkdir -p "$C/ro"
make_dsh "$DSH" ok
[ -z "$SEL" ] || chmod 0500 "$C/ro"
run_w -- --dsh-dir "$DSH" --out "$C/ro/o" "$PROMPT"
[ -z "$SEL" ] || chmod 0700 "$C/ro"
case_begin "setup: R3 --out under a parent the user cannot write is OUT_NOT_CREATED"
h_setup OUT_NOT_CREATED
h_err_line_has OUT_NOT_CREATED "$C/ro/o"
h_no_stub "$OUT" "$C"
case_end

new_case "R3b install into an uncreatable dir"
make_npm "$C/np" 0
mkdir -p "$C/ro"
[ -z "$SEL" ] || chmod 0500 "$C/ro"
run_w -- --install --node "$C/np/bin/node" --dsh-dir "$C/ro/dsh-$PINNED"
[ -z "$SEL" ] || chmod 0700 "$C/ro"
case_begin "setup: R3 --install into a dir it cannot create is DSH_DIR_UNSAFE, and npm never runs"
h_setup DSH_DIR_UNSAFE
h_err_line_has DSH_DIR_UNSAFE "cannot create"
h_path_absent "$C/np/npm-argv" "npm's argv record"
case_end

# ==============================================================================================
echo "== real dsh $PINNED (DSH_REAL_DIR)"

REAL_CASES=("real: composed config (--dump-config)" "real: mock wire request shape" \
  "real: --check passes the mock run's out dir" "real: --check fails a max_tokens run" \
  "real: --check fails a refusal run" "META real: harness pipeline works with the repo patches" \
  "real: --doctor under the wrapper's own fence" "real: a headless turn under the wrapper's own fence" \
  "real: a read of a directory is a tool error (not a regular file) and is not a repo read")
if [ -z "${DSH_REAL_DIR:-}" ]; then
  for n in "${REAL_CASES[@]}"; do note_skip "$n: DSH_REAL_DIR unset"; done
elif [ ! -f "$DSH_REAL_DIR/node_modules/@deepseek-ai/dsh/lib/bin.js" ]; then
  for n in "${REAL_CASES[@]}"; do note_fail "$n: DSH_REAL_DIR has no node_modules/@deepseek-ai/dsh/lib/bin.js"; done
else
  RD="$(realp "$DSH_REAL_DIR")"
  RBIN="$RD/node_modules/@deepseek-ai/dsh/lib/bin.js"
  new_case "real"
  # This block drives real dsh directly (not through run_w), so a deselected one is skipped whole.
  if [ -z "$SEL" ]; then
    for n in "META real: harness pipeline works with the repo patches" "real: composed config (--dump-config)" \
      "real: mock wire request shape" "real: --check passes the mock run's out dir" \
      "real: --check fails a max_tokens run" "real: --check fails a refusal run" \
      "real: a read of a directory is a tool error (not a regular file) and is not a repo read"; do note_desel "$n"; done
  else
  R="$C"
  # Patches: from --print-invocation (the wrapper's own). The META variant uses the repo's
  # review.patch.yml plus the contract's run-1 content, to prove the pipeline itself works.
  run_w NOKEY -- --print-invocation --dsh-dir "$RD" --out "$R/o" "$PROMPT"
  printf '%s' "$STDOUT" > "$R/pinv.json"
  PINV_OK=""
  if [ "$RC" = 0 ] && "$PY" -I -c '
import json, sys
p = json.load(open(sys.argv[1]))["patches"]
for k in ("review.patch.yml", "run-1.patch.yml"):
    open(sys.argv[2] + "/" + k, "w").write(p[k]["content"])' "$R/pinv.json" "$R" 2>/dev/null; then
    PINV_OK=1
  fi
  mkdir -p "$R/ref"
  cp "$PLUGIN/dsh/review.patch.yml" "$R/ref/review.patch.yml"
  printf -- '- id: agent-default-model\n  config:\n    provider: deepseek-official\n    model: deepseek-flash\n- id: llm-deepseek\n  config:\n    baseURL: https://api.deepseek.com/anthropic\n    apiKeyEnv: DEEPSEEK_API_KEY\n    reasoningEffort: max\n    maxTokens: 393216\n' > "$R/ref/run-1.patch.yml"

  real_env() { # WORKDIR -> prints nothing; sets RENV
    mkdir -p "$1/home" "$1/tmp"
    RENV=(PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME="$1/home" DSH_HOME="$1/home" TMPDIR="$1/tmp"
      DSH_TELEMETRY_DISABLED=1 DSH_PERMISSION_MODE=read-only LANG=en_US.UTF-8)
  }
  dump_config() { # PATCHDIR WORKDIR
    real_env "$2"
    ( cd "$2" && exec perl -e 'alarm 60; exec @ARGV' /usr/bin/env -i "${RENV[@]}" \
        /usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' "$NODE_REAL" "$RBIN" \
        --profile headless --patch "$1/review.patch.yml" --patch "$1/run-1.patch.yml" --dump-config ) \
      >"$2/dump.yml" 2>"$2/dump.err" </dev/null
    DUMP_RC=$?
  }
  dump_check() { # PATCHDIR WORKDIR
    if [ "$DUMP_RC" = 0 ]; then c_ok; else c_bad "--dump-config exit $DUMP_RC: $(head -c 200 "$2/dump.err")"; fi
    if grep -qE 'not found|did not activate' "$2/dump.err"; then c_bad "composition warning: $(head -c 300 "$2/dump.err")"; else c_ok; fi
    c_tl "dump" dump-check "$2/dump.yml" "$1/review.patch.yml"
  }
  # mock_run SCEN PATCHDIR WORKDIR [READREL] -- real dsh headless against the loopback mock, which
  # asks for a read of <repo>/READREL (default sentinel.txt).
  mock_run() {
    local scen="$1" pd="$2" w="$3" rr="${4:-sentinel.txt}" port i
    mkdir -p "$w"
    MREPO_R="$w/repo"; make_repo "$MREPO_R"
    MSENT="SENTINEL-REAL-$(tl nonce)"
    printf '%s\n' "$MSENT" > "$MREPO_R/sentinel.txt"
    "$PY" -I "$FIX/mock-messages.py" "$w/port" "$w/requests.jsonl" "$scen" "$MREPO_R/$rr" "$MSENT" &
    MOCKPID=$!
    for i in $(seq 100); do [ -s "$w/port" ] && break; psleep 0.1; done
    port="$(cat "$w/port" 2>/dev/null)"
    sed "s/__PORT__/$port/" "$FIX/test-endpoint.patch.yml" > "$w/endpoint.patch.yml"
    MNONCE="$(tl nonce)"
    printf 'Read sentinel.txt in this repository and report it.\n\n---\nEnd your answer with exactly one final line, and nothing after it:\nVERDICT-%s: FINDINGS\nor\nVERDICT-%s: NO FINDINGS\n' \
      "$MNONCE" "$MNONCE" > "$w/prompt.txt"
    real_env "$w"
    ( cd "$MREPO_R" && exec perl -e 'alarm 120; exec @ARGV' /usr/bin/env -i "${RENV[@]}" DEEPSEEK_API_KEY=FAKE-mock-key \
        /usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network-outbound)(allow network-outbound (remote ip "localhost:*"))(allow network-outbound (remote unix-socket))' \
        "$NODE_REAL" "$RBIN" --profile headless --patch "$pd/review.patch.yml" --patch "$pd/run-1.patch.yml" \
        --patch "$w/endpoint.patch.yml" --json - ) <"$w/prompt.txt" >"$w/run.jsonl" 2>"$w/err.txt"
    MRC=$?
    kill "$MOCKPID" 2>/dev/null
    wait "$MOCKPID" 2>/dev/null
    tl fabricate "$w/out" "$w/run.jsonl" "$w/err.txt" "$MRC" "$MNONCE" "$MREPO_R"
  }

  # META: the pipeline with the repo patches, judged without the wrapper.
  dump_config "$R/ref" "$R/meta-dump"
  mock_run answer "$R/ref" "$R/meta-wire"
  case_begin "META real: harness pipeline works with the repo patches"
  dump_check "$R/ref" "$R/meta-dump"
  if [ "$MRC" = 0 ]; then c_ok; else c_bad "dsh exit $MRC: $(head -c 300 "$R/meta-wire/err.txt")"; fi
  c_tl "requests" requests-check "$R/meta-wire/requests.jsonl"
  if grep -q "\"type\":\"final\".*VERDICT-$MNONCE: NO FINDINGS" "$R/meta-wire/run.jsonl"; then c_ok; else c_bad "final lacks VERDICT-$MNONCE"; fi
  case_end

  # The --check cases judge a real dsh run; with no wrapper patches they use the reference ones
  # (the run's shape is the same), so --check itself is still what they test.
  PD="$R"
  PINV_WHY="--print-invocation gave no patches (exit $RC: $(first_line "$STDERR"))"
  [ -n "$PINV_OK" ] || PD="$R/ref"
  if [ -z "$PINV_OK" ]; then
    note_fail "real: composed config (--dump-config): $PINV_WHY"
  else
    dump_config "$R" "$R/dump"
    case_begin "real: composed config (--dump-config)"
    dump_check "$R" "$R/dump"
    case_end
  fi
  mock_run answer "$PD" "$R/wire"
  case_begin "real: mock wire request shape"
  [ -n "$PINV_OK" ] || c_bad "$PINV_WHY"
  if [ "$MRC" = 0 ]; then c_ok; else c_bad "dsh exit $MRC: $(head -c 300 "$R/wire/err.txt")"; fi
  if grep -qE 'not found|did not activate' "$R/wire/err.txt"; then c_bad "composition warning"; else c_ok; fi
  c_tl "requests" requests-check "$R/wire/requests.jsonl"
  case_end
  {
    OUT="$R/wire/out"
    run_w -- --check "$OUT"
    case_begin "real: --check passes the mock run's out dir"
    final_of_run() { "$PY" -I -c '
import json, sys
f = None
for l in open(sys.argv[1]):
    o = json.loads(l)
    if o.get("type") == "final": f = o["text"]
open(sys.argv[2], "w").write((f or "") + "\n")' "$1" "$2"; }
    final_of_run "$R/wire/run.jsonl" "$R/wire/expected"
    h_pass_stdout "$R/wire/expected"
    case_end
    mock_run max_tokens "$PD" "$R/maxtok"
    OUT="$R/maxtok/out"
    run_w -- --check "$OUT"
    case_begin "real: --check fails a max_tokens run"
    if grep -q '"kind":"max-tokens"' "$R/maxtok/run.jsonl"; then c_ok; else c_bad "real dsh did not report max-tokens"; fi
    h_fail_codes TURN_NOT_COMPLETED contains
    case_end
    mock_run refusal "$PD" "$R/refusal"
    OUT="$R/refusal/out"
    run_w -- --check "$OUT"
    case_begin "real: --check fails a refusal run"
    if grep -q 'MALFORMED_RESPONSE' "$R/refusal/run.jsonl"; then c_ok; else c_bad "real dsh did not report the refusal"; fi
    h_fail_codes TURN_NOT_COMPLETED contains
    case_end
    # Regression: the mock asks real dsh to read the directory src; dsh answers with a tool error,
    # which --check must not count as a repo read.
    mock_run answer_any "$PD" "$R/dirread" src
    OUT="$R/dirread/out"
    run_w -- --check "$OUT"
    case_begin "real: a read of a directory is a tool error (not a regular file) and is not a repo read"
    # dsh 0.2.1-rc.5 answers a directory read with status error, "...: not a regular file".
    if grep '"type":"tool_result"' "$R/dirread/run.jsonl" | grep '"status":"error"' | grep -q 'not a regular file'; then c_ok
    else c_bad "real dsh did not answer the directory read with an error tool_result: $(grep '"tool_result"' "$R/dirread/run.jsonl" | head -c 300)"; fi
    if grep -q "\"type\":\"final\".*VERDICT-$MNONCE: NO FINDINGS" "$R/dirread/run.jsonl"; then c_ok; else c_bad "the mock run did not end with VERDICT-$MNONCE"; fi
    h_fail_codes REPO_NOT_READ exact
    case_end
  }
  fi  # the "real" block

  # The doctor runs real dsh --version and --dump-config under the fence the wrapper writes
  # (no network call). The stub never reads its overlays the way real dsh must.
  new_case "real doctor"
  run_w -- --doctor --dsh-dir "$RD"
  case_begin "real: --doctor under the wrapper's own fence"
  h_rc 0
  h_no_traceback
  for want in "key: present (length 24)" "dsh: $RD version $PINNED (pinned $PINNED) OK" \
    "overlay: composes cleanly under the fence"; do
    if printf '%s\n' "$STDOUT" | grep -qxF -- "$want"; then c_ok; else c_bad "no stdout line '$want' — got: $(first_line "$STDOUT")"; fi
  done
  case_end

  # A full headless turn (read tool included) of real dsh under the wrapper's OWN fence-1.sb, run
  # exactly as status-1.json's argv says, with three test-only changes: the fence copy allows
  # the real dsh dir instead of the stub's and adds the loopback-only network rule of mock_run,
  # argv[4] is the real bin.js, and the loopback endpoint patch (under <out>/home, readable
  # inside the fence) comes before --json.
  new_case "real fenced turn"
  make_repo "$REPO"
  make_dsh "$DSH" ok read="$REPO/sentinel.txt"
  wr --repo "$REPO" "$PROMPT"
  STUB_RUN="exit $RC, $(first_line "$STDERR")"
  RSENT="SENTINEL-REAL-$(tl nonce)"
  printf '%s\n' "$RSENT" > "$REPO/sentinel.txt"
  case_begin "real: a headless turn under the wrapper's own fence"
  RT_READY=1
  for f in fence-1.sb review.patch.yml run-1.patch.yml status-1.json home tmp; do
    [ -e "$OUT/$f" ] || { c_bad "the wrapper left no $OUT/$f (stub run: $STUB_RUN)"; RT_READY=""; }
  done
  if [ -n "$RT_READY" ]; then
    # Test fence: exactly one stub-dsh subpath line swapped for the real dsh dir; network rule appended.
    if "$PY" -I -c '
import sys
src, dst, stub, realdir = sys.argv[1:5]
q = lambda p: "\"" + p.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
t = open(src).read()
old = "(allow file-read* (subpath %s))" % q(stub)
if t.count(old) != 1:
    sys.exit("stub dsh subpath line found %d times" % t.count(old))
t = t.replace(old, "(allow file-read* (subpath %s))" % q(realdir))
t += ("(deny network-outbound)(allow network-outbound (remote ip \"localhost:*\"))"
      "(allow network-outbound (remote unix-socket))\n")
open(dst, "w").write(t)' "$OUT/fence-1.sb" "$C/fence-real.sb" "$(realp "$DSH")" "$RD" 2>"$C/fence-real.err"; then
      c_ok
    else
      c_bad "test fence: $(cat "$C/fence-real.err")"
      RT_READY=""
    fi
  fi
  if [ -n "$RT_READY" ]; then
    # argv from status-1.json, NUL-separated, with the real bin.js and the endpoint patch.
    "$PY" -I "$FIX/mock-messages.py" "$C/port" "$C/requests.jsonl" answer "$REPO/sentinel.txt" "$RSENT" &
    MOCKPID=$!
    for _ in $(seq 100); do [ -s "$C/port" ] && break; psleep 0.1; done
    sed "s/__PORT__/$(cat "$C/port" 2>/dev/null)/" "$FIX/test-endpoint.patch.yml" > "$OUT/home/endpoint.patch.yml"
    if "$PY" -I -c '
import json, sys
st, fence, binjs, ep, stubbin, node, out = sys.argv[1:8]
a = json.load(open(st))["argv"]
want4 = stubbin
if a[:2] != ["/usr/bin/sandbox-exec", "-f"] or a[2] != out + "/fence-1.sb" or a[3] != node or a[4] != want4:
    sys.exit("status-1.json argv head unexpected: %r" % a[:5])
if "--json" not in a:
    sys.exit("status-1.json argv has no --json: %r" % a)
a[2], a[4] = fence, binjs
j = a.index("--json")
a[j:j] = ["--patch", ep]
sys.stdout.write("\0".join(a) + "\0")' "$OUT/status-1.json" "$C/fence-real.sb" "$RBIN" "$OUT/home/endpoint.patch.yml" \
      "$(realp "$DSH")/node_modules/@deepseek-ai/dsh/lib/bin.js" "$NODE_REAL" "$OUT" >"$C/rargv" 2>"$C/rargv.err"; then
      c_ok
    else
      c_bad "argv: $(cat "$C/rargv.err")"
      RT_READY=""
    fi
  fi
  if [ -n "$RT_READY" ]; then
    RARGV=()
    while IFS= read -r -d '' x; do RARGV+=("$x"); done <"$C/rargv"
    RNONCE="$(tl nonce)"
    printf 'Read sentinel.txt in this repository and report it.\n\n---\nEnd your answer with exactly one final line, and nothing after it:\nVERDICT-%s: FINDINGS\nor\nVERDICT-%s: NO FINDINGS\n' \
      "$RNONCE" "$RNONCE" > "$C/rprompt.txt"
    ( cd "$REPO" && exec perl -e 'alarm 120; exec @ARGV' /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        HOME="$OUT/home" DSH_HOME="$OUT/home" TMPDIR="$OUT/tmp" DSH_TELEMETRY_DISABLED=1 \
        DSH_PERMISSION_MODE=read-only LANG=en_US.UTF-8 DEEPSEEK_API_KEY=FAKE-mock-key "${RARGV[@]}" ) \
      <"$C/rprompt.txt" >"$C/rrun.jsonl" 2>"$C/rerr.txt"
    RRC=$?
    if [ "$RRC" = 0 ]; then c_ok; else c_bad "real dsh exit $RRC: $(head -c 400 "$C/rerr.txt" | tr '\n' '|')"; fi
    if grep -qE 'failed to read overlay|did not activate|not found' "$C/rerr.txt"; then
      c_bad "stderr: $(grep -m1 -E 'failed to read overlay|did not activate|not found' "$C/rerr.txt" | head -c 300)"
    else
      c_ok
    fi
    if [ -s "$C/requests.jsonl" ]; then c_tl "requests" requests-check "$C/requests.jsonl"; else c_bad "the mock received no request"; fi
    if grep -q "\"type\":\"final\".*VERDICT-$RNONCE: NO FINDINGS" "$C/rrun.jsonl"; then c_ok; else c_bad "final lacks VERDICT-$RNONCE"; fi
  fi
  [ -n "${MOCKPID:-}" ] && { kill "$MOCKPID" 2>/dev/null; wait "$MOCKPID" 2>/dev/null; MOCKPID=""; }
  case_end
fi

SEL=1
case_begin "META: node and its dylibs still have no hard links at the end of the run"
h_node_links
case_end

echo
[ -n "$DSR_ONLY" ] && echo "selection: DSR_ONLY='$DSR_ONLY': $desel cases deselected (not counted below)"
echo "$pass passed, $fail failed, $skip skipped"
[ "$fail" -eq 0 ]
