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

echo "tên biến rõ ràng là secret"
t JWT_SECRET        'aXk29fjLQ0zBn4'                       secret
t DATABASE_URL      'postgres://u:p@h:5432/db'             secret
t STRIPE_SECRET_KEY 'sk_live_aaaaaaaaaaaaaaaaaaaaaaaa'     secret
t SUPABASE_SERVICE_ROLE_KEY 'abc123def456'                 secret
t GITHUB_PAT        'short'                                secret
t SESSION_SECRET    'x1y2z3'                               secret

echo "tên biến rõ ràng là config"
t NODE_ENV     development  config
t PORT         3000         config
t LOG_LEVEL    debug        config
t HOST         localhost    config
t NEXT_PUBLIC_SITE_URL 'https://example.com' config
t APP_ENV      production   config

echo "hình dạng giá trị quyết định, bất kể tên"
t SOMETHING  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abc'  secret
t WHATEVER   'AKIAIOSFODNN7EXAMPLE'                      secret
t ANYTHING   'ghp_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'  secret
t X_VALUE    'xoxb-1111-2222-abcdefghij'                 secret
t MY_THING   'postgres://user:hunter2@db.internal/app'   secret
t RANDOM_ID  'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6'          secret
t GENERATED  'Kx8Qm2Lp9Zr4Ns7Tv1Wy6Bd3Fg5Hj0'            secret
t NOT_A_KEY  '-----BEGIN RSA PRIVATE KEY-----'           secret

echo "placeholder và rỗng"
t API_KEY   ''             empty
t API_KEY   'changeme'     placeholder
t API_KEY   'your-key-here' placeholder
t API_KEY   '<your-token>' placeholder
t API_KEY   '${FROM_CI}'   placeholder
t SOME_VAR  'TODO'         placeholder

echo "mơ hồ — phải hỏi người dùng"
t MAILER_FROM  'noreply@example.com many words here'  ambiguous
t CUSTOM_THING 'some-medium-length-text-value'        ambiguous

echo "URL công khai không phải secret"
t API_URL   'https://api.example.com'  config
t SITE_URL  'https://example.com/path' config
t BASE_URL  'http://localhost:8080/v1' config
t CDN_URL   'https://cdn.example.com/assets/main.css' config

echo "URL mang credential trong path VẪN là secret"
t NOTIFY_URL 'https://hooks.slack.com/services/T00000000/B00000000/XXXXXXXXXXXXXXXXXXXXXXXX' secret
t DISCORD_HOOK 'https://discord.com/api/webhooks/123456789012345678/aB3dE5gH7jK9lM1nO3pQ5rS7tU9vW1xY3zA5bC7dE9f' secret
t WEBHOOK_URL 'https://example.com/hook' secret

echo
echo "FAIL-CLOSED: không được xếp secret thật thành config/placeholder"
# Mọi ca dưới đây từng bị xếp sai và ghi literal vào .env.op — file dán nhãn
# "commit được". Đây là hậu quả tệ nhất mà bộ phân loại có thể gây ra.
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

echo "giá trị ngắn KHÔNG còn tự động thành config"
# Quy tắc "ngắn và đơn giản -> config" là lỗ fail-open: nó biến hunter2 thành
# cấu hình. Giờ chỉ TÊN mới hạ được một biến xuống config.
t SOME_VALUE   'abc'      ambiguous
t RANDOM_THING 'x1'       ambiguous
t NODE_ENV     'prod'     config
t PORT         '8080'     config

echo "placeholder chỉ còn những dấu hiệu không thể nhầm"
t API_KEY  'changeme'      placeholder
t API_KEY  '<your-token>'  placeholder
t API_KEY  '${FROM_CI}'    placeholder
t API_KEY  'your-key-here' placeholder
t API_KEY  'TODO'          placeholder
t API_KEY  'secret'        secret
t API_KEY  'test'          secret
t API_KEY  'dummy'         secret
t API_KEY  'example'       secret

echo "describe_value không được lộ giá trị"
for v in 'sk_live_abcdefghijklmnopqrst' 'postgres://u:p@h/db' $'multi\nline'; do
  d=$(describe_value "$v")
  if [[ "$d" == *"$v"* ]] || [[ "$v" == *"$d"* && ${#d} -gt 8 ]]; then
    fail=$((fail + 1)); printf '  FAIL describe_value làm lộ giá trị: %s\n' "$d"
  else
    pass=$((pass + 1)); printf '  ok   %s\n' "$d"
  fi
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
