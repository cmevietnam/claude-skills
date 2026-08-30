#!/usr/bin/env bash
# Shared paths, logging and small helpers for opgate.
# Sourced by bin/opgate, scripts/build-gate.sh and scripts/lib/gate.sh.

# --- paths ------------------------------------------------------------------
# Deliberately NOT honouring XDG_DATA_HOME: the gate binary's location must not be
# redirectable through the environment, or anything that can set a variable can
# point us at a fake gate that exits 0.
OPGATE_HOME="$HOME/.local/share/opgate"
OPGATE_STATE_HOME="$HOME/.local/state/opgate"
OPGATE_GATE_BIN="$OPGATE_HOME/bin/touchid-gate"
OPGATE_GATE_SUM="$OPGATE_HOME/bin/touchid-gate.sha256"
OPGATE_AUDIT_LOG="$OPGATE_STATE_HOME/access.log"

# --- configuration knobs ----------------------------------------------------
# OPGATE_VAULT   : 1Password vault holding project secrets      (default: Dev)
# OPGATE_ENV_FILE: default secret-reference file                (default: .env.op)
#
# There is no knob to weaken or skip the gate. An earlier version had
# OPGATE_GATE=none and a sudo fallback; both were removable by anything that could
# set an environment variable, which is exactly the thing being guarded against.
OPGATE_VAULT="${OPGATE_VAULT:-Dev}"
OPGATE_ENV_FILE_DEFAULT="${OPGATE_ENV_FILE:-.env.op}"

# --- output -----------------------------------------------------------------
# Everything diagnostic goes to stderr so it can never be confused with, or
# interleaved into, a child process's real output.
if [[ -t 2 ]]; then
  _c_red=$'\033[31m'; _c_yellow=$'\033[33m'; _c_green=$'\033[32m'
  _c_dim=$'\033[2m'; _c_reset=$'\033[0m'
else
  _c_red=''; _c_yellow=''; _c_green=''; _c_dim=''; _c_reset=''
fi

info() { printf '%sopgate:%s %s\n' "$_c_dim" "$_c_reset" "$*" >&2; }
warn() { printf '%sopgate:%s %s\n' "$_c_yellow" "$_c_reset" "$*" >&2; }
ok()   { printf '  %s✔%s %s\n' "$_c_green" "$_c_reset" "$*" >&2; }
bad()  { printf '  %s✘%s %s\n' "$_c_red" "$_c_reset" "$*" >&2; }
die()  { printf '%sopgate:%s %s\n' "$_c_red" "$_c_reset" "$*" >&2; exit 1; }

# --- validation -------------------------------------------------------------

require_int() { # <value> <what>
  [[ "$1" =~ ^[0-9]+$ ]] || die "$2 phải là số nguyên, nhận được '$1'"
}

# Environment variables that change how this script or its children resolve
# programs and libraries. Binding a secret to one of these turns `opgate exec`
# into an arbitrary-code-execution primitive.
OPGATE_UNSAFE_VARS='^(PATH|IFS|BASH_ENV|ENV|SHELL|LD_[A-Z_]*|DYLD_[A-Z_]*|OPGATE_[A-Z_]*)$'

require_safe_var_name() { # <name>
  [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] \
    || die "'$1' không phải tên biến môi trường hợp lệ"
  [[ "$1" =~ $OPGATE_UNSAFE_VARS ]] \
    && die "từ chối gán secret cho \$$1 — biến này đổi cách phân giải chương trình/thư viện"
  return 0
}

# Audit fields are tab-separated; a tab or newline inside one would forge a record.
sanitize_field() {
  printf '%s' "$1" | tr '\t\n\r' '   ' | cut -c1-200
}

# --- helpers ----------------------------------------------------------------

# Name used in the Touch ID prompt and the audit log, so you can tell at a glance
# which checkout is asking.
project_name() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root="$PWD"
  basename -- "$root"
}

# Best effort: who is driving this shell. Audit log only — an agent can set
# OPGATE_CALLER, so never treat this as an authenticated identity.
detect_caller() {
  if [[ -n "${OPGATE_CALLER:-}" ]]; then printf '%s' "$OPGATE_CALLER"; return; fi
  if [[ -n "${CLAUDE_PLUGIN_ROOT:-}${CLAUDECODE:-}" ]]; then printf 'claude'; return; fi
  if [[ -n "${CODEX_SANDBOX:-}${CODEX_HOME:-}" ]]; then printf 'codex'; return; fi
  printf 'shell'
}

# Resolve which secret-reference file to use, honouring -f/--env-file then the
# project default. Prints the path; fails if it does not exist.
resolve_env_file() {
  local candidate="${1:-}"
  if [[ -z "$candidate" ]]; then
    local root
    root=$(git rev-parse --show-toplevel 2>/dev/null) || root="$PWD"
    if   [[ -f "$PWD/$OPGATE_ENV_FILE_DEFAULT" ]]; then candidate="$PWD/$OPGATE_ENV_FILE_DEFAULT"
    elif [[ -f "$root/$OPGATE_ENV_FILE_DEFAULT" ]]; then candidate="$root/$OPGATE_ENV_FILE_DEFAULT"
    else
      die "no $OPGATE_ENV_FILE_DEFAULT found in $PWD or $root — pass -f <file>, or create one (see references/project-setup.md)"
    fi
  fi
  [[ -f "$candidate" ]] || die "no such file: $candidate"
  printf '%s' "$candidate"
}

# Variable names declared in a secret-reference file. Names only — a caller that
# wants values must go through the gate.
#
# `op run` tolerates whitespace around `=`; an earlier version of this pattern did
# not, so `ADMIN_TOKEN = op://...` was resolved by op but omitted from the approval
# prompt. Under-reporting scope on the prompt is worse than failing outright, so
# this accepts the same shapes op does.
env_file_vars() {
  local file="$1"
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' -- "$file" \
    | sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=.*/\2/p'
}

# `VAR<TAB>value` for each entry, so callers can distinguish op:// references from
# literals without re-implementing the parser.
env_file_pairs() {
  local file="$1"
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' -- "$file" \
    | sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}[[:space:]]*$/\2	\3/p'
}

# Entries that hold a literal value AND whose name looks like a secret. A plain
# `NODE_ENV=test` is fine in a committed file; a literal `JWT_SECRET=` is not, and
# warning about both would train you to ignore the warning.
OPGATE_SECRETY_NAME='(SECRET|TOKEN|_KEY|^KEY|APIKEY|API_KEY|PASSWORD|PASSWD|PWD|CREDENTIAL|PRIVATE|SIGNING|SALT|CERT|DSN|DATABASE_URL|REDIS_URL|CONNECTION_STRING|AUTH|SESSION|COOKIE|WEBHOOK|ACCESS_KEY|SECRET_KEY)'

env_file_literals() {
  local file="$1"
  # Empty values and obvious placeholders are excluded: warning that
  # `TODO_KEY=changeme` is "a secret in a committable file" is noise, and noise is
  # how a warning stops being read.
  env_file_pairs "$file" \
    | awk -F'\t' '
        $2 ~ /^op:\/\// { next }
        $2 == "" { next }
        tolower($2) ~ /^(changeme|change-me|x+|y+|todo|tbd|your[-_a-z]*|replace[-_a-z]*|example|placeholder|dummy|<.*>|\$\{.*\})$/ { next }
        { print $1 }' \
    | grep -E "$OPGATE_SECRETY_NAME" || true
}

# Truncate a list for display in the Touch ID sheet, which has limited room.
summarize_list() {
  local -a items=("$@")
  local count=${#items[@]}
  if (( count == 0 )); then printf '(none)'; return; fi
  if (( count <= 6 )); then
    printf '%s' "$(IFS=', '; printf '%s' "${items[*]}")"
  else
    local -a head=("${items[@]:0:6}")
    printf '%s +%d nữa' "$(IFS=', '; printf '%s' "${head[*]}")" "$((count - 6))"
  fi
}
