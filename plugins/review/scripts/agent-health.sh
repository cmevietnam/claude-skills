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
agent-health.sh --list            liệt kê mọi task của session hiện tại
agent-health.sh --watch <id>      in một dòng mỗi khi trạng thái đổi (dùng với Monitor)

Kết quả: WORKING (chờ) · STALLED (SendMessage giục) · DEAD (TaskStop rồi chạy lại)
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

STALL_AFTER="${STALL_AFTER:-180}"     # giây im lặng trước khi coi là đáng ngờ
IDLE_AFTER="${IDLE_AFTER:-1800}"      # im lặng quá lâu -> gần như chắc chắn đã kết thúc

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
  age=$(( now - $(stat -f %m "$f" 2>/dev/null || echo "$now") ))
  size=$(wc -c <"$f" | tr -d ' ')
  # `grep -c` prints 0 AND exits 1 when nothing matches, so `|| echo 0` used to
  # print the count twice. Swallow the status instead of adding a second number.
  recs=$( { grep -c '^{' "$f" 2>/dev/null; } || true ); recs=${recs:-0}
  last=$(tail -c 4000 "$f" 2>/dev/null | grep -o '"type":"[a-z_]*"' | tail -1 | cut -d'"' -f4)

  # A finished background command leaves its exit line in the file. That is a
  # positive signal and outranks anything inferred from mtime.
  if tail -c 400 "$f" 2>/dev/null | grep -q '\[exited with code'; then
    printf '%-9s im lặng %6ds  %9s bytes  %4s bản ghi  cuối: %-12s %s\n' \
      DONE "$age" "$size" "$recs" "${last:-exit}" "đã kết thúc — đọc kết quả, không cần giục"
    return
  fi

  local alive; alive=$(agents_alive)
  if (( age < STALL_AFTER )); then
    verdict=WORKING;  action="đang chạy, chờ tiếp"
  elif (( age > IDLE_AFTER )); then
    # Past this point "process alive" means nothing: some other agent is running.
    # The harness notifies on completion, so a task this quiet has almost
    # certainly already ended and its result is waiting.
    verdict=IDLE;     action="im lặng quá lâu — nhiều khả năng đã xong; xem kết quả agent / notification trước khi giục"
  elif (( alive > 0 )); then
    verdict="STALLED?"; action="còn tiến trình claude (không chắc là task này) — SendMessage giục nó báo cáo"
  else
    verdict=DEAD;     action="không còn tiến trình nào — TaskStop rồi chạy lại"
  fi

  printf '%-9s im lặng %6ds  %9s bytes  %4s bản ghi  cuối: %-12s %s\n' \
    "$verdict" "$age" "$size" "$recs" "${last:-?}" "$action"
}

case "${1:-}" in
  -h|--help|"") usage; exit 0 ;;
  --list)
    dir=$(find_tasks_dir)
    [[ -n "$dir" ]] || { echo "không tìm thấy thư mục tasks" >&2; exit 1; }
    echo "$dir"
    for f in "$dir"/*.output; do
      [[ -f "$f" ]] || continue
      printf '%-20s ' "$(basename "$f" .output)"; report "$f"
    done ;;
  --watch)
    f=$(resolve "${2:-}") || { echo "không tìm thấy task ${2:-}" >&2; exit 1; }
    prev=""
    while true; do
      cur=$(report "$f" | awk '{print $1}')
      [[ "$cur" != "$prev" ]] && { printf '%s: %s\n' "$(basename "$f" .output)" "$(report "$f")"; prev="$cur"; }
      # A monitor that only reports the happy path is silent through a crash, and
      # silence looks the same as still-running. Every state is emitted.
      sleep "${WATCH_INTERVAL:-60}"
    done ;;
  *)
    f=$(resolve "$1") || { echo "không tìm thấy task '$1' (thử --list)" >&2; exit 1; }
    report "$f" ;;
esac
