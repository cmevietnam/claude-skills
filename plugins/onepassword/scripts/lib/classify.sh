#!/usr/bin/env bash
# Deciding which variables belong in the vault, without ever printing a value.
#
# FAIL CLOSED. The output decides whether a value becomes an op:// reference or is
# copied verbatim into a file the docs tell you to commit. Misclassifying a secret
# as configuration moves a secret that was on disk into git.
#
# Three reviews in a row broke earlier versions of this file, each time through a
# rule that let the VALUE argue for a literal: "short and simple", "looks like a
# plain URL", "changeme is a placeholder", and wildcard name prefixes like
# PUBLIC_* that happily matched PUBLIC_PASSCODE. So the rule is now one sentence:
#
#   A value becomes a literal only if its NAME is on an exact-match allowlist, or
#   the value is template syntax (<...>, ${...}, $VAR), or it already is op://.
#
# Nothing else may demote. Everything unproven comes back `ambiguous` and a human
# is asked. That means `import` asks more often; that is the cost of the sentence
# above being true.
#
# Every function works on the value using bash builtins only. Passing a secret to
# an external command puts it in that command's argv.

# Names that are secrets regardless of value. Checked against the upper-cased
# name, so `db_pass` counts. Shared with common.sh's literal warning, so the
# importer and the warning cannot disagree.
CLASSIFY_SECRET_NAME='(SECRET|TOKEN|_KEY$|^KEY$|_KEY_|KEYFILE|APIKEY|API_KEY|PASSWORD|PASSWD|PASSPHRASE|PASSCODE|PASSKEY|_PASS$|^PASS$|_PASS_|_PW$|^PW$|PINCODE|_PIN$|^PIN$|CREDENTIAL|PRIVATE|PRIVKEY|SIGNING|SIGNATURE|HMAC|BEARER|SALT|CERT|_DSN$|DATABASE_URL|REDIS_URL|MONGO_URI|MONGODB_URI|AMQP_URL|CONNECTION_STRING|ACCESS_KEY|SECRET_KEY|CLIENT_SECRET|WEBHOOK|SERVICE_ROLE|_PAT$|AUTH|SESSION|COOKIE|ENCRYPT|CIPHER|SEED|MNEMONIC|OTP|_SID$|LICENSE)'

# The ONLY names that may become literals. Exact matches, no wildcards: an
# earlier PUBLIC_* prefix let PUBLIC_PASSCODE through, and MAX_* let MAX_KEYS.
# Add a name here only if no plausible value of it could be a credential.
CLASSIFY_CONFIG_EXACT=' NODE_ENV ENV ENVIRONMENT APP_ENV RAILS_ENV RACK_ENV GO_ENV FLASK_ENV DJANGO_ENV MIX_ENV PORT HOST HOSTNAME BIND_ADDR LISTEN_ADDR LOG_LEVEL LOGLEVEL LOG_FORMAT DEBUG VERBOSE TZ TIMEZONE LANG LC_ALL LOCALE CI NODE_OPTIONS GOOS GOARCH GOFLAGS VERSION APP_VERSION APP_NAME SERVICE_NAME PROJECT_NAME TIMEOUT WORKERS REPLICAS CONCURRENCY RETRIES POOL_SIZE REGION AWS_REGION AWS_DEFAULT_REGION GCP_REGION GOOGLE_CLOUD_REGION CLOUD_REGION API_URL BASE_URL SITE_URL APP_URL PUBLIC_URL FRONTEND_URL BACKEND_URL API_BASE_URL NEXT_PUBLIC_API_URL NEXT_PUBLIC_SITE_URL NEXT_PUBLIC_APP_URL VITE_API_URL VITE_APP_URL CORS_ORIGIN ALLOWED_ORIGINS DB_HOST DB_PORT DB_NAME DATABASE_HOST DATABASE_PORT DATABASE_NAME REDIS_HOST REDIS_PORT SMTP_HOST SMTP_PORT MAIL_HOST MAIL_PORT '

# Template syntax that cannot be a live value. Deliberately NOT words: `changeme`,
# `password`, `test` and `your-*` were all here once and each is a possible real
# (bad) value.
CLASSIFY_TEMPLATE='^(<[^>]*>|\$\{[^}]*\}|\$[A-Za-z_][A-Za-z0-9_]*|x{3,}|X{3,}|\.\.\.)$'

# classify_var <name> <value>
#   -> secret | config | placeholder | reference | empty | ambiguous
classify_var() {
  local name="$1" value="$2"

  [[ -z "$value" ]] && { printf 'empty'; return; }

  # Already a reference: written through as-is, never re-vaulted. Validity is
  # checked separately by is_op_ref; an invalid one must not be printed either.
  [[ "$value" == op://* ]] && { printf 'reference'; return; }

  # Shape first: a value that is recognisably a credential is one whatever the
  # variable is called. This can only promote to `secret`, never demote.
  _looks_secret "$value" && { printf 'secret'; return; }

  local uname; uname=$(_toupper "$name")

  if [[ "$uname" =~ $CLASSIFY_SECRET_NAME ]]; then
    [[ "$value" =~ $CLASSIFY_TEMPLATE ]] && { printf 'placeholder'; return; }
    printf 'secret'; return
  fi

  [[ "$value" =~ $CLASSIFY_TEMPLATE ]] && { printf 'placeholder'; return; }

  # The single route to a literal for a non-secret name: exact allowlist match.
  # A URL-typed allowlisted name is still refused when the URL carries userinfo or
  # a credential-looking query parameter — _looks_secret above already caught it.
  case "$CLASSIFY_CONFIG_EXACT" in
    *" $uname "*) printf 'config'; return ;;
  esac

  printf 'ambiguous'
}

# is_op_ref <value> -> 0 if the value is a syntactically plausible op:// reference
# that is safe to print: vault/item/[section/]field, no control characters, no
# quotes. Anything else beginning with op:// is treated as an opaque value.
is_op_ref() {
  local v="$1"
  [[ "$v" == op://* ]] || return 1
  [[ "$v" =~ [[:cntrl:]] ]] && return 1
  [[ "$v" == *[\"\'\`\\]* ]] && return 1
  local rest="${v#op://}" n=0 part
  local IFS='/'
  for part in $rest; do
    [[ -n "$part" ]] || return 1
    n=$((n + 1))
  done
  (( n >= 3 && n <= 4 ))
}

_toupper() {
  local s="$1" out="" i c
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-z]) out+=$(_swapcase "$c" upper) ;;
      *)     out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

_tolower() {
  local s="$1" out="" i c
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [A-Z]) out+=$(_swapcase "$c" lower) ;;
      *)     out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

# bash 3.2 (what macOS ships) has neither ${v^^} nor ${v,,}.
_swapcase() {
  local u=ABCDEFGHIJKLMNOPQRSTUVWXYZ l=abcdefghijklmnopqrstuvwxyz i
  if [[ "$2" == upper ]]; then
    i="${l%%"$1"*}"; printf '%s' "${u:${#i}:1}"
  else
    i="${u%%"$1"*}"; printf '%s' "${l:${#i}:1}"
  fi
}

# Shapes that are secrets whatever they are called.
_looks_secret() {
  local v="$1"
  [[ "$v" == *"-----BEGIN "*"PRIVATE KEY-----"* ]] && return 0
  # A JWT anywhere in the value, not only at the start: a magic-link URL carries
  # one mid-string.
  [[ "$v" =~ eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,} ]] && return 0
  [[ "$v" =~ (^|[^A-Za-z0-9])eyJ[A-Za-z0-9_-]{10,}\. ]] && return 0
  [[ "$v" =~ (^|[^A-Za-z0-9])A(KIA|SIA)[0-9A-Z]{16}([^A-Za-z0-9]|$) ]] && return 0
  [[ "$v" =~ (^|[^A-Za-z0-9])gh[pousr]_[A-Za-z0-9]{30,} ]] && return 0
  [[ "$v" =~ (^|[^A-Za-z0-9])github_pat_[A-Za-z0-9_]{20,} ]] && return 0
  [[ "$v" =~ (^|[^A-Za-z0-9])xox[baprs]- ]] && return 0
  [[ "$v" =~ (^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{20,} ]] && return 0
  [[ "$v" =~ (^|[^A-Za-z0-9])(sk|rk)_(live|test)_[A-Za-z0-9]{20,} ]] && return 0
  [[ "$v" =~ (^|[^A-Za-z0-9])glpat-[A-Za-z0-9_-]{15,} ]] && return 0
  [[ "$v" =~ (^|[^A-Za-z0-9])npm_[A-Za-z0-9]{30,} ]] && return 0
  # A URL carrying credentials in userinfo or a query parameter.
  [[ "$v" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*://[^/@[:space:]]+:[^/@[:space:]]+@ ]] && return 0
  [[ "$v" =~ [?\&](token|key|api_?key|apikey|secret|password|passwd|pass|pwd|sig|signature|access_token|refresh_token|id_token|auth|credential|code|otp|pin|session|sid|ticket|nonce|hash)= ]] && return 0
  _url_token_segment "$v" && return 0
  # Long, mixed-charset strings with no spaces: the shape of a generated key.
  if (( ${#v} >= 24 )) && [[ ! "$v" =~ [[:space:]] ]] \
     && [[ "$v" =~ [A-Za-z] ]] && [[ "$v" =~ [0-9] ]] \
     && [[ ! "$v" =~ ^https?:// ]]; then
    return 0
  fi
  [[ "$v" =~ ^[0-9a-fA-F]{32,}$ ]] && return 0
  return 1
}

# Does any path/query segment of an http(s) URL look like a credential?
_url_token_segment() {
  local v="$1" hostpath rest seg
  [[ "$v" =~ ^https?:// ]] || return 1
  hostpath="${v#*://}"
  case "$hostpath" in
    */*) rest="${hostpath#*/}" ;;
    *)   return 1 ;;
  esac
  # set -f: the unquoted expansion below is for word splitting only; without it a
  # segment like `*` would glob against the current directory.
  local IFS='/?&=' saved_opts="$-"
  set -f
  for seg in $rest; do
    if (( ${#seg} >= 20 )) && [[ "$seg" =~ ^[A-Za-z0-9_~-]+$ ]] && [[ "$seg" != *.* ]]; then
      [[ "$saved_opts" != *f* ]] && set +f
      return 0
    fi
  done
  [[ "$saved_opts" != *f* ]] && set +f
  return 1
}

# describe_value <value> -> a redacted shape, e.g. "36 chars · lower/UPPER/digits"
# Used when asking you about an ambiguous variable. Enough to decide, not enough
# to leak.
describe_value() {
  local v="$1" cls=""
  [[ "$v" =~ [a-z] ]] && cls+="lower"
  [[ "$v" =~ [A-Z] ]] && cls+="${cls:+/}HOA"
  [[ "$v" =~ [0-9] ]] && cls+="${cls:+/}digits"
  [[ "$v" =~ [^A-Za-z0-9] ]] && cls+="${cls:+/}symbols"
  local shape=""
  [[ "$v" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*:// ]] && shape=" · URL-shaped"
  [[ "$v" =~ [[:space:]] ]] && shape+=" · has whitespace"
  [[ "$v" == *$'\n'* ]] && shape+=" · multiline"
  printf '%d chars · %s%s' "${#v}" "${cls:-?}" "$shape"
}
