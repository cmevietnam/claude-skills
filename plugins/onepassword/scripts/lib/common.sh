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
# Mirrors what `op run` 2.34.1 does, as measured, not as the dotenv spec says:
#   - `export` is stripped as a prefix even with no whitespace after it
#   - whitespace is allowed around `=`; names may start with a digit
#   - unquoted: `#` starts a comment; trailing whitespace trimmed
#   - single quotes: literal, may span lines, no escapes at all
#   - double quotes: may span lines; only \n \" \\ are decoded (\t and \r are NOT)
#   - $VAR / ${VAR} are expanded by op in unquoted and double-quoted values
#   - a BOM, an unterminated quote, or a NUL byte makes op reject the whole file
#
# Where op would REJECT the file, this parser dies instead of guessing: an
# altered value stored in the vault is worse than no import.
#
# `$VAR` is the one place we cannot mirror op: expanding here would need op's
# environment, and storing the unexpanded text in the vault changes its meaning
# at run time (a resolved secret is not re-expanded). So a `$` in an expandable
# context is refused with guidance to single-quote it.
#
# Fills the parallel arrays OPG_NAMES / OPG_VALUES (bash 3.2: no associative
# arrays). Duplicate names keep op's last-one-wins: the earlier entry is removed.
OPGATE_MAX_ENV_BYTES=262144

parse_env_file() { # <file>
  local file="$1" line rest name value
  local in_quote="" buf="" pending="" lineno=0
  OPG_NAMES=(); OPG_VALUES=()

  local size; size=$(wc -c <"$file" | tr -d ' ')
  (( size > OPGATE_MAX_ENV_BYTES )) \
    && die "$file lớn hơn $((OPGATE_MAX_ENV_BYTES / 1024))KB — không phải file env; parser thuần bash sẽ rất chậm"

  # NUL anywhere: op refuses to build the environment. Detect before parsing —
  # bash drops NULs silently, which would store a truncated value.
  # ($'\x00' is the EMPTY string in bash — a grep for it matches every file.
  # Compare byte counts with and without NULs instead.)
  if [[ "$(LC_ALL=C tr -d '\000' <"$file" | wc -c)" != "$(wc -c <"$file")" ]]; then
    die "$file chứa byte NUL — op run từ chối file này; sửa file trước"
  fi

  local first=1
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"

    if (( first )); then
      first=0
      if [[ "$line" == $'\xef\xbb\xbf'* ]]; then
        die "$file bắt đầu bằng BOM — op run từ chối file này; lưu lại dạng UTF-8 không BOM"
      fi
    fi

    if [[ -n "$in_quote" ]]; then
      local close; close=$(_dq_find_close "$line" "$in_quote")
      if [[ "$close" == "-1" ]]; then
        buf+=$'\n'"$line"
      else
        buf+=$'\n'"${line:0:close}"
        _finish_quoted "$pending" "$buf" "$in_quote" "$lineno"
        in_quote=""; buf=""; pending=""
      fi
      continue
    fi

    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

    # op strips a leading `export` even with nothing after it: `exportHIDDEN=1`
    # sets HIDDEN. Mirror that, and say so, because it is surprising.
    if [[ "$line" == export* ]]; then
      local after="${line#export}"
      after="${after#"${after%%[![:space:]]*}"}"
      if [[ "$after" =~ ^[A-Za-z0-9_] ]]; then
        [[ "${line:6:1}" =~ [[:space:]] ]] || warn "dòng $lineno: 'export' dính liền tên biến — op đọc thành '${after%%=*}'"
        line="$after"
      fi
    fi

    [[ "$line" =~ ^([A-Za-z0-9_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]] || continue
    name="${BASH_REMATCH[1]}"; rest="${BASH_REMATCH[2]}"
    rest="${rest#"${rest%%[![:space:]]*}"}"

    case "${rest:0:1}" in
      "'")
        local body="${rest:1}" c
        c=$(_dq_find_close "$body" "'")
        if [[ "$c" == "-1" ]]; then in_quote="'"; buf="$body"; pending="$name"
        else _finish_quoted "$name" "${body:0:c}" "'" "$lineno"; fi ;;
      '"')
        local body="${rest:1}" c
        c=$(_dq_find_close "$body" '"')
        if [[ "$c" == "-1" ]]; then in_quote='"'; buf="$body"; pending="$name"
        else _finish_quoted "$name" "${body:0:c}" '"' "$lineno"; fi ;;
      *)
        value="$rest"
        if [[ "$value" =~ ^([^#]*)\#.*$ ]]; then value="${BASH_REMATCH[1]}"; fi
        value="${value%"${value##*[![:space:]]}"}"
        _refuse_expansion "$name" "$value" "$lineno"
        _set_var "$name" "$value" ;;
    esac
  done < "$file"

  # op rejects a file with an unterminated quote. Guessing here would vault
  # whatever text happened to follow.
  if [[ -n "$in_quote" ]]; then
    die "$file: dấu nháy mở ở biến $pending không được đóng — op run từ chối file này; sửa file trước"
  fi
}

# Double-quoted body: decode exactly what op decodes, then refuse $ expansion.
_finish_quoted() { # <name> <body> <quote> <lineno>
  local name="$1" body="$2" q="$3" lineno="$4" value
  if [[ "$q" == '"' ]]; then
    # Sentinel keeps $(...) from stripping a trailing newline: a PEM key that ends
    # in \n must keep it.
    value=$(_dq_unescape "$body"; printf x); value="${value%x}"
    _refuse_expansion "$name" "$value" "$lineno"
  else
    value="$body"
  fi
  _set_var "$name" "$value"
}

_refuse_expansion() { # <name> <value> <lineno>
  local v="$2"
  # An unescaped $ followed by a name character or {. A `\$` reaches here as a
  # literal `\$` in unquoted context and is fine; in double quotes op does not
  # decode `\$` either, so it stays `\$` — also not expanded.
  if [[ "$v" =~ (^|[^\\])\$([A-Za-z_{]) ]]; then
    die "dòng $3: giá trị của $1 chứa \$VAR — op run sẽ expand nó, còn vault thì không, nên sau khi import giá trị đổi nghĩa.
       Muốn giữ nguyên chữ \$ thì bọc trong nháy ĐƠN; muốn giá trị đã expand thì sửa file trước."
  fi
}

_set_var() { # <name> <value>
  local name="$1" value="$2" i
  for (( i = 0; i < ${#OPG_NAMES[@]}; i++ )); do
    if [[ "${OPG_NAMES[$i]}" == "$name" ]]; then
      # Last one wins, like op. Drop the earlier entry so the sheet does not show
      # the name twice and hide a distinct name past the truncation point.
      OPG_NAMES=("${OPG_NAMES[@]:0:i}" "${OPG_NAMES[@]:i+1}")
      OPG_VALUES=("${OPG_VALUES[@]:0:i}" "${OPG_VALUES[@]:i+1}")
      break
    fi
  done
  OPG_NAMES+=("$name"); OPG_VALUES+=("$value")
}

# Index of the closing quote in <s>, honouring backslash escapes inside double
# quotes. Prints -1 when there is none.
_dq_find_close() { # <string> <quote-char>
  local s="$1" q="$2" i c
  local bs=$'\\'
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    if [[ "$q" == '"' && "$c" == "$bs" ]]; then i=$((i + 1)); continue; fi
    [[ "$c" == "$q" ]] && { printf '%d' "$i"; return; }
  done
  printf '%d' -1
}

# Only \n, \" and \\ — measured against op 2.34.1. \t and \r stay as two
# characters; decoding them would store bytes op never produces.
_dq_unescape() { # <string>
  local s="$1" out="" i c n
  local bs=$'\\'
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    if [[ "$c" == "$bs" && $((i + 1)) -lt ${#s} ]]; then
      n="${s:i+1:1}"
      case "$n" in
        n)     out+=$'\n'; i=$((i + 1)) ;;
        '"')   out+='"';   i=$((i + 1)) ;;
        "$bs") out+="$bs"; i=$((i + 1)) ;;
        *)     out+="$c" ;;
      esac
    else
      out+="$c"
    fi
  done
  printf '%s' "$out"
}

# Variable names declared in a secret-reference file. Names only.
env_file_vars() {
  parse_env_file "$1"
  local i
  for (( i = 0; i < ${#OPG_NAMES[@]}; i++ )); do printf '%s\n' "${OPG_NAMES[$i]}"; done
}

# `VAR<TAB>ref` per entry; ref is the op:// reference when the value is a VALID
# one, and empty otherwise. A value that merely starts with op:// is not a
# reference — `op://hunter2` is a password that happens to start with op://, and
# printing it would leak it.
env_file_pairs() {
  parse_env_file "$1"
  local i v
  for (( i = 0; i < ${#OPG_NAMES[@]}; i++ )); do
    v="${OPG_VALUES[$i]}"
    if is_op_ref "$v"; then printf '%s\t%s\n' "${OPG_NAMES[$i]}" "$v"
    else printf '%s\t\n' "${OPG_NAMES[$i]}"; fi
  done
}

# Entries whose name looks like a secret and whose value is a literal. Uses the
# classifier's own regex so this warning and the importer cannot disagree.
env_file_literals() {
  parse_env_file "$1"
  local i name value uname
  for (( i = 0; i < ${#OPG_NAMES[@]}; i++ )); do
    name="${OPG_NAMES[$i]}"; value="${OPG_VALUES[$i]}"
    [[ -z "$value" ]] && continue
    is_op_ref "$value" && continue
    [[ "$value" =~ $CLASSIFY_TEMPLATE ]] && continue
    uname=$(_toupper "$name")
    [[ "$uname" =~ $CLASSIFY_SECRET_NAME ]] && printf '%s\n' "$name"
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
    printf '%s' "$(IFS=', '; printf '%s' "${items[*]}")"
  else
    local -a head=("${items[@]:0:shown}")
    printf '%d biến: %s +%d nữa' "$count" "$(IFS=', '; printf '%s' "${head[*]}")" "$((count - shown))"
  fi
}
