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

echo "the pattern table"
n=0
while IFS=$'\t' read -r l f pat; do [[ -n "$l" && -n "$pat" ]] && n=$((n + 1)); done < <(scan_patterns)
eq "every pattern parses" "$n" "15"

echo "every pattern must catch its own fixture"
# Invented credentials, shaped like the real thing. None of these are valid.
fixture() { printf '%s\n' "$2" > "$tmp/f"; local got
  got=$(set -euo pipefail; scan_embedded "$tmp/f" | cut -f2 | sort -u | tr '\n' ',')
  case "$got" in *"$1"*) ok_ "$1" ;; *) bad_ "$1 (caught: ${got:-<nothing>})" ;; esac
}
fixture 'AWS access key id' 'id = AKIAIOSFODNN7EXAMPLE'
fixture 'GitHub token'      'tok=ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
fixture 'GitLab PAT'        'glpat-aaaaaaaaaaaaaaaaaaaa'
fixture 'Slack token'       'xoxb-1111111111-abcdefghij'
fixture 'Slack webhook'     'https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX'
fixture 'Stripe secret key' 'sk_live_aaaaaaaaaaaaaaaaaaaaaaaa'
fixture 'OpenAI-style key'  'sk-aaaaaaaaaaaaaaaaaaaaaaaaaaaa'
fixture 'JWT'               'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.sig'
fixture 'private key block' '-----BEGIN RSA PRIVATE KEY-----'
fixture 'URL with password' 'db: postgres://user:hunter2@host/db'
fixture 'assigned secret'   '{"AWS_SECRET_ACCESS_KEY":"wJalrXUtnFEMIabcdEXAMPLEKEY"}'
fixture 'GitHub fine-grained' 'github_pat_11ABCDEFG0aaaaaaaaaaaaaaaaaaaa'
fixture 'npm token'         '//registry.npmjs.org/:_authToken=npm_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
fixture 'Discord webhook'   'https://discord.com/api/webhooks/123456789012345678/aB3dE5gH7jK9lM1nO3pQ5rS7tU9vW1xY'
fixture 'AWS access key id' 'ASIAIOSFODNN7EXAMPLE'
fixture 'assigned secret'   'api_key: aaaaaaaaaaaaaaaaaaaaaa'

echo "noise control: a publishable key must NOT be reported"
printf 'k = pk_live_aaaaaaaaaaaaaaaaaaaaaaaa\n' > "$tmp/pk"
got=$(set -euo pipefail; scan_embedded "$tmp/pk" | cut -f2 | sort -u | tr '\n' ',')
case "$got" in *Stripe*) bad_ "pk_live wrongly reported as a Stripe key" ;; *) ok_ "pk_live ignored" ;; esac

echo "YAML is scanned (-name '*.ya?ml' used to match nothing)"
mkdir -p "$tmp/y"; : > "$tmp/y/a.yaml"; : > "$tmp/y/b.yml"; : > "$tmp/y/c.py"; : > "$tmp/y/d.min.js"
got=$(find_config_files "$tmp/y" | wc -l | tr -d ' ')
eq "yaml + yml + py, skipping .min.js" "$got" "3"

echo "several patterns in one file must all be reported"
printf 'a=ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\nb=AKIAIOSFODNN7EXAMPLE\n' > "$tmp/multi"
got=$(set -euo pipefail; scan_embedded "$tmp/multi" | wc -l | tr -d ' ')
eq "two different patterns" "$got" "2"

echo "the output must NOT contain the value"
secret='ghp_zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz'
printf 'tok=%s\n' "$secret" > "$tmp/leak"
out=$(set -euo pipefail; scan_embedded "$tmp/leak")
case "$out" in
  *"$secret"*) bad_ "scan_embedded leaked the value" ;;
  *) ok_ "scan_embedded prints only line + label: $(printf '%s' "$out" | tr '\t' ' ')" ;;
esac

echo "item naming"
eq "root .env"          "$(item_name_for /r/.env cme /r)"                    "cme"
eq "subdirectory"          "$(item_name_for /r/api/.env cme /r)"                "cme-api"
eq "environment suffix"     "$(item_name_for /r/web/.env.production cme /r)"     "cme-web-production"
eq "suffix at the root"     "$(item_name_for /r/.env.local cme /r)"              "cme-local"
eq "nested several levels"  "$(item_name_for /r/svc/auth/.env.staging cme /r)"   "cme-svc-auth-staging"

echo "finding env files, skipping templates"
mkdir -p "$tmp/p/api"
: > "$tmp/p/.env"; : > "$tmp/p/api/.env.production"
: > "$tmp/p/.env.example"; : > "$tmp/p/.env.op"; : > "$tmp/p/api/.env.tpl"
got=$(find_env_files "$tmp/p" | wc -l | tr -d ' ')
eq "real env files only" "$got" "2"

echo "round 3 — GREP_OPTIONS=-h must not leak file contents"
secret='ghp_yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy'
printf 'tok=%s\n' "$secret" > "$tmp/g.json"
out=$(GREP_OPTIONS=-h bash -c 'set -euo pipefail; source "'"$dir"'/lib/scan.sh"; printf "%s\n" "'"$tmp"'/g.json" | scan_embedded_list')
case "$out" in
  *"$secret"*) bad_ "GREP_OPTIONS=-h leaked the value: $(printf '%s' "$out" | cut -c1-40)…" ;;
  *) ok_ "GREP_OPTIONS=-h: output is still only file/line/label" ;;
esac
out=$(GREP_OPTIONS=-h bash -c 'source "'"$dir"'/lib/scan.sh"; printf "%s\n" "'"$tmp"'/g.json" | scan_embedded_list | cut -f2')
eq "field 2 is the line number, not the content" "$out" "1"

echo "round 3 — noise control: reads from env, templates and op:// are not reported"
for line in 'const token = req.headers.authorization' 'secret = process.env.JWT_SECRET_VALUE' 'password: ${POSTGRES_PASSWORD_FROM_ENV}' 'secret: op://Dev/app/DB_SECRET' 'api_key = os.environ.get("API_KEY_FROM_ENV")'; do
  printf '%s\n' "$line" > "$tmp/noise"
  got=$(set -euo pipefail; scan_embedded "$tmp/noise" | wc -l | tr -d ' ')
  eq "ignored: $(printf '%s' "$line" | cut -c1-40)" "$got" "0"
done
printf 'api_key = "aaaaaaaaaaaaaaaaaaaaaaaa"\n' > "$tmp/real"
got=$(set -euo pipefail; scan_embedded "$tmp/real" | wc -l | tr -d ' ')
eq "but a real assignment is still reported" "$got" "1"

echo "round 3 — a filename containing a newline must not corrupt the list"
mkdir -p "$tmp/nl"; printf 'x=1\n' > "$tmp/nl/a.json"
printf 'tok=ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$tmp/nl/$(printf 'b\nc').json" 2>/dev/null || true
got=$(find_config_files "$tmp/nl" | wc -l | tr -d ' ')
eq "the newline filename is dropped, the ordinary one stays" "$got" "1"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
