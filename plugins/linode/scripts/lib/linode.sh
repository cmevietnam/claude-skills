#!/usr/bin/env bash
# Reading a linode-cli command line, and working out who owns what it touches.
# Sourced by scripts/guard-linode.sh, scripts/record-owned.sh and bin/lingate.
#
# Every table below was generated from `linode-cli <group> --help` on v5.67.0 and
# checked against all 436 group/action pairs the CLI exposes — not from the API
# docs. When the CLI and this file disagree, the CLI is right: regenerate with
# scripts/test-guard.sh, which pins the classification.

# --- resource groups --------------------------------------------------------

# Ownership lives in the resource's own `tags` field: these groups accept --tags
# on create and update, and filter on --tags when listing.
LINGATE_TAGGABLE="linodes volumes nodebalancers domains lke firewalls images"

# Project resources the API gives no tags field at all. Ownership lives in the
# repo-local ledger instead.
LINGATE_LEDGER_GROUPS="databases vpcs object-storage placement stackscripts sshkeys"

# Changes credentials or CLI identity rather than a resource.
LINGATE_CLI_GROUPS="configure set-user remove-user register-plugin remove-plugin"

# Local help topics: they print a table and never reach the API.
LINGATE_HELP_TOPICS="commands env-vars plugins completion show-users"

# Everything else the CLI knows about. Reads pass; writes are outside any
# project's boundary and are refused.
LINGATE_UNSCOPED="account alerts betas child-account events image-sharegroups \
kernels longview maintenance managed marketplace monitor network-transfer \
networking payment-methods phone profile regions resource-locks \
security-questions service-transfers streams tags tickets users vlans"

LINGATE_GROUPS="$LINGATE_TAGGABLE $LINGATE_LEDGER_GROUPS $LINGATE_CLI_GROUPS $LINGATE_UNSCOPED $LINGATE_HELP_TOPICS"

# --- action classification --------------------------------------------------
# Read is matched first, then write. Anything matching neither is `unknown`, and
# the guard fails closed on it.

LINGATE_READ_RE='^(list|ls|view|types|engines|kernels|completion|show-users|zone-file|versions|transfer|endpoints|enrolled|prices|replies|settings|invoice-items|v6-pools|v6-ranges|volumes|nodebalancers)$|^(get|view|list)-|-(list|ls|view|url|cert|endpoints|file|types)$|-list-all$|-list-by-token$|^stats'

LINGATE_WRITE_RE='^(create|delete|rm|update|add|remove|attach|detach|boot|reboot|shutdown|resize|rebuild|rescue|clone|migrate|upgrade|recycle|reset|enable|disable|suspend|resume|patch|import|upload|assign|unassign|share|revoke|cancel|close|accept|enroll|verify|confirm|snapshot|replicate|regenerate|restore|reply|default|firewalls|mark-seen|promo-add|apply|order|send)$|-(create|delete|update|add|remove|revoke|reset|recycle|resize|clone|rebuild|order|restore|cancel|enable|disable|suspend|resume|patch|upload|send|confirm|username-password|firewalls|seen|secret|password|assign|share|rm|get)$|^(post-|interfaces-|enable-|sms-|assign-|unassign-)'

# Actions that destroy or replace state. A cached answer is a small bet that
# nothing changed in the last minute; for these the bet is not worth taking, so
# ownership is re-checked against the API even if the cache is warm.
LINGATE_DESTRUCTIVE_RE='^(delete|rm|rebuild|rescue|resize|migrate|restore|recycle|shutdown|reset|revoke|detach|cancel|suspend|upgrade|regenerate|clone|replicate)$|-(delete|rm|reset|recycle|resize|rebuild|restore|revoke|cancel|suspend|password)$'

# Reads whose output IS a credential. They stay reads — the guard only insists
# the value lands somewhere other than the transcript.
LINGATE_SECRET_READ_RE='-creds-view$|-ssl-cert$|^keys-(view|list)$|^kubeconfig-view$|^tokens?-view$|^tokens-list$|^credential(-sshkey)?-view$'

# read | write | unknown
action_kind() {
  # Actions whose name reads like one thing and whose HTTP method says another.
  # `linodes volumes` lists; a bare `nodebalancers firewalls` replaces a
  # NodeBalancer's firewall set; `monitor token-get` is a POST that mints a token.
  case "$1 $2" in
    'nodebalancers firewalls'|'payment-methods default'|'monitor token-get')
      printf 'write'; return ;;
  esac
  if [[ "$2" =~ $LINGATE_READ_RE ]];  then printf 'read'
  elif [[ "$2" =~ $LINGATE_WRITE_RE ]]; then printf 'write'
  else printf 'unknown'; fi
}

# taggable | ledger | cli | help | unscoped | unknown
group_scope() {
  case " $LINGATE_TAGGABLE "      in *" $1 "*) printf 'taggable'; return ;; esac
  case " $LINGATE_LEDGER_GROUPS " in *" $1 "*) printf 'ledger';   return ;; esac
  case " $LINGATE_CLI_GROUPS "    in *" $1 "*) printf 'cli';      return ;; esac
  case " $LINGATE_HELP_TOPICS "   in *" $1 "*) printf 'help';     return ;; esac
  case " $LINGATE_UNSCOPED "      in *" $1 "*) printf 'unscoped'; return ;; esac
  printf 'unknown'
}

# The actions that return, list or update exactly one resource of a group.
view_action_for()   { case "$1" in lke) printf 'cluster-view'   ;; *) printf 'view'   ;; esac; }
list_action_for()   { case "$1" in lke) printf 'clusters-list'  ;; *) printf 'list'   ;; esac; }
update_action_for() { case "$1" in lke) printf 'cluster-update' ;; *) printf 'update' ;; esac; }

# --- lexing -----------------------------------------------------------------
# A small shell lexer. The previous version deleted quotes and split on
# whitespace, which destroyed argument boundaries: `--tags="cme --tags staging"`
# read as two flags, and a `&&` inside a quoted label split the command in half.
# This honours '...', "..." and backslash escapes, and emits shell operators as
# their own tokens so the caller can find real command boundaries.
#
# Output: one token per line, "W<TAB>word" or "O<TAB>operator".
shell_lex() {
  printf '%s' "$1" | awk '
    { s = s $0 "\n" }
    function flush() {
      if (have) { gsub(/[\t\n]/, " ", tok); print "W\t" tok }
      tok = ""; have = 0
    }
    END {
      n = length(s); i = 1; tok = ""; have = 0
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\\") { tok = tok substr(s, i+1, 1); have = 1; i += 2; continue }
        if (c == "\047") {
          i++; have = 1
          while (i <= n && substr(s,i,1) != "\047") { tok = tok substr(s,i,1); i++ }
          i++; continue
        }
        if (c == "\"") {
          i++; have = 1
          while (i <= n && substr(s,i,1) != "\"") {
            if (substr(s,i,1) == "\\") { tok = tok substr(s,i+1,1); i += 2; continue }
            tok = tok substr(s,i,1); i++
          }
          i++; continue
        }
        two = substr(s, i, 2)
        if (two == "&&" || two == "||" || two == ";;" || two == "$(" || two == ">>" || two == "2>") {
          flush(); print "O\t" two; i += 2; continue
        }
        if (c == "|" || c == ";" || c == "&" || c == "(" || c == ")" || c == "`" || c == "\n") {
          flush(); print "O\t" c; i++; continue
        }
        if (c == ">" || c == "<") { flush(); print "O\t" c; i++; continue }
        if (c == " " || c == "\t") { flush(); i++; continue }
        tok = tok c; have = 1; i++
      }
      flush()
    }'
}

# Operators that end one command and begin another. Redirections do not: they
# belong to the command they follow.
lin_is_boundary() {
  case "$1" in '&&'|'||'|';;'|'$('|'|'|';'|'&'|'('|')'|'`'|$'\n') return 0 ;; esac
  return 1
}
lin_is_redirect() {
  case "$1" in '>'|'>>'|'2>'|'<') return 0 ;; esac
  return 1
}

# Split a command line into candidate invocations. Sets the caller's `segs`
# array (words newline-separated, each prefixed with a space so an empty argument
# survives) and `has_sink` when output is redirected or piped.
lin_split() {
  local _line _kind _val cur=""
  while IFS= read -r _line; do
    _kind=${_line%%$'\t'*}
    _val=${_line#*$'\t'}
    if [[ "$_kind" == W ]]; then cur="${cur} ${_val}"$'\n'; continue; fi
    if lin_is_redirect "$_val"; then has_sink=1; continue; fi
    [[ "$_val" == '|' ]] && has_sink=1
    if lin_is_boundary "$_val"; then segs[${#segs[@]}]="$cur"; cur=""; fi
  done <<< "$(shell_lex "$1")"
  segs[${#segs[@]}]="$cur"
}

# `bash -c "linode-cli ..."` carries a whole command line inside one quoted word,
# which correct lexing keeps intact. Re-lex those payloads so the command inside
# is checked like any other. Bounded, so a pathological nesting cannot spin.
lin_split_all() {
  segs=(); has_sink=0
  lin_split "$1"
  local i=0 w prev
  while (( i < ${#segs[@]} && i < 64 )); do
    prev=""
    while IFS= read -r w; do
      [[ -z "$w" ]] && continue
      w=${w# }
      if [[ "$prev" == "-c" ]]; then
        case "$w" in *linode*|*"lin "*) lin_split "$w" ;; esac
      fi
      prev="$w"
    done <<< "${segs[i]}"
    i=$((i + 1))
  done
}

# --- flags ------------------------------------------------------------------

# linode-cli's global options that take no value. Anything else that looks like a
# flag is assumed to consume the next token — the safe direction, because it
# keeps a flag's value from being mistaken for a resource id.
LINGATE_BOOL_FLAGS="--help -h --no-defaults --no-retry --version -v --text --json \
--markdown --ascii-table --pretty --no-headers --all --all-columns --all-rows \
--no-truncation --single-table --suppress-warnings --debug"

# Words that run whatever follows them, so a linode-cli token behind one is still
# in command position. Shell keywords are here too, so the body of a `for` loop
# is not mistaken for a plain argument list.
LINGATE_RUNNERS="env sudo doas command exec eval time timeout nohup nice stdbuf \
xargs watch bash sh zsh dash do then else elif fi done if while until case esac { } !"

# argparse accepts any unambiguous prefix of a long option, so `--tag` really is
# `--tags` and `--root_pas` really is `--root_pass`. Matching only the full
# spelling let those through unchecked.
flag_is_bool() {
  local f="${1%%=*}" b
  for b in $LINGATE_BOOL_FLAGS; do
    [[ "$f" == "$b" ]] && return 0
    [[ ${#f} -ge 4 && "$b" == "$f"* ]] && return 0
  done
  return 1
}

# Order matters: the first canonical name the token prefixes wins, so `--ta` is
# tags rather than type, and `--la` is label rather than linodes.
LINGATE_KNOWN_FLAGS="tags root_pass label linodes linode_id volumes volume_id \
domains nodebalancers nodebalancer_id firewall_id id type"

canon_flag() {
  local f="${1%%=*}" c
  if flag_is_bool "$f"; then
    case "$f" in --j*) printf 'json' ;; *) printf 'bool' ;; esac
    return
  fi
  for c in $LINGATE_KNOWN_FLAGS; do
    if [[ ${#f} -ge 4 && "--$c" == "$f"* ]]; then printf '%s' "$c"; return; fi
  done
  printf 'other'
}

# A command may name a second resource it is about to join to the first — a
# Linode a volume attaches to, a firewall device, a placement group member.
# Those are writes on that resource too, so they get the same ownership check.
lin_add_ref() {
  [[ -n "$2" ]] || return 0
  [[ "$2" =~ ^[A-Za-z0-9][A-Za-z0-9/._-]*$ ]] || return 0
  LIN_REF_GROUPS[${#LIN_REF_GROUPS[@]}]="$1"
  LIN_REF_IDS[${#LIN_REF_IDS[@]}]="$2"
}

# --- command parsing --------------------------------------------------------
# Input: one segment, its words newline-separated and each prefixed with a space
# (so an empty argument survives as its own line).
#
# Sets LIN_GROUP LIN_ACTION LIN_IDS[] LIN_TAGS[] LIN_HAS_JSON LIN_ROOTPASS
# LIN_LINODE_ID LIN_ENV LIN_HELP LIN_LABEL LIN_TAG_ATTACH.
# Returns 1 when the segment invokes no linode CLI at all.
parse_linode_cmd() {
  LIN_GROUP=""; LIN_ACTION=""; LIN_IDS=(); LIN_TAGS=()
  LIN_HAS_JSON=0; LIN_ROOTPASS=""; LIN_ENV=""
  LIN_HELP=0; LIN_LABEL=""; LIN_TAG_ATTACH=0
  LIN_REF_GROUPS=(); LIN_REF_IDS=(); LIN_GENERIC_ID=""; LIN_GENERIC_TYPE=""

  local -a tok=()
  local w
  while IFS= read -r w; do
    [[ -z "$w" ]] && continue
    tok[${#tok[@]}]="${w# }"
  done <<< "$1"

  local n=${#tok[@]} i start=-1 runnable=1 prev_flag=0 base
  for ((i = 0; i < n; i++)); do
    base=${tok[i]##*/}
    if (( runnable )); then
      case "$base" in linode-cli|linode|lin) start=$i; break ;; esac
    fi
    case "${tok[i]}" in
      LINODE_ENV=*) LIN_ENV=${tok[i]#LINODE_ENV=}; prev_flag=0; continue ;;
    esac
    if [[ "${tok[i]}" == -* ]]; then prev_flag=1; continue; fi
    if [[ "${tok[i]}" == *=* ]]; then prev_flag=0; continue; fi
    if (( prev_flag )); then prev_flag=0; continue; fi
    case " $LINGATE_RUNNERS " in *" $base "*) continue ;; esac
    runnable=0
  done
  (( start >= 0 )) || return 1

  # Walk the rest knowing which flags take a value, so the group, the action and
  # the positional ids land in the right places no matter where flags appear.
  local j=$((start + 1)) stage=0 t canon val
  while (( j < n )); do
    t=${tok[j]}
    if [[ "$t" == -* ]]; then
      case "$t" in --help|-h) LIN_HELP=1 ;; esac
      canon=$(canon_flag "$t")
      val=""
      if [[ "$t" == *=* ]]; then
        val=${t#*=}
      elif ! flag_is_bool "$t"; then
        val="${tok[j+1]:-}"; ((j++))
      fi
      case "$canon" in
        json)      LIN_HAS_JSON=1 ;;
        tags)      [[ -n "$val" ]] && LIN_TAGS[${#LIN_TAGS[@]}]="$val" ;;
        root_pass) LIN_ROOTPASS="$val" ;;
        label)     LIN_LABEL="$val" ;;
        id)        LIN_GENERIC_ID="$val" ;;
        type)      LIN_GENERIC_TYPE="$val" ;;
        linodes|linode_id)             lin_add_ref linodes "$val" ;;
        volumes|volume_id)             lin_add_ref volumes "$val" ;;
        domains)                       lin_add_ref domains "$val" ;;
        nodebalancers|nodebalancer_id) lin_add_ref nodebalancers "$val" ;;
        firewall_id)                   lin_add_ref firewalls "$val" ;;
      esac
      case "$canon" in
        linodes|volumes|domains|nodebalancers) LIN_TAG_ATTACH=1 ;;
      esac
      ((j++)); continue
    fi
    case $stage in
      0) LIN_GROUP="$t"; stage=1 ;;
      1) LIN_ACTION="$t"; stage=2 ;;
      *) LIN_IDS[${#LIN_IDS[@]}]="$t" ;;
    esac
    ((j++))
  done

  # `firewalls device-create 999 --id 123 --type linode` names its second
  # resource through generic fields instead of a typed flag.
  if [[ "$LIN_GROUP $LIN_ACTION" == "firewalls device-create" && -n "$LIN_GENERIC_ID" ]]; then
    case "$LIN_GENERIC_TYPE" in
      linode)       lin_add_ref linodes "$LIN_GENERIC_ID" ;;
      nodebalancer) lin_add_ref nodebalancers "$LIN_GENERIC_ID" ;;
    esac
  fi
  return 0
}

# --- ownership --------------------------------------------------------------

# Run a command under a hard deadline. macOS ships no timeout(1); perl's alarm is
# the portable stand-in. Without this a slow API call can outlive the hook's own
# timeout, and a hook that times out does not block — the one failure mode that
# turns this guard off exactly when it is needed.
deadline_run() {
  local secs="$1"; shift
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$secs" "$@"
  else
    "$@"
  fi
}

# Print the tags of one resource, one per line. Empty output means the resource
# exists and carries no tags. Exit 1 means ownership could NOT be established —
# the guard turns that into a refusal, never into permission.
# resolve_tags <group> <id> [fresh]  — fresh=1 ignores the cache.
resolve_tags() {
  local group="$1" id="$2" fresh="${3:-0}" cache raw="" now mtime label own
  [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9/._-]*$ ]] || return 1
  RESOLVED_GROUP="$group"; RESOLVED_ID="$id"

  cache="$LINGATE_CACHE_HOME/$group-${id//\//_}.json"
  now=$(date +%s)
  if [[ -f "$cache" && "$fresh" != 1 ]]; then
    mtime=$(file_mtime "$cache")
    if [[ -n "$mtime" ]] && (( now - mtime < LINGATE_TTL )); then
      raw=$(cat -- "$cache")
    fi
  fi
  if [[ -z "$raw" ]]; then
    command -v linode-cli >/dev/null 2>&1 || return 1
    raw=$(deadline_run "$LINGATE_DEADLINE" linode-cli "$group" "$(view_action_for "$group")" \
            "$id" --json --no-retry --suppress-warnings 2>/dev/null) || return 1
    case "$raw" in '['*) ;; *) return 1 ;; esac
    mkdir -p -- "$LINGATE_CACHE_HOME" 2>/dev/null && printf '%s' "$raw" > "$cache"
  fi

  # An LKE worker node is created by its cluster and usually carries no tags of
  # its own; its label pins the cluster, so ownership falls back to there. A node
  # that HAS been tagged speaks for itself — inheritance is a fallback, not an
  # override, or a tagged node would be reported as belonging to nobody.
  if [[ "$group" == linodes ]]; then
    label=$(json_str "$raw" label)
    if [[ "$label" =~ ^lke([0-9]+)- ]]; then
      own=$(json_tags "$raw")
      if [[ -z "$own" ]]; then
        resolve_tags lke "${BASH_REMATCH[1]}" "$fresh"
        return $?
      fi
    fi
  fi

  json_tags "$raw"
  return 0
}

# tags_contain <wanted> <tag>...
tags_contain() {
  local want="$1" t
  shift
  for t in "$@"; do [[ "$t" == "$want" ]] && return 0; done
  return 1
}

# The env tags a resource carries, given the envs this project declares.
env_of_tags() {
  local envs="$1" t
  shift
  for t in "$@"; do
    case " $envs " in *" $t "*) printf '%s\n' "$t" ;; esac
  done
}
