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

echo "phân loại trạng thái"
f=$(mk fresh 5)
out=$(STALL_AFTER=180 IDLE_AFTER=1800 bash "$S" fresh)
case "$out" in WORKING*) ok "file vừa ghi -> WORKING" ;; *) bad "fresh -> $out" ;; esac

f=$(mk stale 600)
out=$(STALL_AFTER=180 IDLE_AFTER=1800 bash "$S" stale)
case "$out" in "STALLED?"*|DEAD*) ok "im lặng vừa phải -> STALLED?/DEAD" ;; *) bad "stale -> $out" ;; esac

# Quá ngưỡng IDLE thì "còn tiến trình claude" không còn nói lên gì — đó là agent
# khác. Harness đã báo khi task xong, nên im lặng lâu gần như chắc chắn là đã kết
# thúc, và khuyên "giục nó" ở đây là khuyên sai.
f=$(mk ancient 7200)
out=$(STALL_AFTER=180 IDLE_AFTER=1800 bash "$S" ancient)
case "$out" in IDLE*) ok "im lặng rất lâu -> IDLE, không khuyên giục" ;; *) bad "ancient -> $out" ;; esac

# Lệnh nền đã xong để lại dòng exit; dấu hiệu dương này thắng mọi suy đoán từ mtime.
fd="$tmp/tasks/finished.output"
printf 'output\n\n[exited with code 0]\n' > "$fd"
touch -t "$(date -v-9000S +%Y%m%d%H%M.%S 2>/dev/null || date +%Y%m%d%H%M.%S)" "$fd"
out=$(STALL_AFTER=180 IDLE_AFTER=1800 bash "$S" finished)
case "$out" in DONE*) ok "có dòng exit -> DONE dù file rất cũ" ;; *) bad "finished -> $out" ;; esac

echo "số bản ghi không được đếm hai lần"
# `grep -c` in ra 0 VÀ thoát 1 khi không khớp, nên `|| echo 0` từng in số đếm hai lần.
n=$(printf '%s' "$out" | grep -oE '[0-9]+ bản ghi' | wc -l | tr -d ' ')
[[ "$n" == 1 ]] && ok "đúng một trường 'bản ghi'" || bad "có $n trường 'bản ghi'"
lines=$(printf '%s' "$out" | wc -l | tr -d ' ')
[[ "$lines" == 0 ]] && ok "kết quả gọn trên một dòng" || bad "kết quả tràn $((lines+1)) dòng"

echo "nhận task qua id và qua đường dẫn"
out=$(STALL_AFTER=180 IDLE_AFTER=1800 bash "$S" "$tmp/tasks/fresh.output")
case "$out" in WORKING*) ok "đường dẫn đầy đủ" ;; *) bad "đường dẫn -> $out" ;; esac
bash "$S" khong-ton-tai >/dev/null 2>&1 && bad "id sai phải lỗi" || ok "id sai -> lỗi"

echo "--list liệt kê mọi task"
out=$(STALL_AFTER=180 IDLE_AFTER=1800 bash "$S" --list)
n=$(printf '%s' "$out" | grep -cE 'WORKING|STALLED|DEAD|IDLE|DONE')
[[ "$n" == 4 ]] && ok "liệt kê đủ 4 task" || bad "--list thấy $n task (muốn 4)"

echo "KHÔNG được in nội dung transcript"
all=$( { STALL_AFTER=180 IDLE_AFTER=1800 bash "$S" --list; STALL_AFTER=180 bash "$S" fresh; } 2>&1 )
case "$all" in
  *"$SECRET"*) bad "làm lộ nội dung transcript" ;;
  *) ok "chỉ in số liệu và loại bản ghi" ;;
esac

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
