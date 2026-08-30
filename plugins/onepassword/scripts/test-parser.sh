#!/usr/bin/env bash
# Tests for the dotenv parser. Two kinds:
#
#   1. pure unit checks of parse_env_file (always run)
#   2. differential checks against the installed `op run` (skipped when 1Password
#      is locked, since the point is to compare real behaviour)
#
# The differential part matters more than it looks: if this parser and op disagree
# about which variables a file declares, the Touch ID sheet under-reports what is
# about to be resolved. That is a security defect, not a formatting one.
set -uo pipefail

dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$dir/lib/classify.sh"
source "$dir/lib/common.sh"

pass=0 fail=0
tmp=$(mktemp -d "${TMPDIR:-/tmp}/opgate-test-parser.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

chk() { # <label> <got> <want>
  if [[ "$2" == "$3" ]]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL %s\n       got  [%s]\n       want [%s]\n' "$1" "$2" "$3"; fi
}

parse_one() { # <label> <file-content> <var> -> prints value
  printf '%s' "$2" > "$tmp/e"
  parse_env_file "$tmp/e"
  local i
  for (( i = 0; i < ${#OPG_NAMES[@]}; i++ )); do
    [[ "${OPG_NAMES[$i]}" == "$3" ]] && { printf '%s' "${OPG_VALUES[$i]}"; return; }
  done
  printf '<absent>'
}

names_of() { printf '%s' "$1" > "$tmp/e"; parse_env_file "$tmp/e"
  local IFS=,; printf '%s' "${OPG_NAMES[*]-}"; }

echo "tên biến"
chk "export nhiều khoảng trắng" "$(names_of 'export    API_TOKEN=x')" "API_TOKEN"
chk "export dùng tab"           "$(names_of "export$(printf '\t')API_TOKEN=x")" "API_TOKEN"
chk "khoảng trắng quanh dấu ="  "$(names_of 'ADMIN_TOKEN = op://Dev/a/B')" "ADMIN_TOKEN"
chk "tên bắt đầu bằng số"       "$(names_of '1TOKEN=x')" "1TOKEN"
chk "bỏ qua comment và dòng trống" "$(names_of '# c

A=1
B=2')" "A,B"
chk "dòng cuối không có newline" "$(names_of 'A=1
B=2')" "A,B"

echo "giá trị"
chk "comment cuối dòng"      "$(parse_one x 'API_TOKEN=abc123 #rotation-note' API_TOKEN)" "abc123"
chk "comment không khoảng trắng" "$(parse_one x 'API_TOKEN=abc123#note' API_TOKEN)" "abc123"
chk "# trong nháy đơn"       "$(parse_one x "APP_NAME='Acme # prod'" APP_NAME)" "Acme # prod"
chk "# trong nháy kép"       "$(parse_one x 'APP_NAME="Acme # prod"' APP_NAME)" "Acme # prod"
chk "nháy kép, escape \\n"    "$(parse_one x 'A="x\ny"' A)" "$(printf 'x\ny')"
chk "nháy đơn giữ nguyên \\n"  "$(parse_one x "A='x\\ny'" A)" 'x\ny'
chk "escape dấu nháy"        "$(parse_one x 'A="say \"hi\""' A)" 'say "hi"'
chk "giá trị có dấu ="       "$(parse_one x 'A=k=v' A)" "k=v"
chk "CRLF"                   "$(parse_one x "$(printf 'A=1\r\nB=2\r\n')" A)" "1"
chk "trim khoảng trắng cuối"  "$(parse_one x 'A=val   ' A)" "val"

echo "giá trị nhiều dòng"
chk "nháy kép nhiều dòng" "$(parse_one x 'A="line1
line2"
B=2' A)" "$(printf 'line1\nline2')"
chk "biến sau giá trị nhiều dòng vẫn được thấy" "$(names_of 'A="line1
line2"
B=2')" "A,B"
chk "PEM trong nháy đơn" "$(parse_one x "K='-----BEGIN X-----
body
-----END X-----'" K)" "$(printf -- '-----BEGIN X-----\nbody\n-----END X-----')"

echo "so sánh trực tiếp với op run"
if op vault list --format json </dev/null >/dev/null 2>&1; then
  # op resolves these files; if it exports a variable this parser does not list,
  # the approval prompt would be lying about scope.
  cat > "$tmp/diff.env" <<'X'
export    A_ONE=1
B_TWO = 2
1DIGIT=3
C_THREE=val #comment
D_FOUR='keep # this'
E_FIVE="multi
line"
X
  op_names=$(op run --env-file="$tmp/diff.env" -- \
    sh -c 'env | grep -E "^(A_ONE|B_TWO|1DIGIT|C_THREE|D_FOUR|E_FIVE)=" | cut -d= -f1 | sort | tr "\n" ","' 2>/dev/null)
  parse_env_file "$tmp/diff.env"
  our_names=$(printf '%s\n' "${OPG_NAMES[@]-}" | grep -E '^(A_ONE|B_TWO|1DIGIT|C_THREE|D_FOUR|E_FIVE)$' | sort | tr '\n' ',')
  chk "danh sách biến khớp với op run" "$our_names" "$op_names"

  for v in C_THREE D_FOUR; do
    op_val=$(op run --env-file="$tmp/diff.env" -- sh -c "printf '%s' \"\$$v\"" 2>/dev/null)
    chk "giá trị $v khớp op run" "$(parse_one x "$(cat "$tmp/diff.env")" "$v")" "$op_val"
  done
else
  printf '  bỏ qua: 1Password đang khoá, không so được với op run\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
