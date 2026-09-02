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
# jq is the common case; python3 is the fallback that ships with macOS. Both
# missing is fatal rather than silently returning empty, because an empty config
# value would otherwise be read as "not set" and produce a wrong default.
kl_json_get() { # <file> <dotted.path>  -> value, or empty when absent
  local file=$1 path=$2
  [ -f "$file" ] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg p "$path" '
      reduce ($p | split(".")[]) as $k (.; if type == "object" then .[$k] else null end)
      | if . == null then "" elif type == "array" then join(" ") else tostring end
    ' "$file"
  elif command -v python3 >/dev/null 2>&1; then
    KL_PATH="$path" python3 -c '
import json, os, sys
node = json.load(open(sys.argv[1]))
for key in os.environ["KL_PATH"].split("."):
    node = node.get(key) if isinstance(node, dict) else None
    if node is None:
        print("")
        sys.exit(0)
print(" ".join(map(str, node)) if isinstance(node, list) else node)
' "$file"
  else
    kl_die "need jq or python3 to read $file"
  fi
}

# --- config ----------------------------------------------------------------
# Walk up from $PWD looking for .k8s-local/project.json, the way git finds its
# root. Lets klocal run from any subdirectory of the project.
kl_find_config() {
  local dir=${1:-$PWD}
  while [ "$dir" != "/" ]; do
    if [ -f "$dir/.k8s-local/project.json" ]; then
      printf '%s\n' "$dir/.k8s-local/project.json"
      return 0
    fi
    dir=$(dirname "$dir")
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

  KL_NAMESPACE=$(kl_json_get "$KL_CONFIG" namespace)
  [ -n "$KL_NAMESPACE" ] || KL_NAMESPACE="${KL_PROJECT}-local"

  KL_IMAGE=$(kl_json_get "$KL_CONFIG" image.name)
  [ -n "$KL_IMAGE" ] || KL_IMAGE="${KL_PROJECT}-api:local"
  KL_IMAGE_CONTEXT=$(kl_json_get "$KL_CONFIG" image.context)
  [ -n "$KL_IMAGE_CONTEXT" ] || KL_IMAGE_CONTEXT="."

  KL_MANIFESTS=$(kl_json_get "$KL_CONFIG" manifests)
  [ -n "$KL_MANIFESTS" ] || KL_MANIFESTS="deploy/k8s-local"

  KL_APP=$(kl_json_get "$KL_CONFIG" workloads.app)
  [ -n "$KL_APP" ] || KL_APP="${KL_PROJECT}-api"
  KL_DB=$(kl_json_get "$KL_CONFIG" workloads.db)
  KL_CACHE=$(kl_json_get "$KL_CONFIG" workloads.cache)

  KL_INGRESS_CLASS=$(kl_json_get "$KL_CONFIG" ingressClass)
  [ -n "$KL_INGRESS_CLASS" ] || KL_INGRESS_CLASS="traefik"
  KL_ROOT_DOMAIN=$(kl_json_get "$KL_CONFIG" rootDomain)
  [ -n "$KL_ROOT_DOMAIN" ] || KL_ROOT_DOMAIN="lvh.me"

  KL_SECRET=$(kl_json_get "$KL_CONFIG" secret.name)
  KL_SECRET_ENV_FILE=$(kl_json_get "$KL_CONFIG" secret.envFile)
  KL_SECRET_HOOK=$(kl_json_get "$KL_CONFIG" secret.hook)

  KL_DB_NAME=$(kl_json_get "$KL_CONFIG" database.name)
  KL_DB_SUPERUSER=$(kl_json_get "$KL_CONFIG" database.superuser)
  KL_DB_APP_ROLE=$(kl_json_get "$KL_CONFIG" database.appRole)

  KL_TLS_PORT=$(kl_json_get "$KL_CONFIG" tls.port)
  KL_TLS_CERT_DIR=$(kl_json_get "$KL_CONFIG" tls.certDir)
  # A leading ~ in JSON is literal; expand it here or every path breaks.
  case "$KL_TLS_CERT_DIR" in "~"/*) KL_TLS_CERT_DIR="$HOME/${KL_TLS_CERT_DIR#\~/}" ;; esac
}
