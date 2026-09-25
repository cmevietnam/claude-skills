#!/usr/bin/env bash
# Tests for agent-health.sh. No agents, no network — fixtures only.
#
# The property that matters most is the last one: the script must never print
# transcript content. A diagnostic that leaks the thing it is diagnosing is worse
# than no diagnostic.
set -uo pipefail
dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
S="$dir/agent-health.sh"
pass=0 fail=0
ok(){ pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad(){ fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/test-agent-health.XXXXXX"); trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/tasks"; export OPGATE_TASKS_DIR="$tmp/tasks"

SECRET='ghp_zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz'
mk(){ # <id> <age-seconds>
  local f="$tmp/tasks/$1.output"
  printf '{"type":"assistant","text":"tok=%s"}\n{"type":"user"}\n' "$SECRET" > "$f"
  touch -t "$(date -v-"$2"S +%Y%m%d%H%M.%S 2>/dev/null || date +%Y%m%d%H%M.%S)" "$f"
  printf '%s' "$f"
}

echo "state classification"
f=$(mk fresh 5)
out=$(STALL_AFTER=180 IDLE_AFTER=1800 bash "$S" fresh)
case "$out" in WORKING*) ok "freshly written file -> WORKING" ;; *) bad "fresh -> $out" ;; esac

f=$(mk stale 600)
out=$(STALL_AFTER=180 IDLE_AFTER=1800 bash "$S" stale)
case "$out" in "STALLED?"*|DEAD*) ok "moderately quiet -> STALLED?/DEAD" ;; *) bad "stale -> $out" ;; esac

# Past the IDLE threshold "a claude process is alive" says nothing: it is another
# agent. The harness already notified when the task finished, so a long silence almost
# certainly means it has ended, and advising "nudge it" here would be wrong advice.
f=$(mk ancient 7200)
out=$(STALL_AFTER=180 IDLE_AFTER=1800 bash "$S" ancient)
case "$out" in IDLE*) ok "very long silence -> IDLE, no nudge advised" ;; *) bad "ancient -> $out" ;; esac

# A finished background command leaves an exit line; that positive signal beats any
# inference from mtime.
fd="$tmp/tasks/finished.output"
printf 'output\n\n[exited with code 0]\n' > "$fd"
touch -t "$(date -v-9000S +%Y%m%d%H%M.%S 2>/dev/null || date +%Y%m%d%H%M.%S)" "$fd"
out=$(STALL_AFTER=180 IDLE_AFTER=1800 bash "$S" finished)
case "$out" in DONE*) ok "exit line present -> DONE even though the file is old" ;; *) bad "finished -> $out" ;; esac

echo "the record count must not be printed twice"
# `grep -c` prints 0 AND exits 1 on no match, so `|| echo 0` used to print the count twice.
n=$(printf '%s' "$out" | grep -oE '[0-9]+ records' | wc -l | tr -d ' ')
[[ "$n" == 1 ]] && ok "exactly one 'records' field" || bad "$n 'records' fields"
lines=$(printf '%s' "$out" | wc -l | tr -d ' ')
[[ "$lines" == 0 ]] && ok "the verdict fits on one line" || bad "the verdict spilled over $((lines+1)) lines"

echo "a task is accepted by id and by path"
out=$(STALL_AFTER=180 IDLE_AFTER=1800 bash "$S" "$tmp/tasks/fresh.output")
case "$out" in WORKING*) ok "full path" ;; *) bad "path -> $out" ;; esac
bash "$S" does-not-exist >/dev/null 2>&1 && bad "an unknown id must fail" || ok "unknown id -> error"

echo "--list lists every task"
out=$(STALL_AFTER=180 IDLE_AFTER=1800 bash "$S" --list)
n=$(printf '%s' "$out" | grep -cE 'WORKING|STALLED|DEAD|IDLE|DONE')
[[ "$n" == 4 ]] && ok "all 4 tasks listed" || bad "--list saw $n tasks (want 4)"

echo "transcript content must NEVER be printed"
all=$( { STALL_AFTER=180 IDLE_AFTER=1800 bash "$S" --list; STALL_AFTER=180 bash "$S" fresh; } 2>&1 )
case "$all" in
  *"$SECRET"*) bad "leaked transcript content" ;;
  *) ok "prints only numbers and record types" ;;
esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
