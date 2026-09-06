# Shared helpers for klocal: output, failure, and reading .k8s-local/project.json.
#
# Sourced, never executed. No side effects at source time beyond defining
# functions, so the test suite can source this file and call one function in
# isolation.

# --- output ----------------------------------------------------------------
# Everything diagnostic goes to stderr, so a subcommand's real output can be
# piped without the chatter coming along.
kl_info() { printf '==> %s\n' "$*" >&2; }
kl_step() { printf '    %s\n' "$*" >&2; }
kl_warn() { printf 'WARNING: %s\n' "$*" >&2; }
kl_die() {
  printf 'klocal: %s\n' "$*" >&2
  exit 1
}

# --- json ------------------------------------------------------------------
# jq is the common case; python3 is the fallback that ships with macOS. The two
# must agree EXACTLY, or which backend happens to be installed silently changes
# what the tool operates on: Python's str(False) is "False", which is not a legal
# Kubernetes name, while jq's tostring is "false", which is. Both paths below
# therefore emit JSON spellings (lowercase booleans, null as empty) and both
# refuse a non-scalar list rather than rendering a language-specific repr.
kl_json_get() { # <file> <dotted.path>  -> value, or empty when absent
  local file=$1 path=$2
  [ -f "$file" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -er --arg p "$path" '
      def scalar: if type == "boolean" or type == "number" then tostring
                  elif type == "string" then .
                  else error("not a scalar: " + type) end;
      reduce ($p | split(".")[]) as $k (.; if type == "object" then .[$k] else null end)
      | if . == null then ""
        elif type == "array" then (map(scalar) | join(" "))
        else scalar end
    ' "$file" 2>/dev/null || {
      # jq exits non-zero on a non-scalar; say so rather than returning empty,
      # which the caller would read as "key absent" and replace with a default.
      kl_die "$file: value at '$path' is not a scalar or list of scalars"
    }
  elif command -v python3 >/dev/null 2>&1; then
    KL_PATH="$path" python3 -c '
import json, math, os, sys

def scalar(v):
    if isinstance(v, bool):
        return "true" if v else "false"      # match jq, not Python
    if isinstance(v, str):
        return v
    if isinstance(v, (int, float)):
        # jq holds every number as an IEEE double and prints an integral one
        # without a fractional part. Rendering with Python semantics instead made
        # 1.0 -> "1.0" (jq: "1") and kept 9007199254740993 exactly (jq: ...992),
        # so which backend was installed decided whether a config value was
        # accepted. Go through float to get jq behaviour exactly.
        f = float(v)
        if math.isinf(f) or math.isnan(f):
            raise SystemExit("not a finite number")
        if f.is_integer():
            # jq prints negative zero as -0; int() would flatten it to 0.
            if f == 0 and math.copysign(1.0, f) < 0:
                return "-0"
            return str(int(f))
        return repr(f)
    raise SystemExit("not a scalar")

# parse_int=float mirrors jq, which has only doubles. Without it Python keeps
# -0 as the integer 0 (losing the sign jq prints) and 9007199254740993 exactly.
node = json.load(open(sys.argv[1]), parse_int=float)
for key in os.environ["KL_PATH"].split("."):
    node = node.get(key) if isinstance(node, dict) else None
    if node is None:
        print("")
        sys.exit(0)
print(" ".join(scalar(x) for x in node) if isinstance(node, list) else scalar(node))
' "$file" 2>/dev/null || {
      kl_die "$file: value at '$path' is not a scalar or list of scalars"
    }
  else
    kl_die "need jq or python3 to read $file"
  fi
}

# --- validation ------------------------------------------------------------
# Names from the config file are passed to kubectl as positional arguments.
# Quoting them stops word-splitting but does NOT stop kubectl reading a leading
# dash as a flag: a namespace of "--all" turns `kubectl delete namespace $NS`
# into `kubectl delete namespace --all`, which deletes every namespace on the
# cluster. So every such value is validated before it is ever used.
# RFC1123 label: what Kubernetes accepts for a namespace.
#
# Implemented with `case`, not `grep`: grep -q succeeds when ANY line matches, so
# a multiline value like $'valid\n--context=prod' passed the anchored pattern and
# then reached kubectl as an argument. A negated glob set has no such hole — a
# newline is simply not in [a-z0-9-].
kl_is_dns_label() {
  case "$1" in
    "" | -* | *-) return 1 ;;
    *[!a-z0-9-]*) return 1 ;;
  esac
  [ "${#1}" -le 63 ]
}

# A bare SQL identifier. Deliberately narrow: psql's -d accepts a full connection
# URI, so a "database name" of postgresql://postgres@prod-db/production silently
# redirects the session to production AND overrides -U, which defeats --app.
kl_is_pg_ident() {
  case "$1" in
    "" | [!a-zA-Z_]*) return 1 ;;
    *[!a-zA-Z0-9_]*) return 1 ;;
  esac
  [ "${#1}" -le 63 ]
}

kl_require_pg_ident() { # <config-key> <value>
  kl_is_pg_ident "$2" || kl_die \
    "$KL_CONFIG: \"$1\" must be a bare identifier (letters, digits, _), got: '$2'.
       A connection URI here would redirect psql to another server and override --app."
}

kl_require_dns_label() { # <config-key> <value>
  kl_is_dns_label "$2" || kl_die \
    "$KL_CONFIG: \"$1\" must be a lowercase DNS label (a-z, 0-9, -), got: '$2'"
}

# Looser: image references legitimately carry / : . and _ , but must never begin
# with a dash for the same reason as above.
kl_require_safe_arg() { # <config-key> <value>
  case "$2" in
    "" | -*) kl_die "$KL_CONFIG: \"$1\" must not be empty or begin with '-', got: '$2'" ;;
  esac
  case "$2" in
    *[[:space:]]*) kl_die "$KL_CONFIG: \"$1\" must not contain whitespace, got: '$2'" ;;
  esac
}

# A TCP port. This one is not decoration: the value is interpolated into a `sed`
# program that builds the reachable URL, so a `|` closed the substitution and the
# rest became further sed commands — `w /path` writes a file anywhere the user
# can write. Even without malice, `&` is sed's whole-match replacement, so a port
# of "80&81" silently rendered as ":8081".
kl_require_port() { # <config-key> <value>
  case "$2" in
    "" | *[!0-9]*) kl_die "$KL_CONFIG: \"$1\" must be a number, got: '$2'" ;;
  esac
  [ "${#2}" -le 5 ] && [ "$2" -ge 1 ] && [ "$2" -le 65535 ] 2>/dev/null || kl_die \
    "$KL_CONFIG: \"$1\" must be a port between 1 and 65535, got: '$2'"
}

# --- config ----------------------------------------------------------------
# Walk up from $PWD looking for .k8s-local/project.json, the way git finds its
# root. Lets klocal run from any subdirectory of the project.
# Terminates on "the parent stopped changing", not on "we reached /". dirname
# is a fixed point at BOTH "/" and ".", so a relative starting directory spun
# forever: dirname "." is ".". Making the path absolute first is the real fix;
# the fixed-point test is the floor under it, so no future caller can reintroduce
# a loop with no exit.
kl_find_config() {
  local dir=${1:-$PWD} prev=""
  case "$dir" in
    /*) ;;
    *) dir=$(cd -- "$dir" 2>/dev/null && pwd -P) || return 1 ;;
  esac
  while [ -n "$dir" ] && [ "$dir" != "$prev" ]; do
    if [ -f "$dir/.k8s-local/project.json" ]; then
      printf '%s\n' "$dir/.k8s-local/project.json"
      return 0
    fi
    prev=$dir
    dir=$(dirname -- "$dir")
  done
  return 1
}

# Populates KL_* globals. Every default here is the value that is correct when
# the key is simply absent; nothing is guessed from the environment.
kl_load_config() {
  KL_CONFIG=$(kl_find_config "$PWD") || kl_die \
    "no .k8s-local/project.json found in $PWD or any parent — run: klocal scaffold"
  KL_ROOT=$(dirname "$(dirname "$KL_CONFIG")")

  KL_PROJECT=$(kl_json_get "$KL_CONFIG" project)
  [ -n "$KL_PROJECT" ] || kl_die "$KL_CONFIG: \"project\" is required"
  kl_require_dns_label project "$KL_PROJECT"

  KL_NAMESPACE=$(kl_json_get "$KL_CONFIG" namespace)
  [ -n "$KL_NAMESPACE" ] || KL_NAMESPACE="${KL_PROJECT}-local"
  kl_require_dns_label namespace "$KL_NAMESPACE"

  KL_IMAGE=$(kl_json_get "$KL_CONFIG" image.name)
  [ -n "$KL_IMAGE" ] || KL_IMAGE="${KL_PROJECT}-api:local"
  kl_require_safe_arg image.name "$KL_IMAGE"
  KL_IMAGE_CONTEXT=$(kl_json_get "$KL_CONFIG" image.context)
  [ -n "$KL_IMAGE_CONTEXT" ] || KL_IMAGE_CONTEXT="."

  KL_MANIFESTS=$(kl_json_get "$KL_CONFIG" manifests)
  [ -n "$KL_MANIFESTS" ] || KL_MANIFESTS="deploy/k8s-local"

  KL_APP=$(kl_json_get "$KL_CONFIG" workloads.app)
  [ -n "$KL_APP" ] || KL_APP="${KL_PROJECT}-api"
  kl_require_dns_label workloads.app "$KL_APP"
  KL_DB=$(kl_json_get "$KL_CONFIG" workloads.db)
  [ -z "$KL_DB" ] || kl_require_dns_label workloads.db "$KL_DB"
  KL_CACHE=$(kl_json_get "$KL_CONFIG" workloads.cache)
  [ -z "$KL_CACHE" ] || kl_require_dns_label workloads.cache "$KL_CACHE"

  # Unvalidated, this reaches kubectl as a positional argument — and a value of
  # "--context=prod" is read as a global flag that OVERRIDES the pinned context,
  # because a later --context wins.
  KL_INGRESS_CLASS=$(kl_json_get "$KL_CONFIG" ingressClass)
  [ -n "$KL_INGRESS_CLASS" ] || KL_INGRESS_CLASS="traefik"
  kl_require_dns_label ingressClass "$KL_INGRESS_CLASS"
  KL_ROOT_DOMAIN=$(kl_json_get "$KL_CONFIG" rootDomain)
  [ -n "$KL_ROOT_DOMAIN" ] || KL_ROOT_DOMAIN="lvh.me"

  KL_SECRET=$(kl_json_get "$KL_CONFIG" secret.name)
  [ -z "$KL_SECRET" ] || kl_require_dns_label secret.name "$KL_SECRET"
  KL_SECRET_ENV_FILE=$(kl_json_get "$KL_CONFIG" secret.envFile)
  KL_SECRET_HOOK=$(kl_json_get "$KL_CONFIG" secret.hook)

  KL_DB_NAME=$(kl_json_get "$KL_CONFIG" database.name)
  [ -z "$KL_DB_NAME" ] || kl_require_pg_ident database.name "$KL_DB_NAME"
  KL_DB_SUPERUSER=$(kl_json_get "$KL_CONFIG" database.superuser)
  [ -z "$KL_DB_SUPERUSER" ] || kl_require_pg_ident database.superuser "$KL_DB_SUPERUSER"
  KL_DB_APP_ROLE=$(kl_json_get "$KL_CONFIG" database.appRole)
  [ -z "$KL_DB_APP_ROLE" ] || kl_require_pg_ident database.appRole "$KL_DB_APP_ROLE"

  KL_TLS_PORT=$(kl_json_get "$KL_CONFIG" tls.port)
  [ -z "$KL_TLS_PORT" ] || kl_require_port tls.port "$KL_TLS_PORT"
  KL_TLS_CERT_DIR=$(kl_json_get "$KL_CONFIG" tls.certDir)
  # A leading ~ in JSON is literal; expand it here or every path breaks.
  case "$KL_TLS_CERT_DIR" in "~"/*) KL_TLS_CERT_DIR="$HOME/${KL_TLS_CERT_DIR#\~/}" ;; esac
}
