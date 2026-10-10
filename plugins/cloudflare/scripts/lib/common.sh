#!/usr/bin/env bash
# Shared paths, output helpers, project lookup and config reading for the
# cloudflare plugin. Sourced by bin/cfgate and scripts/guard-cloudflare.sh.

# --- paths ------------------------------------------------------------------
CFGATE_DIR=".cloudflare"
CFGATE_CONFIG="$CFGATE_DIR/project.json"

# --- configuration knobs ----------------------------------------------------
# CFGATE_GUARD : on | off — off disables the PreToolUse guard   (default: on)
# CFGATE_DEBUG : 1 makes the guard state what it checked on an allow, so a
#                test can tell "checked and allowed" from "never looked".
#                Never set it in a real session: an explicit allow skips the
#                normal permission prompt.
CFGATE_GUARD="${CFGATE_GUARD:-on}"

# --- output -----------------------------------------------------------------
# Diagnostics go to stderr so they can never be mixed into JSON a caller parses.
if [[ -t 2 ]]; then
  _c_red=$'\033[31m'; _c_yellow=$'\033[33m'; _c_green=$'\033[32m'
  _c_dim=$'\033[2m'; _c_reset=$'\033[0m'
else
  _c_red=''; _c_yellow=''; _c_green=''; _c_dim=''; _c_reset=''
fi

info() { printf '%scfgate:%s %s\n' "$_c_dim" "$_c_reset" "$*" >&2; }
warn() { printf '%scfgate:%s %s\n' "$_c_yellow" "$_c_reset" "$*" >&2; }
ok()   { printf '  %s✔%s %s\n' "$_c_green" "$_c_reset" "$*" >&2; }
bad()  { printf '  %s✘%s %s\n' "$_c_red" "$_c_reset" "$*" >&2; }
die()  { printf '%scfgate:%s %s\n' "$_c_red" "$_c_reset" "$*" >&2; exit 1; }

# --- project lookup ---------------------------------------------------------

# Walk up from a directory to the first one holding .cloudflare/project.json.
# The guard runs from wherever the Bash tool sits, not necessarily the repo root.
find_project_root() {
  local dir="${1:-${CLAUDE_PROJECT_DIR:-$PWD}}"
  dir=$(cd -- "$dir" 2>/dev/null && pwd -P) || return 1
  while [[ -n "$dir" ]]; do
    [[ -f "$dir/$CFGATE_CONFIG" ]] && { printf '%s' "$dir"; return 0; }
    [[ "$dir" == "/" ]] && break
    dir=${dir%/*}
    [[ -z "$dir" ]] && dir="/"
  done
  return 1
}

# --- config flattening ------------------------------------------------------
# One reader for JSON, JSONC and TOML, deliberately awk and not jq or a TOML
# library: the guard runs on every Bash call, and a guard that stops guarding
# the day a dependency is missing is worse than none.
#
# Every scalar comes out as one line, `path<TAB>value`, with `/` between keys
# and `[]` for an array member:
#
#   name                                 cme-cdn
#   routes[]/pattern                     cdn.cmevietnam.org.vn/*
#   env/staging/r2_buckets[]/bucket_name cme-staging-public
#   zones/cmevietnam.org.vn              <zone id>
#
# `/`, not `.`, because zone names are keys and contain dots. The reader is
# tolerant (commas are whitespace, trailing commas and comments are fine) and
# always advances, so malformed input ends instead of spinning. It reads what a
# boundary check needs; it is not a validator.
#
# flatten_config <file> [json|toml] — the format defaults to the extension.
flatten_config() {
  local file="$1" mode="${2:-}"
  [[ -r "$file" ]] || return 1
  if [[ -z "$mode" ]]; then
    case "$file" in *.toml) mode=toml ;; *) mode=json ;; esac
  fi
  awk -v mode="$mode" '
    { S = S $0 "\n" }
    function ws(   c, e) {
      while (P <= L) {
        c = substr(S, P, 1)
        if (c == " " || c == "\t" || c == "\r" || c == "\n" || c == ",") { P++; continue }
        if (c == "/" && substr(S, P + 1, 1) == "/") { while (P <= L && substr(S, P, 1) != "\n") P++; continue }
        if (c == "/" && substr(S, P + 1, 1) == "*") {
          e = index(substr(S, P + 2), "*/"); P = e ? P + 2 + e + 1 : L + 1; continue
        }
        if (c == "#") { while (P <= L && substr(S, P, 1) != "\n") P++; continue }
        break
      }
    }
    # A quoted string, honouring backslash escapes in "..." and none in '"'"'...'"'"'.
    function qstr(   q, v, c, n, e) {
      q = substr(S, P, 1); P++
      if (substr(S, P, 2) == q q) {            # TOML triple-quoted
        P += 2; e = index(substr(S, P), q q q)
        if (e == 0) { v = substr(S, P); P = L + 1; return v }
        v = substr(S, P, e - 1); P += e + 2; return v
      }
      v = ""
      while (P <= L) {
        c = substr(S, P, 1)
        if (c == "\\" && q == "\"") {
          n = substr(S, P + 1, 1)
          if (n == "n") v = v "\n"; else if (n == "t") v = v "\t"; else v = v n
          P += 2; continue
        }
        if (c == q) { P++; break }
        v = v c; P++
      }
      return v
    }
    function bare(   v, c) {
      v = ""
      while (P <= L) {
        c = substr(S, P, 1)
        if (c ~ /[ \t\r\n,:=#{}\[\]]/) break
        v = v c; P++
      }
      return v
    }
    function key(   k, c) {
      c = substr(S, P, 1)
      if (c == "\"" || c == "\047") return qstr()
      k = bare()
      if (mode == "toml") gsub(/\./, "/", k)
      return k
    }
    function emit(path, v) { gsub(/[\t\n]/, " ", v); print path "\t" v }
    function value(path,   c, k, v) {
      ws(); if (P > L) return
      c = substr(S, P, 1)
      if (c == "{") {
        P++
        while (1) {
          ws(); if (P > L) return
          c = substr(S, P, 1)
          if (c == "}") { P++; return }
          k = key()
          if (k == "") { P++; continue }
          ws(); c = substr(S, P, 1)
          if (c == ":" || c == "=") P++
          value(path == "" ? k : path "/" k)
        }
      }
      if (c == "[") {
        P++
        while (1) {
          ws(); if (P > L) return
          if (substr(S, P, 1) == "]") { P++; return }
          value(path "[]")
        }
      }
      if (c == "\"" || c == "\047") { emit(path, qstr()); return }
      v = bare()
      if (v == "") { P++; return }
      emit(path, v)
    }
    # TOML: a [table] or [[array]] header sets the prefix of the keys below it.
    function header(   arr, h, c, part, out) {
      arr = (substr(S, P, 2) == "[["); P += arr ? 2 : 1
      out = ""; part = ""
      while (P <= L) {
        c = substr(S, P, 1)
        if (c == "]") break
        if (c == "\"" || c == "\047") { part = part qstr(); continue }
        if (c == ".") { out = out (out == "" ? "" : "/") part; part = ""; P++; continue }
        if (c != " " && c != "\t") part = part c
        P++
      }
      out = out (out == "" ? "" : "/") part
      while (P <= L && substr(S, P, 1) == "]") P++
      return out (arr ? "[]" : "")
    }
    END {
      L = length(S); P = 1
      if (mode == "json") { value(""); exit }
      prefix = ""
      while (1) {
        ws(); if (P > L) break
        if (substr(S, P, 1) == "[") { prefix = header(); continue }
        k = key()
        if (k == "") { P++; continue }
        ws(); if (substr(S, P, 1) == "=") P++
        value(prefix == "" ? k : prefix "/" k)
      }
    }' "$file"
}

# Values of one exact path in a flattened config read from stdin, one per line.
# The path and the pattern travel through the environment, not `awk -v`: -v
# interprets backslash escapes, which turned `routes\[\]` into a broken bracket
# expression and silently disabled every route and binding check.
flat_get() { FLAT_ARG="$1" awk -F '\t' '$1 == ENVIRON["FLAT_ARG"] { print substr($0, length($1) + 2) }'; }

# Paths matching an ERE, printed as `path<TAB>value`.
flat_grep() { FLAT_ARG="$1" awk -F '\t' '$1 ~ ENVIRON["FLAT_ARG"]'; }

# --- project config ---------------------------------------------------------
# Loaded once per root into CFG_* globals:
#   CFG_PROJECT  project name            CFG_ACCOUNT  account id (32 hex)
#   CFG_ZONE_NAMES[] / CFG_ZONE_IDS[]    the project's zones, same order
#   CFG_PREFIXES[]   name prefixes       CFG_NAMES[]  extra exact names
#   CFG_PROTECTED[]  globs over names, hostnames and zones; a match asks
CFG_ROOT=""
load_project() {
  local root="$1" flat line k v
  [[ "$CFG_ROOT" == "$root" ]] && return 0
  CFG_ROOT="$root"; CFG_PROJECT=""; CFG_ACCOUNT=""
  CFG_ZONE_NAMES=(); CFG_ZONE_IDS=(); CFG_PREFIXES=(); CFG_NAMES=(); CFG_PROTECTED=()
  flat=$(flatten_config "$root/$CFGATE_CONFIG" json) || return 1
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    k=${line%%$'\t'*}; v=${line#*$'\t'}
    case "$k" in
      project)       CFG_PROJECT="$v" ;;
      accountId)     CFG_ACCOUNT="$v" ;;
      zones/*)       CFG_ZONE_NAMES[${#CFG_ZONE_NAMES[@]}]=$(lower "${k#zones/}")
                     CFG_ZONE_IDS[${#CFG_ZONE_IDS[@]}]="$v" ;;
      'prefixes[]')  [[ -n "$v" ]] && CFG_PREFIXES[${#CFG_PREFIXES[@]}]="$v" ;;
      'names[]')     [[ -n "$v" ]] && CFG_NAMES[${#CFG_NAMES[@]}]="$v" ;;
      'protected[]') [[ -n "$v" ]] && CFG_PROTECTED[${#CFG_PROTECTED[@]}]="$v" ;;
    esac
  done <<< "$flat"
  return 0
}

# Problems with the loaded project config, one per line; empty means usable.
project_problems() {
  [[ -n "$CFG_PROJECT" ]] || echo "no \"project\" name"
  [[ "$CFG_ACCOUNT" =~ ^[0-9a-f]{32}$ ]] || echo "\"accountId\" is not a 32-character hex account id"
  (( ${#CFG_PREFIXES[@]} + ${#CFG_NAMES[@]} > 0 )) || echo "neither \"prefixes\" nor \"names\" is set, so no resource name could ever be in the project"
  local i=0 p
  while (( i < ${#CFG_ZONE_IDS[@]} )); do
    [[ "${CFG_ZONE_IDS[i]}" =~ ^[0-9a-f]{32}$ ]] || echo "zone ${CFG_ZONE_NAMES[i]} has id '${CFG_ZONE_IDS[i]}', not a 32-character hex zone id"
    i=$((i + 1))
  done
  # An empty prefix matches every name on the account, which is no boundary.
  for p in ${CFG_PREFIXES[@]+"${CFG_PREFIXES[@]}"}; do
    (( ${#p} >= 2 )) || echo "prefix '$p' is too short to separate projects (2 characters minimum)"
  done
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# --- boundary predicates ----------------------------------------------------

# Is a resource name inside the project? Prefix match, or one of the extra names.
name_in_project() {
  local n="$1" p
  [[ -n "$n" ]] || return 1
  for p in ${CFG_PREFIXES[@]+"${CFG_PREFIXES[@]}"}; do [[ "$n" == "$p"* ]] && return 0; done
  for p in ${CFG_NAMES[@]+"${CFG_NAMES[@]}"}; do [[ "$n" == "$p" ]] && return 0; done
  return 1
}

# The project zone a hostname belongs to (the longest matching zone), or fail.
zone_of_host() {
  local h best="" z
  h=$(lower "$1"); h=${h%.}
  for z in ${CFG_ZONE_NAMES[@]+"${CFG_ZONE_NAMES[@]}"}; do
    if [[ "$h" == "$z" || "$h" == *".$z" ]] && (( ${#z} > ${#best} )); then best="$z"; fi
  done
  [[ -n "$best" ]] || return 1
  printf '%s' "$best"
}

zone_name_of_id() {
  local i=0
  while (( i < ${#CFG_ZONE_IDS[@]} )); do
    [[ "${CFG_ZONE_IDS[i]}" == "$1" ]] && { printf '%s' "${CFG_ZONE_NAMES[i]}"; return 0; }
    i=$((i + 1))
  done
  return 1
}

zone_id_is_ours() { zone_name_of_id "$1" >/dev/null; }

zone_name_is_ours() {
  local z n
  n=$(lower "$1")
  for z in ${CFG_ZONE_NAMES[@]+"${CFG_ZONE_NAMES[@]}"}; do [[ "$z" == "$n" ]] && return 0; done
  return 1
}

# Does a name, hostname or zone match one of the project's protected globs?
# Prints the glob that matched.
protected_match() {
  local s="$1" g
  for g in ${CFG_PROTECTED[@]+"${CFG_PROTECTED[@]}"}; do
    # shellcheck disable=SC2053  # the glob is meant to match
    [[ "$s" == $g ]] && { printf '%s' "$g"; return 0; }
  done
  return 1
}

# The hostname inside a route pattern: scheme, path and a leading wildcard go.
#   "*.cmevietnam.org.vn/*" -> cmevietnam.org.vn ; "https://a.b.c/x" -> a.b.c
host_of_pattern() {
  local p="$1"
  p=${p#*://}; p=${p%%/*}; p=${p%%:*}
  p=${p#\*}; p=${p#.}
  printf '%s' "$p"
}

# --- hook payload -----------------------------------------------------------

# A string field of a hook payload. jq when available; otherwise a scanner that
# honours backslash escapes, so an embedded \" does not truncate the value.
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
                         if (n == "n") out = out "\n"
                         else if (n == "t") out = out "\t"
                         else out = out n
                         i++ }
        else if (c == "\"") break
        else out = out c
      }
      print out
    }'
}

hook_command() { payload_str "$1" '.tool_input.command' 'command'; }
