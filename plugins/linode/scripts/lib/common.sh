#!/usr/bin/env bash
# Shared paths, output helpers and project lookup for the linode plugin.
# Sourced by bin/lingate, scripts/guard-linode.sh and scripts/record-owned.sh.

# --- paths ------------------------------------------------------------------
LINGATE_CACHE_HOME="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/lingate"
LINGATE_DIR=".linode"
LINGATE_CONFIG="$LINGATE_DIR/project.json"
LINGATE_LEDGER="$LINGATE_DIR/owned.json"

# --- configuration knobs ----------------------------------------------------
# LINGATE_GUARD   : on | off — off disables the PreToolUse guard  (default: on)
# LINGATE_TTL     : seconds an ownership lookup stays cached       (default: 60)
# LINGATE_DEADLINE: seconds one API lookup may take               (default: 8)
LINGATE_GUARD="${LINGATE_GUARD:-on}"
LINGATE_TTL="${LINGATE_TTL:-60}"
LINGATE_DEADLINE="${LINGATE_DEADLINE:-8}"

# --- output -----------------------------------------------------------------
# Everything diagnostic goes to stderr, so it can never be confused with, or
# interleaved into, JSON that a caller is parsing.
if [[ -t 2 ]]; then
  _c_red=$'\033[31m'; _c_yellow=$'\033[33m'; _c_green=$'\033[32m'
  _c_dim=$'\033[2m'; _c_reset=$'\033[0m'
else
  _c_red=''; _c_yellow=''; _c_green=''; _c_dim=''; _c_reset=''
fi

info() { printf '%slingate:%s %s\n' "$_c_dim" "$_c_reset" "$*" >&2; }
warn() { printf '%slingate:%s %s\n' "$_c_yellow" "$_c_reset" "$*" >&2; }
ok()   { printf '  %s✔%s %s\n' "$_c_green" "$_c_reset" "$*" >&2; }
bad()  { printf '  %s✘%s %s\n' "$_c_red" "$_c_reset" "$*" >&2; }
die()  { printf '%slingate:%s %s\n' "$_c_red" "$_c_reset" "$*" >&2; exit 1; }

# --- project lookup ---------------------------------------------------------

# Walk up from a starting directory to the first one holding .linode/project.json
# and print it. The guard runs from wherever the Bash tool sits, which is not
# necessarily the repo root.
find_project_root() {
  local dir="${1:-${CLAUDE_PROJECT_DIR:-$PWD}}"
  dir=$(cd -- "$dir" 2>/dev/null && pwd -P) || return 1
  while [[ -n "$dir" ]]; do
    [[ -f "$dir/$LINGATE_CONFIG" ]] && { printf '%s' "$dir"; return 0; }
    [[ "$dir" == "/" ]] && break
    dir=${dir%/*}
    [[ -z "$dir" ]] && dir="/"
  done
  return 1
}

# --- JSON -------------------------------------------------------------------
# Deliberately awk and not jq: the guard runs on every Bash call and a guard that
# stops guarding the day jq is missing is worse than no guard. These walk the
# document honouring string quoting and backslash escapes, so a tag or label
# containing a comma, a space or a bracket survives intact — an earlier
# sed/tr version silently turned the single tag "cme,staging" into two.

# First string value of a top-level-ish key.
json_str() {
  printf '%s' "$1" | tr '\n' ' ' | awk -v key="$2" '
    {
      pat = "\"" key "\""
      k = index($0, pat); if (k == 0) exit
      i = k + length(pat)
      while (i <= length($0) && (substr($0,i,1) == " " || substr($0,i,1) == ":")) i++
      if (substr($0,i,1) != "\"") exit
      i++; v = ""
      while (i <= length($0)) {
        c = substr($0,i,1)
        if (c == "\\") { v = v substr($0,i+1,1); i += 2; continue }
        if (c == "\"") break
        v = v c; i++
      }
      print v
    }'
}

json_str_file() { json_str "$(cat -- "$1" 2>/dev/null)" "$2"; }

# Members of a string array, one per line, values intact.
json_arr() {
  printf '%s' "$1" | tr '\n' ' ' | awk -v key="$2" '
    {
      pat = "\"" key "\""
      k = index($0, pat); if (k == 0) exit
      i = k + length(pat)
      while (i <= length($0) && (substr($0,i,1) == " " || substr($0,i,1) == ":")) i++
      if (substr($0,i,1) != "[") exit
      i++
      while (i <= length($0)) {
        c = substr($0,i,1)
        if (c == "]") break
        if (c == "\"") {
          i++; v = ""
          while (i <= length($0)) {
            c = substr($0,i,1)
            if (c == "\\") { v = v substr($0,i+1,1); i += 2; continue }
            if (c == "\"") break
            v = v c; i++
          }
          print v; i++
          continue
        }
        i++
      }
    }'
}

json_arr_file() { json_arr "$(cat -- "$1" 2>/dev/null)" "$2"; }

# A boolean field of a JSON file: prints `true` or `false`. grep, not sed —
# BSD sed has no \| alternation, so a sed version silently never matched.
json_bool_file() {
  if grep -q "\"$2\"[[:space:]]*:[[:space:]]*true" -- "$1" 2>/dev/null
  then printf 'true'; else printf 'false'; fi
}

json_tags() { json_arr "$1" tags; }

# The FIRST numeric "id" in a document — what a create action returns for the
# resource itself. Nested children (a VPC's subnets) come later in the response,
# so taking the last match would record the wrong id in the ledger.
json_first_id() {
  printf '%s' "$1" | tr '\n' ' ' \
    | grep -o '"id"[[:space:]]*:[[:space:]]*[0-9][0-9]*' \
    | head -1 | grep -o '[0-9][0-9]*$'
}

# Make a string safe to sit inside a JSON string in the ledger. Braces and
# control characters are replaced rather than escaped: entries are recovered with
# a brace-matching grep, and a label is display metadata, not something worth
# breaking the file's readability for.
json_escape() {
  printf '%s' "$1" | awk '
    { s = s $0 "\n" }
    END {
      sub(/\n$/, "", s)
      n = length(s); out = ""
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (c == "\\")     out = out "\\\\"
        else if (c == "\"") out = out "\\\""
        else if (c == "{" || c == "}" || c == "\n" || c == "\t" || c < " ") out = out " "
        else out = out c
      }
      printf "%s", out
    }'
}

# --- ownership ledger -------------------------------------------------------
# For resource types the API gives no tags field. One line per entry so a plain
# grep can answer the question the guard asks.

# A ledger only speaks for the project it names. Without this check an
# owned.json copied in from another project would hand over its resources.
# ledger_is_ours <root> <tag>
ledger_is_ours() {
  local file="$1/$LINGATE_LEDGER"
  [[ -f "$file" ]] || return 1
  [[ "$(json_str_file "$file" tag)" == "$2" ]]
}

# ledger_has <root> <tag> <type> <id>
ledger_has() {
  local file="$1/$LINGATE_LEDGER"
  [[ -f "$file" ]] || return 1
  ledger_is_ours "$1" "$2" || return 1
  tr -d ' \n\t' < "$file" | grep -o '{[^{}]*}' \
    | grep -F "\"type\":\"$3\"" | grep -qF "\"id\":\"$4\""
}

# The environments a ledger entry claims, one per line. More than one means the
# resource is shared between environments, which the guard treats exactly like a
# taggable resource carrying two env tags.
# ledger_envs_of <root> <tag> <type> <id>
ledger_envs_of() {
  local file="$1/$LINGATE_LEDGER" e
  [[ -f "$file" ]] || return 1
  ledger_is_ours "$1" "$2" || return 1
  tr -d ' \n\t' < "$file" | grep -o '{[^{}]*}' \
    | grep -F "\"type\":\"$3\"" | grep -F "\"id\":\"$4\"" \
    | while IFS= read -r e; do json_str "$e" env; done
}

# Portable mtime in epoch seconds.
file_mtime() {
  stat -f %m -- "$1" 2>/dev/null || stat -c %Y -- "$1" 2>/dev/null
}

# --- hook payload -----------------------------------------------------------

# Pull a string field out of a hook payload. jq when available; otherwise a
# scanner that walks the JSON string honouring backslash escapes, so an embedded
# \" (as in `bash -c "linode-cli ..."`) does not truncate the value.
# payload_str <payload> <jq-path> <raw-key>
payload_str() {
  local payload="$1" path="$2" key="$3" out
  if command -v jq >/dev/null 2>&1; then
    out=$(printf '%s' "$payload" | jq -r "$path // \"\"" 2>/dev/null) \
      && [[ -n "$out" ]] && { printf '%s' "$out"; return 0; }
  fi
  printf '%s' "$payload" | awk -v key="\"$key\":" '
    { line = line $0 "\n" }
    END {
      k = index(line, key)
      if (k == 0) exit
      rest = substr(line, k + length(key))
      q = index(rest, "\"")
      if (q == 0) exit
      rest = substr(rest, q + 1)
      out = ""
      for (i = 1; i <= length(rest); i++) {
        c = substr(rest, i, 1)
        if (c == "\\") { n = substr(rest, i + 1, 1)
                         if (n == "n" || n == "t") out = out " "
                         else out = out n
                         i++ }
        else if (c == "\"") break
        else out = out c
      }
      print out
    }'
}

hook_command()  { payload_str "$1" '.tool_input.command' 'command'; }
hook_response() { payload_str "$1" '(.tool_response.stdout? // .tool_response.output? // (.tool_response|strings))' 'stdout'; }

# --- ledger writing ---------------------------------------------------------
# The ledger is written one entry per line so grep can read it, but it is read
# back through tr so that a human who reformats the file does not break it.

ledger_entries() {
  local file="$1/$LINGATE_LEDGER"
  [[ -f "$file" ]] || return 0
  tr -d '\n\t' < "$file" | grep -o '{[^{}]*}' | grep '"type"' || true
}

# ledger_save <root> <tag>  — entries arrive on stdin, one JSON object per line.
ledger_save() {
  local root="$1" tag="$2" file="$1/$LINGATE_LEDGER" tmp entries
  entries=$(cat)
  tmp="$file.tmp.$$"
  mkdir -p -- "$root/$LINGATE_DIR" || return 1
  {
    printf '{\n  "tag": "%s",\n  "owned": [\n' "$tag"
    local first=1 line
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      (( first )) || printf ',\n'
      first=0
      printf '    %s' "$line"
    done <<< "$entries"
    (( first )) || printf '\n'
    printf '  ]\n}\n'
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$file"
}
