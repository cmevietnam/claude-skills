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
# A small shell lexer. It honours '...', "..." and backslash escapes, opens
# command substitutions ($( ) and backticks) even inside double quotes, treats a
# newline as the statement boundary it is, swallows a redirection's target so a
# filename is never mistaken for a resource id, and skips heredoc bodies.
#
# Output, one token per line:
#   W<TAB>word       an argument
#   O<TAB>operator   && || ;; | ; & ( ) ` $( NL
#   R<TAB>kind       a redirection; kind is `stdout` when standard output leaves
#                    the terminal (>, >>, &>, >&file), `other` for everything
#                    else (2>, <, <<<, 2>&1, >&2)
shell_lex() {
  printf '%s' "$1" | awk '
    { s = s $0 "\n" }
    function flush() {
      if (rt) {
        # A redirection waits for its target; whitespace in between must not
        # cancel it, or `> file` hands the filename over as a positional word.
        if (!have) return
        k = rkind
        if (rdup && (tok ~ /^[0-9]+$/ || tok == "-")) k = "other"
        print "R\t" k
        rt = 0; rdup = 0
      } else if (have) {
        gsub(/[\t\n]/, " ", tok); print "W\t" tok
      }
      tok = ""; have = 0
    }
    function op(o) { flush(); rt = 0; rdup = 0; print "O\t" o }
    function redir(kind, adv) {
      flush(); rkind = kind; rt = 1; rdup = 0; i += adv
      if (substr(s, i, 1) == "&") { rdup = 1; i++ }
    }
    function skip_heredoc(   p, e, line, rest) {
      rest = substr(s, i)
      p = 1
      while (p <= length(rest)) {
        e = index(substr(rest, p), "\n")
        if (e == 0) { line = substr(rest, p); p = length(rest) + 1 }
        else { line = substr(rest, p, e - 1); p += e }
        sub(/^\t+/, "", line)
        if (line == hd) break
      }
      i = i + p - 1
      hd = ""
    }
    END {
      n = length(s); i = 1; tok = ""; have = 0; mode = 0; sp = 0; depth = 0
      rt = 0; rdup = 0; rkind = ""; hd = ""; hdnext = 0
      while (i <= n) {
        c = substr(s, i, 1); two = substr(s, i, 2); three = substr(s, i, 3)
        if (mode == 1) {
          if (c == "\047") { mode = 0; i++; continue }
          tok = tok c; have = 1; i++; continue
        }
        if (mode == 2) {
          if (c == "\"") { mode = 0; i++; continue }
          if (c == "\\") {
            if (substr(s, i+1, 1) != "\n") tok = tok substr(s, i+1, 1)
            have = 1; i += 2; continue
          }
          if (two == "$(") { op("$("); sp++; smode[sp] = 2; sdepth[sp] = depth; skind[sp] = "p"; mode = 0; i += 2; continue }
          if (c == "`") { op("`"); sp++; smode[sp] = 2; skind[sp] = "b"; mode = 0; i++; continue }
          tok = tok c; have = 1; i++; continue
        }
        if (c == "\\") {
          if (substr(s, i+1, 1) == "\n") { flush(); i += 2; continue }
          tok = tok substr(s, i+1, 1); have = 1; i += 2; continue
        }
        if (c == "#" && !have) { while (i <= n && substr(s, i, 1) != "\n") i++; continue }
        if (c == "\047") { mode = 1; have = 1; i++; continue }
        if (c == "\"") { mode = 2; have = 1; i++; continue }
        if (two == "$(") { op("$("); sp++; smode[sp] = 0; sdepth[sp] = depth; skind[sp] = "p"; i += 2; continue }
        if (c == "`") {
          if (sp > 0 && skind[sp] == "b") { op("`"); mode = smode[sp]; sp--; i++; continue }
          op("`"); sp++; smode[sp] = 0; skind[sp] = "b"; i++; continue
        }
        if (c == "(") { op("("); depth++; i++; continue }
        if (c == ")") {
          op(")")
          if (sp > 0 && skind[sp] == "p" && depth == sdepth[sp]) { mode = smode[sp]; sp--; i++; continue }
          if (depth > 0) depth--
          i++; continue
        }
        if (hdnext && c != " " && c != "\t") {
          d = ""
          while (i <= n) {
            c = substr(s, i, 1)
            if (c == " " || c == "\t" || c == "\n" || c == ";" || c == "|" || c == "&") break
            if (c == "\047" || c == "\"" || c == "\\") { i++; continue }
            d = d c; i++
          }
          sub(/^-/, "", d)
          hd = d; hdnext = 0; continue
        }
        if (c == "\n") { op("NL"); i++; if (hd != "") skip_heredoc(); continue }
        if (three == "<<<") { redir("other", 3); continue }
        if (two == "<<") { flush(); hdnext = 1; i += 2; continue }
        if (three == "&>>") { redir("stdout", 3); continue }
        if (two == "&>") { redir("stdout", 2); continue }
        if (two == ">>") { redir("stdout", 2); continue }
        if (c == ">") { redir("stdout", 1); continue }
        if (c == "<") { redir("other", 1); continue }
        if (!have && c ~ /[0-9]/ && (substr(s, i+1, 1) == ">" || substr(s, i+1, 1) == "<")) {
          fd = c; i++
          if (substr(s, i, 2) == ">>") { redir((fd == "1") ? "stdout" : "other", 2); continue }
          if (substr(s, i, 1) == ">") { redir((fd == "1") ? "stdout" : "other", 1); continue }
          redir("other", 1); continue
        }
        if (two == "&&" || two == "||" || two == ";;") { op(two); i += 2; continue }
        if (two == "|&") { op("|"); i += 2; continue }
        if (c == "|" || c == ";" || c == "&") { op(c); i++; continue }
        if (c == " " || c == "\t") { flush(); i++; continue }
        tok = tok c; have = 1; i++
      }
      flush()
    }'
}

# Operators that end one command and begin another.
lin_is_boundary() {
  case "$1" in '&&'|'||'|';;'|'$('|'|'|';'|'&'|'('|')'|'`'|NL) return 0 ;; esac
  return 1
}

# Split a command line into candidate invocations. Fills, in parallel:
#   segs[]        words, newline-separated, each prefixed with one space (so an
#                 empty argument survives as its own line)
#   seg_stdout[]  1 when the segment's standard output goes to a file
#   seg_piped[]   1 when the segment feeds a pipe
lin_split() {
  local _line _kind _val cur="" cur_stdout=0 cur_piped=0
  while IFS= read -r _line; do
    _kind=${_line%%$'\t'*}
    _val=${_line#*$'\t'}
    case "$_kind" in
      W) cur="${cur} ${_val}"$'\n' ;;
      R) [[ "$_val" == stdout ]] && cur_stdout=1 ;;
      O)
        [[ "$_val" == '|' ]] && cur_piped=1
        if lin_is_boundary "$_val"; then
          segs[${#segs[@]}]="$cur"
          seg_stdout[${#seg_stdout[@]}]=$cur_stdout
          seg_piped[${#seg_piped[@]}]=$cur_piped
          cur=""; cur_stdout=0; cur_piped=0
        fi ;;
    esac
  done <<< "$(shell_lex "$1")"
  segs[${#segs[@]}]="$cur"
  seg_stdout[${#seg_stdout[@]}]=$cur_stdout
  seg_piped[${#seg_piped[@]}]=$cur_piped
}

# `bash -c "..."`, `eval ...` and `env -S "..."` carry a whole command line
# inside one word. Those are re-lexed and their segments appended, so the
# command inside is checked like any other. Bounded, so nesting cannot spin.
lin_split_all() {
  segs=(); seg_stdout=(); seg_piped=()
  lin_split "$1"
  local i=0
  while (( i < ${#segs[@]} && i < 64 )); do
    lin_words "${segs[i]}"
    lin_scan
    [[ -n "$LIN_NESTED" ]] && lin_split "$LIN_NESTED"
    i=$((i + 1))
  done
}

# Words of one segment into LIN_WORDS[].
lin_words() {
  LIN_WORDS=()
  local w
  while IFS= read -r w; do
    [[ -z "$w" ]] && continue
    LIN_WORDS[${#LIN_WORDS[@]}]="${w# }"
  done <<< "$1"
}

lin_join() {
  local i="$1" out=""
  while (( i < ${#LIN_WORDS[@]} )); do out="$out ${LIN_WORDS[i]}"; i=$((i + 1)); done
  printf '%s' "${out# }"
}

# --- command position -------------------------------------------------------
# A linode token only counts when it is what the shell will actually execute:
# the first word of the segment, or the operand of something that runs its
# operand. Each wrapper below is walked with its own option table, so
# `sudo -u root`, `timeout 10`, `xargs -I{}` and `opgate exec VAR=... --` all
# land on the right word. The old version guessed with a heuristic and hid every
# one of those forms — including the plugin's own documented secrets pattern.

# Heads that consume their operands as data, never as a command.
LINGATE_NONRUNNERS="echo printf grep egrep fgrep rg ag cat bat sed awk find ls \
git man which type whereis less more head tail wc sort uniq cut tr tee diff file \
stat touch mkdir rm cp mv chmod chown ln du df ps kill open pbcopy pbpaste curl \
wget python python3 node npm npx pip pip3 brew apt yum jq yq test [ true false \
read export unset alias unalias set shift return exit break continue local \
declare typeset readonly cd pushd popd pwd date sleep wait trap source . lingate"

_lin_re_assign='^[A-Za-z_][A-Za-z0-9_]*='

# lin_skip_opts <index> "<value-taking options>" — advances LIN_I past a
# wrapper's options. Anything not in the table is assumed NOT to take a value;
# for wrappers that is the safe direction, because a swallowed command word
# would hide the invocation entirely.
lin_skip_opts() {
  local i="$1" valopts="$2" w o took
  LIN_SPLITSTR=""
  while (( i < ${#LIN_WORDS[@]} )); do
    w=${LIN_WORDS[i]}
    case "$w" in
      --)      i=$((i + 1)); break ;;
      --*=*)   i=$((i + 1)); continue ;;
      -?*)     ;;
      *)       if [[ "$w" =~ $_lin_re_assign ]]; then i=$((i + 1)); continue; fi
               break ;;
    esac
    took=0
    for o in $valopts; do
      if [[ "$w" == "$o" ]]; then
        [[ "$o" == -S || "$o" == --split-string ]] && LIN_SPLITSTR="${LIN_WORDS[i+1]:-}"
        i=$((i + 2)); took=1; break
      fi
      if [[ ${#o} -eq 2 && "$w" == "$o"?* ]]; then
        [[ "$o" == -S ]] && LIN_SPLITSTR="${w#-S}"
        i=$((i + 1)); took=1; break
      fi
    done
    (( took )) && continue
    i=$((i + 1))
  done
  LIN_I=$i
}

# Sets exactly one of:
#   LIN_START         index of the linode token in command position   (return 0)
#   LIN_NESTED        a script string to lex again                     (return 2)
#   LIN_HEAD_UNKNOWN  a head this file does not know, with a linode
#                     token somewhere behind it                        (return 3)
# and returns 1 when the segment runs no linode CLI. Also picks up a leading
# LINODE_ENV=... assignment into LIN_ENV.
lin_scan() {
  LIN_START=-1; LIN_NESTED=""; LIN_HEAD_UNKNOWN=""; LIN_ENV=""
  local n=${#LIN_WORDS[@]} i=0 w base sub j hasc k
  while (( i < n )); do
    w=${LIN_WORDS[i]}
    if [[ "$w" =~ $_lin_re_assign ]]; then
      case "$w" in LINODE_ENV=*) LIN_ENV=${w#LINODE_ENV=} ;; esac
      i=$((i + 1)); continue
    fi
    base=${w##*/}
    case "$base" in
      linode-cli|linode|lin) LIN_START=$i; return 0 ;;
      --|do|then|else|elif|if|while|until|'!'|'{'|time) i=$((i + 1)); continue ;;
      env)
        lin_skip_opts $((i + 1)) "-u -C -S --unset --chdir --split-string"; i=$LIN_I
        if [[ -n "$LIN_SPLITSTR" ]]; then LIN_NESTED="$LIN_SPLITSTR"; return 2; fi
        continue ;;
      sudo|doas)
        lin_skip_opts $((i + 1)) "-u -g -p -h -C -D -r -t -U -T --user --group --prompt --host --chdir --chroot --role --type --other-user"
        i=$LIN_I; continue ;;
      command)
        case "${LIN_WORDS[i+1]:-}" in -v|-V) return 1 ;; esac
        lin_skip_opts $((i + 1)) ""; i=$LIN_I; continue ;;
      exec)             lin_skip_opts $((i + 1)) "-a"; i=$LIN_I; continue ;;
      nohup|caffeinate) lin_skip_opts $((i + 1)) "-t -w"; i=$LIN_I; continue ;;
      nice)             lin_skip_opts $((i + 1)) "-n --adjustment"; i=$LIN_I; continue ;;
      stdbuf)           lin_skip_opts $((i + 1)) "-i -o -e --input --output --error"; i=$LIN_I; continue ;;
      timeout)          lin_skip_opts $((i + 1)) "-s -k --signal --kill-after"; i=$((LIN_I + 1)); continue ;;
      xargs)            lin_skip_opts $((i + 1)) "-I -i -n -P -L -d -a -s -E --max-args --max-procs --max-lines --delimiter --arg-file --max-chars --eof --replace"; i=$LIN_I; continue ;;
      watch)            lin_skip_opts $((i + 1)) "-n --interval"; i=$LIN_I; continue ;;
      eval)             LIN_NESTED=$(lin_join $((i + 1))); return 2 ;;
      bash|sh|zsh|dash|ksh)
        # An option cluster containing c makes the next operand a script.
        j=$((i + 1)); hasc=0
        while (( j < n )) && [[ "${LIN_WORDS[j]}" == -* ]]; do
          case "${LIN_WORDS[j]}" in --) j=$((j + 1)); break ;; --*) ;; -*c*) hasc=1 ;; esac
          [[ "${LIN_WORDS[j]}" == -o ]] && j=$((j + 1))
          j=$((j + 1))
        done
        if (( hasc )) && (( j < n )); then LIN_NESTED="${LIN_WORDS[j]}"; return 2; fi
        return 1 ;;
      opgate)
        sub=${LIN_WORDS[i+1]:-}
        case "$sub" in
          exec|run) lin_skip_opts $((i + 2)) "-f --env-file"; i=$LIN_I; continue ;;
          *) return 1 ;;
        esac ;;
      *)
        case " $LINGATE_NONRUNNERS " in *" $base "*) return 1 ;; esac
        for ((k = i + 1; k < n; k++)); do
          case "${LIN_WORDS[k]##*/}" in
            linode-cli|linode|lin) LIN_HEAD_UNKNOWN="$w"; return 3 ;;
          esac
        done
        return 1 ;;
    esac
  done
  return 1
}

# First word of a segment that is not an assignment, and the word after it.
lin_head() {
  LIN_HEAD=""; LIN_HEAD_ARG=""
  local i=0
  while (( i < ${#LIN_WORDS[@]} )); do
    if [[ "${LIN_WORDS[i]}" =~ $_lin_re_assign ]]; then i=$((i + 1)); continue; fi
    LIN_HEAD=${LIN_WORDS[i]##*/}; LIN_HEAD_ARG="${LIN_WORDS[i+1]:-}"
    return 0
  done
  return 1
}

# --- flags ------------------------------------------------------------------
# linode-cli is argparse underneath, and argparse accepts any unambiguous prefix
# of a long option — so `--tag` really is `--tags` and `--root_pas` really is
# `--root_pass`. But argparse resolves an EXACT option name before it tries
# abbreviations, and so must this: `--domain` is the real field of `domains
# create`, not an abbreviation of `--domains`. Getting that wrong made every
# domains create unusable.

# Global options that take no value.
LINGATE_BOOL_NAMES="help no-defaults no-retry version text json markdown \
ascii-table pretty no-headers all all-columns all-rows no-truncation \
single-table suppress-warnings debug"

# Fields the guard acts on. Order matters for abbreviations: the first match
# wins, so `--linode` lands on linode_id and `--fire` on firewall_id.
LINGATE_REF_NAMES="tags root_pass linode_id linodes volume_id volumes domains \
nodebalancer_id nodebalancers firewall_id firewall_ids vpc_id label"

# Real field names that happen to be prefixes of a name above.
LINGATE_EXACT_NAMES="domain type id label"

# canon_flag <token> — sets CF_NAME (canonical name or `other`), CF_PARENT (the
# component before the last dot of a nested field such as devices.linodes), and
# CF_BOOL (1 when the flag takes no value).
canon_flag() {
  local f="${1%%=*}" name b vals="" bools=""
  CF_NAME=other; CF_PARENT=""; CF_BOOL=0
  case "$f" in
    -h) CF_NAME=help; CF_BOOL=1; return ;;
    -v) CF_NAME=version; CF_BOOL=1; return ;;
    --*) name=${f#--} ;;
    *) return ;;
  esac
  if [[ "$name" == *.* ]]; then
    CF_PARENT=${name%.*}; CF_PARENT=${CF_PARENT##*.}
    name=${name##*.}
  fi
  for b in $LINGATE_BOOL_NAMES; do
    [[ "$name" == "$b" ]] && { CF_NAME=$b; CF_BOOL=1; return; }
  done
  for b in $LINGATE_EXACT_NAMES $LINGATE_REF_NAMES; do
    [[ "$name" == "$b" ]] && { CF_NAME=$b; return; }
  done
  (( ${#name} >= 2 )) || return
  for b in $LINGATE_BOOL_NAMES; do [[ "$b" == "$name"* ]] && bools="$bools $b"; done
  for b in $LINGATE_REF_NAMES $LINGATE_EXACT_NAMES; do [[ "$b" == "$name"* ]] && vals="$vals $b"; done
  if [[ -n "$vals" ]]; then
    vals=${vals# }; CF_NAME=${vals%% *}
  elif [[ -n "$bools" ]]; then
    bools=${bools# }; CF_NAME=${bools%% *}; CF_BOOL=1
  fi
}

# A command may name a second resource it is about to join to the first — the
# Linode a volume attaches to, a firewall device, a VPC an interface joins.
# Those are writes on that resource too, so they get the same ownership check.
# A value that cannot be read (a shell variable, a JSON blob) is recorded as
# unverifiable rather than dropped: dropping it was how `--linode_id $ID`
# skipped the check that `--linode_id 123` got.
lin_add_ref() {
  local g="$1" v="$2" x
  [[ -n "$v" ]] || return 0
  v=${v#[}; v=${v%]}
  local IFS=,
  for x in $v; do
    x=${x// /}
    [[ -n "$x" ]] || continue
    if [[ "$x" =~ ^[A-Za-z0-9][A-Za-z0-9/._-]*$ ]]; then
      LIN_REF_GROUPS[${#LIN_REF_GROUPS[@]}]="$g"
      LIN_REF_IDS[${#LIN_REF_IDS[@]}]="$x"
    else
      LIN_BAD_REFS[${#LIN_BAD_REFS[@]}]="$g $x"
    fi
  done
}

# --- command parsing --------------------------------------------------------
# parse_linode_cmd <segment>
#   0  an invocation: LIN_GROUP LIN_ACTION LIN_IDS[] LIN_TAGS[] LIN_HAS_JSON
#      LIN_ROOTPASS LIN_ENV LIN_HELP LIN_LABEL LIN_TAG_ATTACH LIN_REF_GROUPS[]
#      LIN_REF_IDS[] LIN_BAD_REFS[] are set
#   1  no linode CLI in this segment
#   2  a nested script (already re-lexed by lin_split_all)
#   3  an unknown head with a linode token behind it (LIN_HEAD_UNKNOWN)
parse_linode_cmd() {
  LIN_GROUP=""; LIN_ACTION=""; LIN_IDS=(); LIN_TAGS=()
  LIN_HAS_JSON=0; LIN_ROOTPASS=""; LIN_HELP=0; LIN_LABEL=""; LIN_TAG_ATTACH=0
  LIN_REF_GROUPS=(); LIN_REF_IDS=(); LIN_BAD_REFS=()
  LIN_GENERIC_ID=""; LIN_GENERIC_TYPE=""

  lin_words "$1"
  lin_scan
  local rc=$?
  (( rc == 0 )) || return $rc

  local n=${#LIN_WORDS[@]} j=$((LIN_START + 1)) stage=0 t val
  while (( j < n )); do
    t=${LIN_WORDS[j]}
    if [[ "$t" == -?* ]]; then
      canon_flag "$t"
      val=""
      if [[ "$t" == *=* ]]; then
        val=${t#*=}
      elif (( CF_BOOL == 0 )); then
        val="${LIN_WORDS[j+1]:-}"; j=$((j + 1))
      fi
      case "$CF_NAME" in
        help)      LIN_HELP=1 ;;
        json)      LIN_HAS_JSON=1 ;;
        tags)      [[ -n "$val" ]] && LIN_TAGS[${#LIN_TAGS[@]}]="$val" ;;
        root_pass) LIN_ROOTPASS="$val" ;;
        label)     LIN_LABEL="$val" ;;
        id)        LIN_GENERIC_ID="$val"
                   [[ "$CF_PARENT" == placement_group ]] && lin_add_ref placement "$val" ;;
        type)      LIN_GENERIC_TYPE="$val" ;;
        linodes|linode_id)             lin_add_ref linodes "$val" ;;
        volumes|volume_id)             lin_add_ref volumes "$val" ;;
        domains)                       lin_add_ref domains "$val" ;;
        nodebalancers|nodebalancer_id) lin_add_ref nodebalancers "$val" ;;
        firewall_id|firewall_ids)      lin_add_ref firewalls "$val" ;;
        vpc_id)                        lin_add_ref vpcs "$val" ;;
      esac
      case "$CF_NAME" in
        linodes|volumes|domains|nodebalancers) [[ -z "$CF_PARENT" ]] && LIN_TAG_ATTACH=1 ;;
      esac
      j=$((j + 1)); continue
    fi
    case $stage in
      0) LIN_GROUP="$t"; stage=1 ;;
      1) LIN_ACTION="$t"; stage=2 ;;
      *) LIN_IDS[${#LIN_IDS[@]}]="$t" ;;
    esac
    j=$((j + 1))
  done

  # `firewalls device-create 999 --id 123 --type linode` names its second
  # resource through generic fields instead of a typed flag.
  if [[ "$LIN_GROUP $LIN_ACTION" == "firewalls device-create" && -n "$LIN_GENERIC_ID" ]]; then
    case "$LIN_GENERIC_TYPE" in
      linode)       lin_add_ref linodes "$LIN_GENERIC_ID" ;;
      nodebalancer) lin_add_ref nodebalancers "$LIN_GENERIC_ID" ;;
      *)            LIN_BAD_REFS[${#LIN_BAD_REFS[@]}]="firewall-device $LIN_GENERIC_ID" ;;
    esac
  fi
  return 0
}

# The id the ledger uses for a resource. Object Storage buckets have no numeric
# id; the API addresses them as <region>/<label>, and so does the ledger.
lin_owner_id() {
  if [[ "$LIN_GROUP" == object-storage ]] && (( ${#LIN_IDS[@]} >= 2 )); then
    printf '%s/%s' "${LIN_IDS[0]}" "${LIN_IDS[1]}"
  else
    printf '%s' "${LIN_IDS[0]:-}"
  fi
}

# --- ownership --------------------------------------------------------------

# LINGATE_BUDGET: seconds the whole hook may spend on API lookups. Claude Code
# kills a PreToolUse hook at its configured timeout (15 s in hooks.json) and
# then DISCARDS its decision — the one failure this guard cannot turn into a
# refusal. So every lookup shares one budget, each call gets what is left, and
# an exhausted budget is a refusal issued while there is still time to issue it.
LINGATE_BUDGET="${LINGATE_BUDGET:-11}"

# Seconds available for one more API call, or failure when the budget is spent.
lookup_deadline() {
  local now elapsed left
  [[ -n "${LINGATE_T0:-}" ]] || LINGATE_T0=$(date +%s)
  now=$(date +%s)
  elapsed=$((now - LINGATE_T0))
  left=$((LINGATE_BUDGET - elapsed))
  (( left >= 1 )) || return 1
  if (( left < LINGATE_DEADLINE )); then printf '%s' "$left"; else printf '%s' "$LINGATE_DEADLINE"; fi
}

# Run a command under a hard deadline. macOS ships no timeout(1); perl's alarm is
# the portable stand-in.
deadline_run() {
  local secs="$1"; shift
  if command -v perl >/dev/null 2>&1; then
    perl -e 'alarm shift @ARGV; exec @ARGV or exit 127' "$secs" "$@"
  else
    "$@"
  fi
}

# Print the identity that was actually consulted as a first line `@<group>/<id>`,
# then the resource's tags one per line. No tag lines means the resource exists
# and carries none. Exit 1 means ownership could NOT be established — the guard
# turns that into a refusal, never into permission.
# resolve_tags <group> <id> [fresh]  — fresh=1 ignores the cache.
resolve_tags() {
  local group="$1" id="$2" fresh="${3:-0}" cache raw="" now mtime label own secs
  [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9/._-]*$ ]] || return 1

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
    secs=$(lookup_deadline) || return 1
    raw=$(deadline_run "$secs" linode-cli "$group" "$(view_action_for "$group")" \
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

  printf '@%s/%s\n' "$group" "$id"
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
