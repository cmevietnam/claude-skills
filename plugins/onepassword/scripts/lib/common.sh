#!/usr/bin/env bash
# Shared paths, logging and small helpers for opgate.
# Sourced by bin/opgate, scripts/build-gate.sh and scripts/lib/gate.sh.

# Placeholder detection lives in classify.sh; env_file_literals uses it so the
# literal warning and the importer agree on what counts as a blank.
if ! declare -f _is_placeholder >/dev/null 2>&1; then
  _opgate_lib_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  [[ -r "$_opgate_lib_dir/classify.sh" ]] && source "$_opgate_lib_dir/classify.sh"
fi

# --- paths ------------------------------------------------------------------
# Deliberately NOT honouring XDG_DATA_HOME: the gate binary's location must not be
# redirectable by a variable that exists for exactly that purpose.
#
# This is a speed bump, not a wall. The path still derives from HOME, and anything
# that can set HOME could point us at a different tree — but anything that can do
# that can also just run `op` directly, which no part of this tool prevents. See
# references/security-model.md.
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

# --- dotenv parsing --------------------------------------------------------
#
# One parser, used by everything. The approval prompt, the literal warning and
# `import` previously used three different implementations; any divergence means
# the Touch ID sheet under-reports what `op run` will actually resolve, which is a
# security bug rather than a cosmetic one.
#
# Aims to match what `op run` accepts: optional `export`, whitespace around `=`,
# names that may start with a digit, single-quoted values taken literally,
# double-quoted values with \n \t \r \" \\ escapes, quoted values spanning
# several physical lines, and `#` starting a comment only outside quotes.
#
# Fills the parallel arrays OPG_NAMES / OPG_VALUES. bash 3.2 has no associative
# arrays, hence two arrays kept in step.
parse_env_file() { # <file>
  local file="$1" line rest name value
  local in_quote="" buf="" pending=""
  OPG_NAMES=(); OPG_VALUES=()

  # `|| [[ -n "$line" ]]` keeps the final line when the file has no trailing
  # newline — dropping it would silently skip the last variable.
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"

    if [[ -n "$in_quote" ]]; then
      local close; close=$(_dq_find_close "$line" "$in_quote")
      if [[ "$close" == "-1" ]]; then
        buf+=$'\n'"$line"
      else
        buf+=$'\n'"${line:0:close}"
        [[ "$in_quote" == '"' ]] && buf=$(_dq_unescape "$buf")
        OPG_NAMES+=("$pending"); OPG_VALUES+=("$buf")
        in_quote=""; buf=""; pending=""
      fi
      continue
    fi

    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

    # `export` followed by any amount of whitespace.
    if [[ "$line" =~ ^export[[:space:]]+(.*)$ ]]; then line="${BASH_REMATCH[1]}"; fi

    # op accepts names beginning with a digit; an earlier pattern required a
    # letter or underscore and silently dropped `1TOKEN=…` from the prompt.
    [[ "$line" =~ ^([A-Za-z0-9_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]] || continue
    name="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "${rest:0:1}" in
      "'")
        local body="${rest:1}" c
        c=$(_dq_find_close "$body" "'")
        if [[ "$c" == "-1" ]]; then
          in_quote="'"; buf="$body"; pending="$name"
        else
          OPG_NAMES+=("$name"); OPG_VALUES+=("${body:0:c}")
        fi ;;
      '"')
        local body="${rest:1}" c
        c=$(_dq_find_close "$body" '"')
        if [[ "$c" == "-1" ]]; then
          in_quote='"'; buf="$body"; pending="$name"
        else
          OPG_NAMES+=("$name"); OPG_VALUES+=("$(_dq_unescape "${body:0:c}")")
        fi ;;
      *)
        # Unquoted: `#` begins a comment. op keeps `abc123` from
        # `TOKEN=abc123 #note`, so storing the note as part of the secret was
        # both wrong and a way to put a comment inside a vault field.
        value="$rest"
        if [[ "$value" =~ ^([^#]*)\#.*$ ]]; then value="${BASH_REMATCH[1]}"; fi
        value="${value%"${value##*[![:space:]]}"}"
        OPG_NAMES+=("$name"); OPG_VALUES+=("$value") ;;
    esac
  done < "$file"

  # An unterminated quote: keep what we have rather than dropping the variable,
  # so the prompt still mentions it.
  if [[ -n "$in_quote" ]]; then
    [[ "$in_quote" == '"' ]] && buf=$(_dq_unescape "$buf")
    OPG_NAMES+=("$pending"); OPG_VALUES+=("$buf")
  fi
}

# Index of the closing quote in <s>, honouring backslash escapes for `"`.
# Prints -1 when there is none.
_dq_find_close() { # <string> <quote-char>
  local s="$1" q="$2" i c
  local bs=$'\\'
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    # Inside double quotes a backslash escapes the next character, so a `\"` is
    # part of the value rather than its terminator.
    if [[ "$q" == '"' && "$c" == "$bs" ]]; then i=$((i + 1)); continue; fi
    [[ "$c" == "$q" ]] && { printf '%d' "$i"; return; }
  done
  printf '%d' -1
}

_dq_unescape() { # <string>
  local s="$1" out="" i c n
  local bs=$'\\'
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    if [[ "$c" == "$bs" && $((i + 1)) -lt ${#s} ]]; then
      n="${s:i+1:1}"
      case "$n" in
        n)  out+=$'\n'; i=$((i + 1)) ;;
        t)  out+=$'\t'; i=$((i + 1)) ;;
        r)  out+=$'\r'; i=$((i + 1)) ;;
        '"') out+='"';  i=$((i + 1)) ;;
        "$bs") out+="$bs"; i=$((i + 1)) ;;
        *)  out+="$c" ;;
      esac
    else
      out+="$c"
    fi
  done
  printf '%s' "$out"
}

# Variable names declared in a secret-reference file. Names only — a caller that
# wants values must go through the gate.
env_file_vars() {
  parse_env_file "$1"
  local i
  for (( i = 0; i < ${#OPG_NAMES[@]}; i++ )); do printf '%s\n' "${OPG_NAMES[$i]}"; done
}

# `VAR<TAB>ref` for each entry; the second field is the op:// reference when the
# value is one, and empty otherwise. Values are deliberately NOT emitted here: a
# value may contain tabs or newlines, and a line-based stream carrying secrets is
# a leak waiting for a careless caller.
env_file_pairs() {
  parse_env_file "$1"
  local i v
  for (( i = 0; i < ${#OPG_NAMES[@]}; i++ )); do
    v="${OPG_VALUES[$i]}"
    case "$v" in
      op://*) printf '%s\t%s\n' "${OPG_NAMES[$i]}" "$v" ;;
      *)      printf '%s\t\n' "${OPG_NAMES[$i]}" ;;
    esac
  done
}

# Entries that hold a literal value AND whose name looks like a secret. A plain
# `NODE_ENV=test` is fine in a committed file; a literal `JWT_SECRET=` is not, and
# warning about both would train you to ignore the warning.
OPGATE_SECRETY_NAME='(SECRET|TOKEN|_KEY|^KEY|APIKEY|API_KEY|PASSWORD|PASSWD|PASSPHRASE|_PASS|^PASS|_PW$|PWD|CREDENTIAL|PRIVATE|SIGNING|SALT|CERT|DSN|DATABASE_URL|REDIS_URL|CONNECTION_STRING|AUTH|SESSION|COOKIE|WEBHOOK|ACCESS_KEY|SECRET_KEY|SEED|MNEMONIC)'

env_file_literals() {
  parse_env_file "$1"
  local i name value uname
  for (( i = 0; i < ${#OPG_NAMES[@]}; i++ )); do
    name="${OPG_NAMES[$i]}"; value="${OPG_VALUES[$i]}"
    [[ -z "$value" ]] && continue
    case "$value" in op://*) continue ;; esac
    # Placeholders are not leaks; warning about `TODO_KEY=changeme` is noise, and
    # noise is how a warning stops being read.
    if declare -f _is_placeholder >/dev/null 2>&1 && _is_placeholder "$value"; then continue; fi
    uname=$(printf '%s' "$name" | LC_ALL=C tr 'a-z' 'A-Z')
    [[ "$uname" =~ $OPGATE_SECRETY_NAME ]] && printf '%s\n' "$name"
  done
}

# Render a list for the Touch ID sheet. The count is always shown: the sheet has
# limited room, so a long list is truncated, and an approval that silently hides
# how much it covers is worse than one that says "and 40 more".
summarize_list() {
  local -a items=("$@")
  local count=${#items[@]} shown=12
  if (( count == 0 )); then printf '(none)'; return; fi
  if (( count <= shown )); then
    printf '%d: %s' "$count" "$(IFS=', '; printf '%s' "${items[*]}")"
  else
    local -a head=("${items[@]:0:shown}")
    printf '%d biến: %s +%d nữa' "$count" "$(IFS=', '; printf '%s' "${head[*]}")" "$((count - shown))"
  fi
}
