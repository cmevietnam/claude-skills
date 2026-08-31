#!/usr/bin/env bash
# Unit tests for the secret classifier. Pure logic — no vault, no network, no
# Touch ID. The fixture values here are invented, not real credentials.
set -uo pipefail

dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/classify.sh
source "$dir/lib/classify.sh"

pass=0 fail=0
t() { # <name> <value> <expected>
  local got; got=$(classify_var "$1" "$2")
  if [[ "$got" == "$3" ]]; then
    pass=$((pass + 1)); printf '  ok   %-24s -> %s\n' "$1" "$got"
  else
    fail=$((fail + 1)); printf '  FAIL %-24s -> %s (want %s)\n' "$1" "$got" "$3"
  fi
}

echo "names that are unmistakably secrets"
t JWT_SECRET        'aXk29fjLQ0zBn4'                       secret
t DATABASE_URL      'postgres://u:p@h:5432/db'             secret
t STRIPE_SECRET_KEY 'sk_live_aaaaaaaaaaaaaaaaaaaaaaaa'     secret
t SUPABASE_SERVICE_ROLE_KEY 'abc123def456'                 secret
t GITHUB_PAT        'short'                                secret
t SESSION_SECRET    'x1y2z3'                               secret

echo "names that are unmistakably config"
t NODE_ENV     development  config
t PORT         3000         config
t LOG_LEVEL    debug        config
t HOST         localhost    config
t NEXT_PUBLIC_SITE_URL 'https://example.com' config
t APP_ENV      production   config

echo "the shape of the value decides, whatever the name says"
t SOMETHING  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abc'  secret
t WHATEVER   'AKIAIOSFODNN7EXAMPLE'                      secret
t ANYTHING   'ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'  secret
t X_VALUE    'xoxb-1111-2222-abcdefghij'                 secret
t MY_THING   'postgres://user:hunter2@db.internal/app'   secret
t RANDOM_ID  'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6'          secret
t GENERATED  'Kx8Qm2Lp9Zr4Ns7Tv1Wy6Bd3Fg5Hj0'            secret
t NOT_A_KEY  '-----BEGIN RSA PRIVATE KEY-----'           secret

echo "placeholders and empty values"
t API_KEY   ''             empty
t API_KEY   'changeme'     secret
t API_KEY   'your-key-here' secret
t API_KEY   '<your-token>' placeholder
t API_KEY   '${FROM_CI}'   placeholder
t SOME_VAR  'TODO'         ambiguous

echo "ambiguous — has to ask the user"
t MAILER_FROM  'noreply@example.com many words here'  ambiguous
t CUSTOM_THING 'some-medium-length-text-value'        ambiguous

echo "a public URL is not a secret"
t API_URL   'https://api.example.com'  config
t SITE_URL  'https://example.com/path' config
t BASE_URL  'http://localhost:8080/v1' config
t CDN_URL   'https://cdn.example.com/assets/main.css' ambiguous

echo "a URL carrying a credential in its path IS a secret"
t NOTIFY_URL 'https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX' secret
t DISCORD_HOOK 'https://discord.com/api/webhooks/123456789012345678/aB3dE5gH7jK9lM1nO3pQ5rS7tU9vW1xY3zA5bC7dE9f' secret
t WEBHOOK_URL 'https://example.com/hook' secret

echo
echo "FAIL CLOSED: a real secret must never be classified as config or placeholder"
# Every case below was once misclassified and written as a literal into .env.op —
# the file the docs label "safe to commit". That is the worst thing this classifier
# can do, so these cases are the ones that matter most.
t DB_PASS      'hunter2'                          secret
t DB_PASSWORD  'password'                         secret
t API_KEY      '<p@ssword>'                       placeholder
t db_pass      'hunter2'                          secret
t MYSQL_PW     'abc123'                           secret
t PASSPHRASE   'correct horse'                    secret
t ADMIN_PASS   'x'                                secret
t MAGIC_LINK   'https://app.example/login?token=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.sig' secret
t CALLBACK     'https://a.example/cb?api_key=abcdef123456'  secret
t SHORT_TOKEN  'a1b2c3'                            secret
t SEED_PHRASE  'word word word'                    secret

echo "a short value is no longer automatically config"
# The old "short and simple -> config" rule was a fail-open hole: it turned
# hunter2 into configuration. Only the NAME can demote a variable now.
t SOME_VALUE   'abc'      ambiguous
t RANDOM_THING 'x1'       ambiguous
t NODE_ENV     'prod'     config
t PORT         '8080'     config

echo "placeholders are now only the unmistakable markers"
t API_KEY  'changeme'      secret
t API_KEY  '<your-token>'  placeholder
t API_KEY  '${FROM_CI}'    placeholder
t API_KEY  'your-key-here' secret
t API_KEY  'TODO'          secret
t API_KEY  'secret'        secret
t API_KEY  'test'          secret
t API_KEY  'dummy'         secret
t API_KEY  'example'       secret

echo "round 3 — the wildcard allowlist is gone; only an exact name means config"
t PUBLIC_PASSCODE     '1234'                         secret
t NEXT_PUBLIC_PINCODE '1234'                         secret
t PUBLIC_HMAC         'deadbeef'                     secret
t PUBLIC_ADMIN_PASSCODE 'correct-horse-battery-staple' secret
t MAX_KEYS            'abc'                          ambiguous
t MIN_SOMETHING       'x'                            ambiguous
t SMTP_HOSTNAME       'mail.example.com'             ambiguous
t PUBLIC_THING        'hello'                        ambiguous
t NEXT_PUBLIC_SITE_URL 'https://x.example'           config
t AWS_REGION          'ap-southeast-1'               config
t DB_PORT             '5432'                         config

echo "round 3 — no more demotion just because a value looks like a URL"
t MAGIC_LINK  'https://x.example/login?code=hunter2'   secret
t CALLBACK    'https://x.example/cb?session=abc'       secret
t SOME_URL    'https://x.example/docs'                 ambiguous

echo "round 3 — an op:// value is a reference, not something to re-vault"
t ALREADY  'op://Dev/app/KEY'   reference
t WEIRD    'op://hunter2'       reference

echo "round 3 — is_op_ref accepts only valid syntax"
r() { if is_op_ref "$1"; then got=valid; else got=invalid; fi
  if [[ "$got" == "$2" ]]; then pass=$((pass+1)); printf '  ok   %-30s %s\n' "$(printf %s "$1" | tr '\n' '|')" "$got"
  else fail=$((fail+1)); printf '  FAIL %-30s %s (want %s)\n' "$(printf %s "$1" | tr '\n' '|')" "$got" "$2"; fi; }
r 'op://Dev/app/KEY'          valid
r 'op://Dev/app/sec/KEY'      valid
r 'op://My Vault/an item/F'   valid
r 'op://hunter2'              invalid
r 'op://Dev/app'              invalid
r 'op://Dev/app/a/b/c'        invalid
r "$(printf 'op://bad\nhunter2')" invalid
r 'op://Dev/app/K"EY'         invalid
r 'op://Dev//KEY'             invalid

echo "describe_value must not leak the value"
for v in 'sk_live_abcdefghijklmnopqrst' 'postgres://u:p@h/db' $'multi\nline'; do
  d=$(describe_value "$v")
  if [[ "$d" == *"$v"* ]] || [[ "$v" == *"$d"* && ${#d} -gt 8 ]]; then
    fail=$((fail + 1)); printf '  FAIL describe_value leaked the value: %s\n' "$d"
  else
    pass=$((pass + 1)); printf '  ok   %s\n' "$d"
  fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
