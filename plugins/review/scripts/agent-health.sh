#!/usr/bin/env bash
# agent-health.sh — is that quiet sub-agent thinking, stuck, or dead?
#
# A silent agent is one of three things and they need opposite responses, so the
# first move is always to distinguish them rather than to wait longer.
#
# This script NEVER prints transcript content. For a local agent the `.output` file
# is a symlink to the full JSONL conversation; reading it into a model's context
# blows up the context window. Everything here is aggregate: sizes, counts, record
# TYPES, timestamps. If you extend it, keep that property.
set -uo pipefail

usage() {
  cat >&2 <<'USAGE'
agent-health.sh [task-id | path/to/<task-id>.output]
agent-health.sh --list            list every task of the current session
agent-health.sh --watch <id>      print one line whenever the state changes (use with Monitor)
agent-health.sh --model <id> [expected-model]
                                  which model(s) answered; with expected-model, exit 0 only
                                  on MATCH (e.g. claude-sonnet-5-5)

Verdicts: WORKING (wait) · STALLED (nudge with SendMessage) · DEAD (TaskStop, then rerun)
USAGE
}

# Claude Code keeps per-session task output under a scratch dir; find the newest.
find_tasks_dir() {
  [[ -n "${OPGATE_TASKS_DIR:-}" ]] && { printf '%s' "$OPGATE_TASKS_DIR"; return; }
  local d
  d=$(find /private/tmp/claude-* /tmp/claude-* -maxdepth 3 -type d -name tasks 2>/dev/null \
      | while IFS= read -r p; do printf '%s\t%s\n' "$(stat -f %m "$p" 2>/dev/null || echo 0)" "$p"; done \
      | sort -rn | head -1 | cut -f2)
  printf '%s' "$d"
}

STALL_AFTER="${STALL_AFTER:-180}"     # seconds of silence before it counts as suspicious
IDLE_AFTER="${IDLE_AFTER:-1800}"      # silent this long -> almost certainly finished

resolve() { # <arg> -> path
  local a="$1" dir
  [[ -f "$a" ]] && { printf '%s' "$a"; return 0; }
  dir=$(find_tasks_dir)
  [[ -n "$dir" && -f "$dir/$a.output" ]] && { printf '%s' "$dir/$a.output"; return 0; }
  return 1
}

# Coarse on purpose: a task id cannot be mapped to a pid, so this answers "could
# anything still be working" — never "is THIS task running". The verdict below
# leans on it only in the window where it is actually informative.
agents_alive() { pgrep -f '[c]laude' 2>/dev/null | grep -c . || true; }

report() { # <file>
  local f="$1" now age size recs last verdict action
  now=$(date +%s)
  # -L: a task's .output is a symlink made when the task starts. Its own mtime never
  # moves, so without -L every long run reads as STALLED after STALL_AFTER seconds.
  age=$(( now - $(stat -L -f %m "$f" 2>/dev/null || echo "$now") ))
  size=$(wc -c <"$f" | tr -d ' ')
  # `grep -c` prints 0 AND exits 1 when nothing matches, so `|| echo 0` used to
  # print the count twice. Swallow the status instead of adding a second number.
  recs=$( { grep -c '^{' "$f" 2>/dev/null; } || true ); recs=${recs:-0}
  last=$(tail -c 4000 "$f" 2>/dev/null | grep -o '"type":"[a-z_]*"' | tail -1 | cut -d'"' -f4)

  # A finished background command leaves its exit line in the file. That is a
  # positive signal and outranks anything inferred from mtime.
  if tail -c 400 "$f" 2>/dev/null | grep -q '\[exited with code'; then
    printf '%-9s quiet %6ds  %9s bytes  %4s records  last: %-12s %s\n' \
      DONE "$age" "$size" "$recs" "${last:-exit}" "finished — read the result, no need to nudge"
    return
  fi

  local alive; alive=$(agents_alive)
  if (( age < STALL_AFTER )); then
    verdict=WORKING;  action="running, keep waiting"
  elif (( age > IDLE_AFTER )); then
    # Past this point "process alive" means nothing: some other agent is running.
    # The harness notifies on completion, so a task this quiet has almost
    # certainly already ended and its result is waiting.
    verdict=IDLE;     action="quiet for very long — most likely finished; check the agent result / notification before nudging"
  elif (( alive > 0 )); then
    verdict="STALLED?"; action="a claude process is alive (not necessarily this task) — SendMessage to nudge it to report"
  else
    verdict=DEAD;     action="no process left — TaskStop, then rerun"
  fi

  printf '%-9s quiet %6ds  %9s bytes  %4s records  last: %-12s %s\n' \
    "$verdict" "$age" "$size" "$recs" "${last:-?}" "$action"
}

# Which model actually answered. A reviewer spawned as a fork, or without its model
# override, runs on the parent's model and its report looks no different, so "the
# second reviewer was Sonnet" has to be read off the transcript, never assumed.
# Only values shaped like a Claude model id are printed; anything else is counted as
# "(unrecognised)", so this mode cannot print transcript content either.
models() { # <file> [expected-model] -> exit 0 only on a positive answer
  local f="$1" want="${2:-}" counts real distinct
  # Model ids quoted inside message text are JSON-escaped (\"model\":\"…\") and
  # cannot match this pattern; only the record's own field does.
  counts=$(grep -o '"model":"[^"\\]*"' "$f" 2>/dev/null | cut -d'"' -f4 \
    | awk '$0 !~ /^(claude-[a-z0-9.-]+|<synthetic>)$/ { $0 = "(unrecognised)" }
           { n[$0]++ }
           END { for (m in n) printf "%6d  %s\n", n[m], m }' | sort -rn)
  # <synthetic> marks messages the harness injected; they prove nothing about the model.
  real=$(printf '%s\n' "$counts" | awk 'NF && $2 != "<synthetic>" { print $2 }')
  [[ -n "$counts" ]] && printf '%s\n' "$counts"
  if [[ -z "$real" ]]; then
    # Silence is not a pass: no model id means no evidence, whatever was expected.
    echo "NONE      no model recorded — not an agent transcript, or no reply yet"
    return 1
  fi
  [[ -z "$want" ]] && return 0
  distinct=$(printf '%s\n' "$real" | tr '\n' ' ' | sed 's/ $//')
  if [[ "$distinct" == "$want" ]]; then
    printf 'MATCH     %s\n' "$want"
  else
    printf 'MISMATCH  want %s, ran on: %s\n' "$want" "$distinct"
    return 1
  fi
}

case "${1:-}" in
  -h|--help|"") usage; exit 0 ;;
  --list)
    dir=$(find_tasks_dir)
    [[ -n "$dir" ]] || { echo "tasks directory not found" >&2; exit 1; }
    echo "$dir"
    for f in "$dir"/*.output; do
      [[ -f "$f" ]] || continue
      printf '%-20s ' "$(basename "$f" .output)"; report "$f"
    done ;;
  --watch)
    f=$(resolve "${2:-}") || { echo "task not found: ${2:-}" >&2; exit 1; }
    prev=""
    while true; do
      cur=$(report "$f" | awk '{print $1}')
      [[ "$cur" != "$prev" ]] && { printf '%s: %s\n' "$(basename "$f" .output)" "$(report "$f")"; prev="$cur"; }
      # A monitor that only reports the happy path is silent through a crash, and
      # silence looks the same as still-running. Every state is emitted.
      sleep "${WATCH_INTERVAL:-60}"
    done ;;
  --model)
    f=$(resolve "${2:-}") || { echo "task '${2:-}' not found (try --list)" >&2; exit 1; }
    models "$f" "${3:-}"; exit $? ;;
  *)
    f=$(resolve "$1") || { echo "task '$1' not found (try --list)" >&2; exit 1; }
    report "$f" ;;
esac
