#!/usr/bin/env bash
# Deciding which variables belong in the vault, without ever printing a value.
#
# FAIL CLOSED. The output of this file decides whether a value is written as an
# op:// reference or copied verbatim into `.env.op`, a file the docs tell you to
# commit. Misclassifying a secret as configuration therefore does not merely fail
# to protect it — it moves a secret that was sitting on disk into git.
#
# So `config` requires positive evidence from the variable NAME. No rule may
# demote a variable to a literal on the strength of its value looking harmless: an
# earlier version treated anything short and simple as configuration, which made
# `DB_PASS=hunter2` a committable literal. Anything not proven to be either a
# secret or configuration comes back `ambiguous`, and the caller asks a human.
#
# Every function works on the value using bash builtins only. Passing a secret to
# an external command would put it in that command's argv, where any process
# running as you can read it.

# Names that are secrets regardless of what the value looks like. Matched against
# the upper-cased name, so `db_pass` counts.
CLASSIFY_SECRET_NAME='(SECRET|TOKEN|_KEY$|^KEY$|_KEY_|KEYFILE|APIKEY|API_KEY|PASSWORD|PASSWD|PASSPHRASE|_PASS$|^PASS$|_PASS_|_PW$|^PW$|CREDENTIAL|PRIVATE|SIGNING|SIGNATURE|SALT|_DSN$|DATABASE_URL|REDIS_URL|CONNECTION_STRING|ACCESS_KEY|SECRET_KEY|CLIENT_SECRET|WEBHOOK|SERVICE_ROLE|_PAT$|AUTH|SESSION|COOKIE|ENCRYPT|CIPHER|SEED|MNEMONIC|PIN$|OTP|_SID$|LICENSE_KEY)'

# Names that are configuration. This is an allowlist and the ONLY route to a
# literal: a name must be recognised here to be written into a committable file.
CLASSIFY_CONFIG_NAME='^(NODE_ENV|ENV|ENVIRONMENT|APP_ENV|RAILS_ENV|GO_ENV|PORT|[A-Z0-9_]*_PORT|HOST|HOSTNAME|[A-Z0-9_]*_HOSTNAME|LOG_LEVEL|LOGLEVEL|DEBUG|VERBOSE|TZ|TIMEZONE|LANG|LC_ALL|CI|NODE_OPTIONS|GOOS|GOARCH|VERSION|APP_NAME|APP_VERSION|SERVICE_NAME|TIMEOUT|[A-Z0-9_]*_TIMEOUT|MAX_[A-Z0-9_]*|MIN_[A-Z0-9_]*|POOL_SIZE|WORKERS|REPLICAS|CONCURRENCY|RETRIES|LOCALE|REGION|AWS_REGION|AWS_DEFAULT_REGION|NEXT_PUBLIC_[A-Z0-9_]*|PUBLIC_[A-Z0-9_]*|VITE_PUBLIC_[A-Z0-9_]*|REACT_APP_PUBLIC_[A-Z0-9_]*)$'

# Values that cannot plausibly be a real credential. Kept deliberately small:
# `password`, `secret`, `test`, `dummy` and `example` were here once, and each is a
# perfectly possible (bad) real value, so treating them as blanks would have
# written a live credential into a committable file.
CLASSIFY_PLACEHOLDER='^(changeme|change-me|change_me|your[-_][a-z0-9_-]*|your[a-z0-9_-]*here|replace[-_]?me|replace[-_][a-z0-9_-]*|todo|tbd|fixme|n/a|none|null|xxx+|\.\.\.|<[^>]*>|\$\{[^}]*\}|\$[A-Z_][A-Z0-9_]*)$'

# classify_var <name> <value> -> secret | config | placeholder | empty | ambiguous
classify_var() {
  local name="$1" value="$2"

  [[ -z "$value" ]] && { printf 'empty'; return; }

  local uname; uname=$(_toupper "$name")

  # Shape first: a value that is recognisably a credential is one no matter what
  # the variable is called.
  _looks_secret "$value" && { printf 'secret'; return; }

  if [[ "$uname" =~ $CLASSIFY_SECRET_NAME ]]; then
    # The only demotion allowed for a secret-named variable, and only for markers
    # that cannot be a real value.
    _is_placeholder "$value" && { printf 'placeholder'; return; }
    printf 'secret'; return
  fi

  _is_placeholder "$value" && { printf 'placeholder'; return; }

  # The only two routes to a literal, both requiring positive evidence.
  [[ "$uname" =~ $CLASSIFY_CONFIG_NAME ]] && { printf 'config'; return; }
  _is_plain_url "$value" && { printf 'config'; return; }

  printf 'ambiguous'
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

_is_placeholder() {
  local l; l=$(_tolower "$1")
  [[ "$l" =~ $CLASSIFY_PLACEHOLDER ]]
}

# Shapes that are secrets whatever they are called.
_looks_secret() {
  local v="$1"
  [[ "$v" == *"-----BEGIN "*"PRIVATE KEY-----"* ]] && return 0
  # A JWT anywhere in the value, not only at the start: a magic-link URL carries
  # one mid-string, and anchoring on ^ let those through as ordinary URLs.
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
  # A URL carrying credentials in userinfo or in a query parameter.
  [[ "$v" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*://[^/@[:space:]]+:[^/@[:space:]]+@ ]] && return 0
  [[ "$v" =~ [?\&](token|key|api_?key|apikey|secret|password|passwd|sig|signature|access_token|auth|credential)= ]] && return 0
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
# Deliberately does NOT require a digit: a Slack webhook's final segment is often
# letters only, and requiring digits let it through as an ordinary URL.
_url_token_segment() {
  local v="$1" hostpath rest seg
  [[ "$v" =~ ^https?:// ]] || return 1
  hostpath="${v#*://}"
  case "$hostpath" in
    */*) rest="${hostpath#*/}" ;;
    *)   return 1 ;;
  esac
  local IFS='/?&='
  for seg in $rest; do
    if (( ${#seg} >= 20 )) && [[ "$seg" =~ ^[A-Za-z0-9_~-]+$ ]] && [[ "$seg" != *.* ]]; then
      return 0
    fi
  done
  return 1
}

# An http(s) URL carrying neither userinfo nor a token-shaped path segment.
_is_plain_url() {
  local v="$1"
  [[ "$v" =~ ^https?://[^[:space:]]+$ ]] || return 1
  [[ "$v" == *@* ]] && return 1
  _url_token_segment "$v" && return 1
  return 0
}

# describe_value <value> -> a redacted shape, e.g. "36 ký tự · thường/HOA/số"
# Used when asking you about an ambiguous variable. It must be enough to decide
# without being enough to leak.
describe_value() {
  local v="$1" cls=""
  [[ "$v" =~ [a-z] ]] && cls+="thường"
  [[ "$v" =~ [A-Z] ]] && cls+="${cls:+/}HOA"
  [[ "$v" =~ [0-9] ]] && cls+="${cls:+/}số"
  [[ "$v" =~ [^A-Za-z0-9] ]] && cls+="${cls:+/}ký hiệu"
  local shape=""
  [[ "$v" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*:// ]] && shape=" · dạng URL"
  [[ "$v" =~ [[:space:]] ]] && shape+=" · có khoảng trắng"
  [[ "$v" == *$'\n'* ]] && shape+=" · nhiều dòng"
  printf '%d ký tự · %s%s' "${#v}" "${cls:-?}" "$shape"
}
