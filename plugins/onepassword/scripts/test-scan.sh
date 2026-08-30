#!/usr/bin/env bash
# Tests for the scanner: pattern table, embedded-credential detection, item
# naming, and env parsing. Runs against fixtures in a temp dir — no vault, no
# network, no Touch ID.
#
# Runs the library under `set -euo pipefail`, the way bin/opgate does. An earlier
# version passed when tested without it and did nothing when tested with it,
# because a non-matching grep aborted the function.
set -uo pipefail

dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$dir/lib/scan.sh"

pass=0 fail=0
ok_()   { pass=$((pass + 1)); printf '  ok   %s\n' "$1"; }
bad_()  { fail=$((fail + 1)); printf '  FAIL %s\n' "$1"; }
eq()    { [[ "$2" == "$3" ]] && ok_ "$1" || bad_ "$1 -> '$2' (want '$3')"; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/opgate-test-scan.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

echo "bảng pattern"
n=0
while IFS=$'\t' read -r l f pat; do [[ -n "$l" && -n "$pat" ]] && n=$((n + 1)); done < <(scan_patterns)
eq "parse được đủ pattern" "$n" "11"

echo "mỗi pattern phải bắt được fixture của nó"
# Invented credentials, shaped like the real thing. None of these are valid.
fixture() { printf '%s\n' "$2" > "$tmp/f"; local got
  got=$(set -euo pipefail; scan_embedded "$tmp/f" | cut -f2 | sort -u | tr '\n' ',')
  case "$got" in *"$1"*) ok_ "$1" ;; *) bad_ "$1 (bắt được: ${got:-<không gì>})" ;; esac
}
fixture 'AWS access key id' 'id = AKIAIOSFODNN7EXAMPLE'
fixture 'GitHub token'      'tok=ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
fixture 'GitLab PAT'        'glpat-aaaaaaaaaaaaaaaaaaaa'
fixture 'Slack token'       'xoxb-1111111111-abcdefghij'
fixture 'Slack webhook'     'https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX'
fixture 'Stripe key'        'sk_live_aaaaaaaaaaaaaaaaaaaaaaaa'
fixture 'OpenAI-style key'  'sk-aaaaaaaaaaaaaaaaaaaaaaaaaaaa'
fixture 'JWT'               'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.sig'
fixture 'private key block' '-----BEGIN RSA PRIVATE KEY-----'
fixture 'URL with password' 'db: postgres://user:hunter2@host/db'
fixture 'assigned secret'   '{"AWS_SECRET_ACCESS_KEY":"wJalrXUtnFEMIabcdEXAMPLEKEY"}'

echo "nhiều pattern trên cùng một file đều phải được báo"
printf 'a=ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nb=AKIAIOSFODNN7EXAMPLE\n' > "$tmp/multi"
got=$(set -euo pipefail; scan_embedded "$tmp/multi" | wc -l | tr -d ' ')
eq "hai pattern khác nhau" "$got" "2"

echo "output KHÔNG được chứa giá trị"
secret='ghp_zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz'
printf 'tok=%s\n' "$secret" > "$tmp/leak"
out=$(set -euo pipefail; scan_embedded "$tmp/leak")
case "$out" in
  *"$secret"*) bad_ "scan_embedded làm lộ giá trị" ;;
  *) ok_ "scan_embedded chỉ in dòng + nhãn: $(printf '%s' "$out" | tr '\t' ' ')" ;;
esac

echo "đặt tên item"
eq "root .env"          "$(item_name_for /r/.env cme /r)"                    "cme"
eq "thư mục con"        "$(item_name_for /r/api/.env cme /r)"                "cme-api"
eq "hậu tố môi trường"  "$(item_name_for /r/web/.env.production cme /r)"     "cme-web-production"
eq "hậu tố ở root"      "$(item_name_for /r/.env.local cme /r)"              "cme-local"
eq "lồng nhiều cấp"     "$(item_name_for /r/svc/auth/.env.staging cme /r)"   "cme-svc-auth-staging"

echo "tìm file env, bỏ qua template"
mkdir -p "$tmp/p/api"
: > "$tmp/p/.env"; : > "$tmp/p/api/.env.production"
: > "$tmp/p/.env.example"; : > "$tmp/p/.env.op"; : > "$tmp/p/api/.env.tpl"
got=$(find_env_files "$tmp/p" | wc -l | tr -d ' ')
eq "chỉ file env thật" "$got" "2"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
