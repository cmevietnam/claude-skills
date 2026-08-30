#!/usr/bin/env bash
# Deciding which variables belong in the vault, without ever printing a value.
#
# Every function here works on the value using bash builtins only. Passing a
# secret to an external command would put it in that command's argv, where any
# process running as you can read it — the exact bug this plugin already had once.

# Names that are secrets regardless of what the value looks like.
CLASSIFY_SECRET_NAME='(SECRET|TOKEN|_KEY$|^KEY$|_KEY_|APIKEY|API_KEY|PASSWORD|PASSWD|^PWD$|CREDENTIAL|PRIVATE|SIGNING|SALT|_DSN$|DATABASE_URL|REDIS_URL|CONNECTION_STRING|ACCESS_KEY|SECRET_KEY|CLIENT_SECRET|WEBHOOK_URL|SERVICE_ROLE|_PAT$|AUTH_TOKEN|SESSION_SECRET|COOKIE_SECRET|ENCRYPTION)'

# Names that are configuration, regardless of what the value looks like.
CLASSIFY_CONFIG_NAME='^(NODE_ENV|ENV|ENVIRONMENT|PORT|HOST|HOSTNAME|LOG_LEVEL|LOGLEVEL|DEBUG|TZ|LANG|LC_ALL|NEXT_PUBLIC_[A-Z0-9_]*|VITE_[A-Z0-9_]*PUBLIC[A-Z0-9_]*|PUBLIC_[A-Z0-9_]*|CI|NODE_OPTIONS|GOOS|GOARCH|VERSION|APP_NAME|APP_ENV|TIMEOUT|MAX_[A-Z0-9_]*|MIN_[A-Z0-9_]*|POOL_SIZE|WORKERS|REPLICAS)$'

# Values that are obviously not real secrets yet.
CLASSIFY_PLACEHOLDER='^(changeme|change-me|xxx+|yyy+|todo|tbd|your[-_a-z]*|replace[-_a-z]*|example|placeholder|dummy|test|secret|password|<.*>|\$\{.*\}|\.\.\.)$'

# classify_var <name> <value> -> secret | config | placeholder | empty | ambiguous
classify_var() {
  local name="$1" value="$2"

  [[ -z "$value" ]] && { printf 'empty'; return; }

  if [[ "$name" =~ $CLASSIFY_SECRET_NAME ]]; then
    # A secret-looking name holding a placeholder is still not worth vaulting.
    _is_placeholder "$value" && { printf 'placeholder'; return; }
    printf 'secret'; return
  fi

  _looks_secret "$value" && { printf 'secret'; return; }

  if [[ "$name" =~ $CLASSIFY_CONFIG_NAME ]]; then printf 'config'; return; fi

  _is_placeholder "$value" && { printf 'placeholder'; return; }

  # A URL with no credentials and no token-shaped path segment is an endpoint, not
  # a secret. The path check matters: a Slack or Discord webhook looks like an
  # ordinary URL but carries its credential in the path.
  _is_plain_url "$value" && { printf 'config'; return; }

  # Short, simple values are configuration in practice: ports, flags, hostnames.
  if (( ${#value} < 12 )) && [[ ! "$value" =~ [^A-Za-z0-9._:-] ]]; then
    printf 'config'; return
  fi

  printf 'ambiguous'
}

_is_placeholder() {
  local v="$1" l=""
  # Lowercase without calling out to tr/awk.
  local i c
  for (( i = 0; i < ${#v}; i++ )); do
    c="${v:i:1}"
    case "$c" in
      [A-Z]) l+=$(_tolower "$c") ;;
      *) l+="$c" ;;
    esac
  done
  [[ "$l" =~ $CLASSIFY_PLACEHOLDER ]]
}

_tolower() {
  case "$1" in
    A) printf a;; B) printf b;; C) printf c;; D) printf d;; E) printf e;; F) printf f;;
    G) printf g;; H) printf h;; I) printf i;; J) printf j;; K) printf k;; L) printf l;;
    M) printf m;; N) printf n;; O) printf o;; P) printf p;; Q) printf q;; R) printf r;;
    S) printf s;; T) printf t;; U) printf u;; V) printf v;; W) printf w;; X) printf x;;
    Y) printf y;; Z) printf z;; *) printf '%s' "$1";;
  esac
}

# Shapes that are secrets whatever they are called.
_looks_secret() {
  local v="$1"
  # Known credential formats, most specific first.
  [[ "$v" == *"-----BEGIN "*"PRIVATE KEY-----"* ]] && return 0
  [[ "$v" =~ ^eyJ[A-Za-z0-9_-]{10,}\. ]] && return 0                 # JWT
  [[ "$v" =~ ^AKIA[0-9A-Z]{16}$ ]] && return 0                       # AWS access key id
  [[ "$v" =~ ^gh[pousr]_[A-Za-z0-9]{30,}$ ]] && return 0             # GitHub token
  [[ "$v" =~ ^xox[baprs]- ]] && return 0                             # Slack
  [[ "$v" =~ ^sk-[A-Za-z0-9_-]{20,}$ ]] && return 0                  # OpenAI-style
  [[ "$v" =~ ^(sk|pk|rk)_(live|test)_[A-Za-z0-9]{20,}$ ]] && return 0 # Stripe
  [[ "$v" =~ ^glpat-[A-Za-z0-9_-]{15,}$ ]] && return 0               # GitLab PAT
  # A URL carrying credentials: scheme://user:pass@host
  [[ "$v" =~ ^[a-zA-Z][a-zA-Z0-9+.-]*://[^/@[:space:]]+:[^/@[:space:]]+@ ]] && return 0
  # A URL whose path carries a token: a Slack/Discord webhook is a credential
  # wearing a URL as a costume.
  _url_token_segment "$v" && return 0
  # Long, mixed-charset strings with no spaces: the shape of a generated key.
  # URLs are exempt and judged by the rule above instead — an earlier version
  # exempted them with `^https?://[^:@]*$`, which a port number defeats.
  if (( ${#v} >= 24 )) && [[ ! "$v" =~ [[:space:]] ]] \
     && [[ "$v" =~ [A-Za-z] ]] && [[ "$v" =~ [0-9] ]] \
     && [[ ! "$v" =~ ^https?:// ]]; then
    return 0
  fi
  # Long hex — a hash or a raw key.
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
    *)   return 1 ;;                 # host only, no path
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
  [[ "$v" == *@* ]] && return 1                       # userinfo -> handled as secret
  _url_token_segment "$v" && return 1
  return 0
}

# describe_value <value> -> a redacted shape, e.g. "36 ký tự · chữ+số+ký hiệu"
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
