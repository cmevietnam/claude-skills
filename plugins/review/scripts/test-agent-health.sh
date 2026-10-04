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

echo "age is read from the transcript, not from the .output symlink"
# A real .output is a symlink created when the task starts. Without stat -L its mtime
# never moves, so a reviewer still writing would be called STALLED after 3 minutes,
# and one that had stopped long ago could look fresh. Both directions are pinned.
mkdir -p "$tmp/links"
ago(){ date -v-"$1"S +%Y%m%d%H%M.%S; }
lt="$tmp/links/live.jsonl"; printf '{"type":"assistant"}\n' > "$lt"
ln -s "$lt" "$tmp/links/live.output"; touch -h -t "$(ago 600)" "$tmp/links/live.output"
out=$(STALL_AFTER=180 IDLE_AFTER=1800 bash "$S" "$tmp/links/live.output")
case "$out" in WORKING*) ok "old symlink, transcript still growing -> WORKING" ;; *) bad "live via symlink -> $out" ;; esac
qt="$tmp/links/quiet.jsonl"; printf '{"type":"assistant"}\n' > "$qt"; touch -t "$(ago 600)" "$qt"
ln -s "$qt" "$tmp/links/quiet.output"
out=$(STALL_AFTER=180 IDLE_AFTER=1800 bash "$S" "$tmp/links/quiet.output")
case "$out" in "STALLED?"*|DEAD*) ok "fresh symlink, transcript quiet 600s -> STALLED?/DEAD" ;; *) bad "quiet via symlink -> $out" ;; esac

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

echo "--model reports the model that actually answered"
# Kept outside tasks/ so --list still sees exactly the 4 tasks above. A real .output
# is a symlink to the transcript, so the fixtures are reached the same way.
mkdir -p "$tmp/transcripts"
mt(){ # <id> <record>... -> symlinked <id>.output, one JSONL record per argument
  local t="$tmp/transcripts/$1.jsonl"; shift
  printf '%s\n' "$@" > "$t"
  printf '%s' "$t"
}
SON='{"type":"assistant","message":{"model":"claude-sonnet-5-5","content":"tok='"$SECRET"'"}}'
OPU='{"type":"assistant","message":{"model":"claude-opus-5-5"}}'
SYN='{"type":"assistant","message":{"model":"<synthetic>"}}'
# An Opus id quoted inside message text is JSON-escaped and must not count.
QUOTED='{"type":"user","message":{"content":"grep found \"model\":\"claude-opus-5-5\" in a log"}}'
LEAK='{"type":"assistant","message":{"model":"'"$SECRET"'"}}'

t=$(mt sonnet "$SON" "$SON" "$SYN" "$QUOTED")
out=$(bash "$S" --model "$t" claude-sonnet-5-5); rc=$?
[[ $rc == 0 && "$out" == *"MATCH     claude-sonnet-5-5"* ]] \
  && ok "Sonnet transcript, Sonnet expected -> MATCH, exit 0" || bad "sonnet -> rc=$rc $out"
[[ "$out" == *"2  claude-sonnet-5-5"* ]] \
  && ok "counts the record's own field, not the escaped quote in the text" || bad "count -> $out"
[[ "$out" != *"claude-opus-5-5"* ]] \
  && ok "an escaped model id inside message text is ignored" || bad "quoted id counted -> $out"

# The failure this mode exists for: a fork ignores the model override and runs on
# the parent's model, so the "Sonnet" reviewer was really Opus.
t=$(mt forked "$OPU" "$OPU")
out=$(bash "$S" --model "$t" claude-sonnet-5-5); rc=$?
[[ $rc != 0 && "$out" == *"MISMATCH  want claude-sonnet-5-5, ran on: claude-opus-5-5"* ]] \
  && ok "Opus transcript, Sonnet expected -> MISMATCH, non-zero exit" || bad "forked -> rc=$rc $out"

t=$(mt mixed "$OPU" "$SON")
out=$(bash "$S" --model "$t" claude-sonnet-5-5); rc=$?
[[ $rc != 0 && "$out" == *MISMATCH* ]] \
  && ok "two models in one transcript -> MISMATCH, not a partial match" || bad "mixed -> rc=$rc $out"

# Silence is not a pass: with no model recorded there is no evidence either way.
t=$(mt synthetic "$SYN" '{"type":"user"}')
out=$(bash "$S" --model "$t" claude-sonnet-5-5); rc=$?
[[ $rc != 0 && "$out" == *"NONE "* ]] \
  && ok "only <synthetic> records -> NONE, non-zero exit" || bad "synthetic -> rc=$rc $out"
t=$(mt empty '{"type":"user"}')
out=$(bash "$S" --model "$t"); rc=$?
[[ $rc != 0 && "$out" == *"NONE "* ]] \
  && ok "no model at all -> NONE even with nothing expected" || bad "empty -> rc=$rc $out"

ln -s "$(mt viatask "$SON")" "$tmp/viatask.output"
out=$(bash "$S" --model "$tmp/viatask.output" claude-sonnet-5-5); rc=$?
[[ $rc == 0 && "$out" == *MATCH* ]] \
  && ok "follows the .output symlink to the transcript" || bad "symlink -> rc=$rc $out"

t=$(mt leak "$LEAK" "$SON")
out=$(bash "$S" --model "$t"); rc=$?
[[ "$out" == *"(unrecognised)"* ]] \
  && ok "a model value that is not a Claude id is shown as (unrecognised)" || bad "leak -> $out"

echo "--effort reports the effort the reviewer actually ran at"
# Each assistant record carries a top-level "effort". The failure this mode exists for
# was real: Sonnet reviewers spawned as general-purpose with model "sonnet" ran at
# medium while the Opus reviewer next to them ran at xhigh.
ef(){ printf '{"type":"assistant","effort":"%s","perTurnEffort":"low","message":{"model":"claude-sonnet-5-5","content":"tok=%s"}}' "$1" "$SECRET"; }
QEFF='{"type":"user","message":{"content":"set \"effort\":\"high\" in the frontmatter"}}'

t=$(mt effhigh "$(ef high)" "$(ef high)" "$QEFF")
out=$(bash "$S" --effort "$t" high); rc=$?
[[ $rc == 0 && "$out" == *"MATCH     high"* ]] \
  && ok "high transcript, high expected -> MATCH, exit 0" || bad "effhigh -> rc=$rc $out"
[[ "$out" == *"2  high"* ]] \
  && ok "counts the record's own field, not perTurnEffort or an escaped quote" || bad "effort count -> $out"

t=$(mt effmed "$(ef medium)" "$(ef medium)")
out=$(bash "$S" --effort "$t" high); rc=$?
[[ $rc != 0 && "$out" == *"MISMATCH  want high, ran at: medium"* ]] \
  && ok "medium transcript, high expected -> MISMATCH, non-zero exit" || bad "effmed -> rc=$rc $out"

t=$(mt effmixed "$(ef high)" "$(ef xhigh)")
out=$(bash "$S" --effort "$t" high); rc=$?
[[ $rc != 0 && "$out" == *MISMATCH* ]] \
  && ok "two efforts in one transcript -> MISMATCH, not a partial match" || bad "effmixed -> rc=$rc $out"

t=$(mt effnone "$SON" '{"type":"user"}')
out=$(bash "$S" --effort "$t" high); rc=$?
[[ $rc != 0 && "$out" == *"NONE "* ]] \
  && ok "no effort recorded -> NONE, non-zero exit" || bad "effnone -> rc=$rc $out"

t=$(mt effleak "$(ef "$SECRET")" "$(ef high)")
out=$(bash "$S" --effort "$t"); rc=$?
[[ "$out" == *"(unrecognised)"* ]] \
  && ok "an effort value outside low..max is shown as (unrecognised)" || bad "effleak -> $out"

echo "transcript content must NEVER be printed"
all=$( { STALL_AFTER=180 IDLE_AFTER=1800 bash "$S" --list; STALL_AFTER=180 bash "$S" fresh
         for t in "$tmp"/transcripts/*.jsonl; do bash "$S" --model "$t" claude-sonnet-5-5
           bash "$S" --effort "$t" high; done; } 2>&1 )
case "$all" in
  *"$SECRET"*) bad "leaked transcript content" ;;
  *) ok "prints only numbers and record types" ;;
esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
