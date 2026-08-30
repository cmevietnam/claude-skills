#!/usr/bin/env bash
# Shared paths, logging and small helpers for opgate.
# Sourced by bin/opgate, scripts/build-gate.sh and scripts/lib/gate.sh.

# --- paths ------------------------------------------------------------------
OPGATE_DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/opgate"
OPGATE_STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/opgate"
OPGATE_GATE_BIN="$OPGATE_DATA_HOME/bin/touchid-gate"
OPGATE_AUDIT_LOG="$OPGATE_STATE_HOME/access.log"

# --- configuration knobs ----------------------------------------------------
# OPGATE_VAULT   : 1Password vault holding project secrets      (default: Dev)
# OPGATE_TTL     : seconds an approval is reused; 0 = ask every time (default: 0)
# OPGATE_GATE    : touchid | sudo | none                        (default: touchid)
# OPGATE_ENV_FILE: default secret-reference file                (default: .env.op)
OPGATE_VAULT="${OPGATE_VAULT:-Dev}"
OPGATE_TTL="${OPGATE_TTL:-0}"
OPGATE_GATE="${OPGATE_GATE:-touchid}"
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

# --- helpers ----------------------------------------------------------------

# Name used in the Touch ID prompt and the audit log, so you can tell at a glance
# which checkout is asking.
project_name() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || root="$PWD"
  basename -- "$root"
}

# Best effort: who is driving this shell. Used for the audit log only.
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
      die "no $OPGATE_ENV_FILE_DEFAULT found in $PWD or $root — pass -f <file>, or create one (see: opgate help setup)"
    fi
  fi
  [[ -f "$candidate" ]] || die "no such file: $candidate"
  printf '%s' "$candidate"
}

# Variable names declared in a secret-reference file. Names only — a caller that
# wants values must go through the gate.
env_file_vars() {
  local file="$1"
  # Skip blanks and comments; take the LHS of the first '='.
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' -- "$file" \
    | sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)=.*/\2/p'
}

# Entries that hold a literal value AND whose name looks like a secret. A plain
# `NODE_ENV=test` is fine in a committed file; a literal `JWT_SECRET=` is not, and
# warning about both would train you to ignore the warning.
OPGATE_SECRETY_NAME='(SECRET|TOKEN|_KEY|^KEY|APIKEY|API_KEY|PASSWORD|PASSWD|PWD|CREDENTIAL|PRIVATE|SIGNING|SALT|CERT|DSN|DATABASE_URL|REDIS_URL|CONNECTION_STRING|AUTH|SESSION|COOKIE|WEBHOOK|ACCESS_KEY|SECRET_KEY)'

env_file_literals() {
  local file="$1"
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' -- "$file" \
    | sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}\([A-Za-z_][A-Za-z0-9_]*\)=\(.*\)/\2 \3/p' \
    | awk '$2 !~ /^"?op:\/\// { print $1 }' \
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
