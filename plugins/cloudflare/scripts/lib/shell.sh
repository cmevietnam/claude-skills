#!/usr/bin/env bash
# Reading a shell command line: a small lexer, a splitter into invocations, and
# the walk past wrappers (sudo, env, timeout, bash -c ...) to the word the shell
# will actually execute. Sourced by scripts/guard-cloudflare.sh.
#
# Adapted from the linode plugin's lexer, with structural changes found by two
# review rounds:
#   - a command substitution does not split the word around it: in
#       curl -H "Authorization: Bearer $(cat t)" https://api.cloudflare.com/...
#     the URL stays part of the curl call, and the word keeps a `$` as a marker
#     that part of it came from the shell;
#   - a heredoc's delimiter may be quoted (<<'EOF', <<"EOF", <<\EOF). Missing
#     that once made every body line a command, and one apostrophe in the body
#     hid every line after it;
#   - a heredoc's body is kept, because `bash <<EOF` runs it;
#   - $((...)) is arithmetic, so its << is a shift, not a heredoc; $'...' is a
#     quote; backslash-newline joins a word instead of splitting it.

# --- lexing -----------------------------------------------------------------
# Output, one token per line:
#   W<TAB>word       an argument
#   O<TAB>operator   && || ;; | ; & ( ) NL, and `$(` / `$)` around the inner
#                    command of a substitution ($( ) or backticks)
#   R<TAB>kind       a redirection: `stdout` when standard output goes to a
#                    file (>, >>, &>, 1>; not /dev/stdout, /dev/stderr, /dev/tty,
#                    /dev/fd/1|2, which still print), `stdin` for < and a
#                    here-string whose value comes from the shell, `stdin-lit`
#                    for a here-string written out literally, `heredoc` for <<
#                    (always literal), `other` for the rest (2>, 2>&1, >&2)
#   H<TAB>body       the body of the heredoc opened by the most recent `heredoc`
#                    redirection still waiting for one; newlines are \001
shell_lex() {
  printf '%s' "$1" | awk '
    { s = s $0 "\n" }
    function flush(   k) {
      if (rt) {
        # A redirection waits for its target; whitespace in between must not
        # cancel it, or `> file` hands the filename over as a positional word.
        if (!have) return
        k = rkind
        if (rdup && (tok ~ /^[0-9]+$/ || tok == "-")) k = "other"
        if (k == "stdout" && tok ~ /^\/dev\/(stdout|stderr|tty|fd\/[12])$/) k = "other"
        if (k == "herestr") k = (tok == "" || tok ~ /\$/) ? "stdin" : "stdin-lit"
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
    # A substitution opens: park the word being built, lex the inner command,
    # and resume the word when it closes.
    function sub_open(kind, adv) {
      sp++; smode[sp] = mode; skind[sp] = kind; sdepth[sp] = depth
      stok[sp] = tok; shave[sp] = have; srt[sp] = rt; srkind[sp] = rkind; srdup[sp] = rdup
      tok = ""; have = 0; rt = 0; rdup = 0; mode = 0
      print "O\t$("
      i += adv
    }
    function sub_close() {
      flush()
      print "O\t$)"
      mode = smode[sp]; tok = stok[sp] "$"; have = 1
      rt = srt[sp]; rkind = srkind[sp]; rdup = srdup[sp]
      sp--
      i++
    }
    # $(( ... )): arithmetic. Kept as one opaque piece of the current word.
    function arith(   d, c) {
      i += 3; d = 2
      while (i <= n && d > 0) {
        c = substr(s, i, 1)
        if (c == "(") d++
        else if (c == ")") d--
        i++
      }
      tok = tok "$"; have = 1
    }
    # The body of a pending heredoc starts at i (just after the newline).
    function heredoc_body(   p, e, line, rest, body, first) {
      rest = substr(s, i)
      p = 1; body = ""; first = 1
      while (p <= length(rest)) {
        e = index(substr(rest, p), "\n")
        if (e == 0) { line = substr(rest, p); p = length(rest) + 1 }
        else { line = substr(rest, p, e - 1); p += e }
        if (hdtabs) sub(/^\t+/, "", line)
        if (line == hd) break
        body = body (first ? "" : "\001") line; first = 0
      }
      i = i + p - 1
      gsub(/\t/, " ", body)
      print "H\t" body
      hd = ""; hdtabs = 0
    }
    END {
      n = length(s); i = 1; tok = ""; have = 0; mode = 0; sp = 0; depth = 0
      rt = 0; rdup = 0; rkind = ""; hd = ""; hdnext = 0; hdtabs = 0
      while (i <= n) {
        c = substr(s, i, 1); two = substr(s, i, 2); three = substr(s, i, 3)
        if (mode == 1) {
          if (c == "\047") { mode = 0; i++; continue }
          tok = tok c; have = 1; i++; continue
        }
        if (mode == 3) {                       # $'"'"'...'"'"' with backslash escapes
          if (c == "\\") { tok = tok substr(s, i+1, 1); have = 1; i += 2; continue }
          if (c == "\047") { mode = 0; i++; continue }
          tok = tok c; have = 1; i++; continue
        }
        if (mode == 2) {
          if (c == "\"") { mode = 0; i++; continue }
          if (c == "\\") {
            if (substr(s, i+1, 1) != "\n") tok = tok substr(s, i+1, 1)
            have = 1; i += 2; continue
          }
          if (three == "$((") { arith(); continue }
          if (two == "$(") { sub_open("p", 2); continue }
          if (c == "`") { sub_open("b", 1); continue }
          tok = tok c; have = 1; i++; continue
        }
        # The word after << is the delimiter, quoted or not. It must be read
        # before the quote rules below, or <<'"'"'EOF'"'"' opens a quote instead.
        if (hdnext && c != " " && c != "\t") {
          d = ""
          if (c == "-") { hdtabs = 1; i++; c = substr(s, i, 1) }
          while (i <= n) {
            c = substr(s, i, 1)
            if (c == " " || c == "\t" || c == "\n" || c == ";" || c == "|" || c == "&" || c == ")" || c == "<" || c == ">") break
            if (c == "\047" || c == "\"" || c == "\\") { i++; continue }
            d = d c; i++
          }
          hd = d; hdnext = 0; continue
        }
        if (c == "\\") {
          # Backslash-newline joins: `wrang\<NL>ler` is the word wrangler.
          if (substr(s, i+1, 1) == "\n") { i += 2; continue }
          tok = tok substr(s, i+1, 1); have = 1; i += 2; continue
        }
        if (c == "#" && !have) { while (i <= n && substr(s, i, 1) != "\n") i++; continue }
        if (two == "$\047") { mode = 3; have = 1; i += 2; continue }
        if (c == "\047") { mode = 1; have = 1; i++; continue }
        if (c == "\"") { mode = 2; have = 1; i++; continue }
        if (three == "$((") { arith(); continue }
        if (two == "$(") { sub_open("p", 2); continue }
        if (c == "`") {
          if (sp > 0 && skind[sp] == "b") { sub_close(); continue }
          sub_open("b", 1); continue
        }
        if (c == "(") { op("("); depth++; i++; continue }
        if (c == ")") {
          if (sp > 0 && skind[sp] == "p" && depth == sdepth[sp]) { sub_close(); continue }
          op(")")
          if (depth > 0) depth--
          i++; continue
        }
        if (c == "\n") {
          op("NL"); i++
          if (hd != "") heredoc_body()
          continue
        }
        if (three == "<<<") { redir("herestr", 3); continue }
        if (two == "<<") { flush(); print "R\theredoc"; hdnext = 1; i += 2; continue }
        if (three == "&>>") { redir("stdout", 3); continue }
        if (two == "&>") { redir("stdout", 2); continue }
        if (two == ">>") { redir("stdout", 2); continue }
        if (c == ">") { redir("stdout", 1); continue }
        if (c == "<") { redir("stdin", 1); continue }
        if (!have && c ~ /[0-9]/ && (substr(s, i+1, 1) == ">" || substr(s, i+1, 1) == "<")) {
          fd = c; i++
          if (substr(s, i, 2) == ">>") { redir((fd == "1") ? "stdout" : "other", 2); continue }
          if (substr(s, i, 1) == ">") { redir((fd == "1") ? "stdout" : "other", 1); continue }
          redir((fd == "0") ? "stdin" : "other", 1); continue
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
sh_is_boundary() {
  case "$1" in '&&'|'||'|';;'|'|'|';'|'&'|'('|')'|NL) return 0 ;; esac
  return 1
}

# Split a command line into candidate invocations. Fills, in parallel (the
# caller declares them `local` so a nested script gets its own set):
#   segs[]         words, newline-separated, each prefixed with one space (so
#                  an empty argument survives as its own line)
#   seg_stdout[]   1 when the segment's standard output goes to a file
#   seg_piped[]    1 when the segment feeds a pipe
#   seg_stdin[]    ""|stdin|stdin-lit|heredoc: where standard input comes from
#   seg_fed[]      index of the segment piping into this one, or -1
#   seg_cap[]      1 when the segment runs inside a command substitution, so
#                  its standard output goes to the shell, not to the terminal
#   seg_gid[]      the id of the substitution the segment runs inside (0: none)
#   seg_kids[]     " id id " of the substitutions inside this segment's words;
#                  sh_outer_of finds who receives a substitution's output
#   seg_depth[]    ( ) subshell depth: a `cd` inside a subshell ends with it
#   seg_hd[]       the heredoc body fed to the segment (\001 for newlines)
sh_split() {
  local _line _kind _val
  local cur="" c_out=0 c_pipe=0 c_in="" c_fed=-1 c_cap=0 c_gid=0 c_kids=" " depth=0
  local pdepth=0 hd_pending=0 hd_queue=""
  local -a st_cur=() st_out=() st_pipe=() st_in=() st_fed=() st_cap=() st_gid=() st_kids=()
  _sh_store() {
    local n=${#segs[@]}
    segs[n]="$cur"
    seg_stdout[n]=$c_out
    seg_piped[n]=$c_pipe
    seg_stdin[n]="$c_in"
    seg_fed[n]=$c_fed
    seg_cap[n]=$c_cap
    seg_gid[n]=$c_gid
    seg_kids[n]="$c_kids"
    seg_depth[n]=$pdepth
    seg_hd[n]=""
    if (( hd_pending )); then hd_queue="$hd_queue $n"; hd_pending=0; fi
  }
  while IFS= read -r _line; do
    _kind=${_line%%$'\t'*}
    _val=${_line#*$'\t'}
    case "$_kind" in
      W) cur="${cur} ${_val}"$'\n' ;;
      R) case "$_val" in
           stdout) c_out=1 ;;
           stdin|stdin-lit) c_in="$_val" ;;
           heredoc) c_in=heredoc; hd_pending=1 ;;
         esac ;;
      H)
        # The body belongs to the oldest segment still waiting for one; it may
        # already be stored (`bash <<EOF && echo hi` ends it before the body).
        local _owner=${hd_queue# }; _owner=${_owner%% *}
        hd_queue=${hd_queue# }; hd_queue=${hd_queue#"$_owner"}
        [[ -n "$_owner" ]] && seg_hd[_owner]="$_val" ;;
      O)
        case "$_val" in
          '$(')
            st_cur[depth]="$cur"; st_out[depth]=$c_out; st_pipe[depth]=$c_pipe
            st_in[depth]="$c_in"; st_fed[depth]=$c_fed; st_cap[depth]=$c_cap
            SH_GID=$((SH_GID + 1))
            st_gid[depth]=$c_gid; st_kids[depth]="$c_kids$SH_GID "
            depth=$((depth + 1))
            cur=""; c_out=0; c_pipe=0; c_in=""; c_fed=-1; c_cap=1; c_gid=$SH_GID; c_kids=" "
            continue ;;
          '$)')
            _sh_store
            (( depth > 0 )) && depth=$((depth - 1))
            cur="${st_cur[depth]:-}"; c_out=${st_out[depth]:-0}; c_pipe=${st_pipe[depth]:-0}
            c_in="${st_in[depth]:-}"; c_fed=${st_fed[depth]:--1}; c_cap=${st_cap[depth]:-0}
            c_gid=${st_gid[depth]:-0}; c_kids="${st_kids[depth]:- }"
            continue ;;
        esac
        if sh_is_boundary "$_val"; then
          [[ "$_val" == '|' ]] && c_pipe=1
          _sh_store
          if [[ "$_val" == '|' ]]; then c_fed=$(( ${#segs[@]} - 1 )); else c_fed=-1; fi
          cur=""; c_out=0; c_pipe=0; c_in=""; c_kids=" "
          (( depth > 0 )) && c_cap=1 || c_cap=0
          case "$_val" in
            '(') pdepth=$((pdepth + 1)) ;;
            ')') (( pdepth > 0 )) && pdepth=$((pdepth - 1)) ;;
          esac
        fi ;;
    esac
  done <<< "$(shell_lex "$1")"
  _sh_store
}

# The segment whose words contain substitution <gid>, i.e. the command that
# receives that substitution's output. Prints its index.
sh_outer_of() {
  local j=0
  while (( j < ${#segs[@]} )); do
    [[ "${seg_kids[j]}" == *" $1 "* ]] && { printf '%s' "$j"; return 0; }
    j=$((j + 1))
  done
  return 1
}

# Words of one segment into SH_WORDS[].
sh_words() {
  SH_WORDS=()
  local w
  while IFS= read -r w; do
    [[ -z "$w" ]] && continue
    SH_WORDS[${#SH_WORDS[@]}]="${w# }"
  done <<< "$1"
}

sh_join() {
  local i="$1" out=""
  while (( i < ${#SH_WORDS[@]} )); do out="$out ${SH_WORDS[i]}"; i=$((i + 1)); done
  printf '%s' "${out# }"
}

# --- command position --------------------------------------------------------
# A tool name only counts when it is what the shell will actually execute: the
# first word of the segment, or the operand of something that runs its operand.

# Heads that consume their operands as data, never as a command.
SH_NONRUNNERS="echo printf grep egrep fgrep rg ag cat bat sed awk ls git man \
which type whereis less more head tail wc sort uniq cut tr tee diff file stat touch \
mkdir rm cp mv chmod chown ln du df ps kill open pbcopy pbpaste jq yq test [ true \
false read export unset alias unalias set shift return exit break continue local \
declare typeset readonly cd pushd popd pwd date sleep wait trap source . cfgate \
dig nslookup host whois code vim nvim nano brew apt apt-get port yum dnf gh glab \
prettier shellcheck"

_sh_re_assign='^[A-Za-z_][A-Za-z0-9_]*='

# The tool a word names, case-insensitively (macOS file systems ignore case, so
# WRANGLER runs wrangler): sets SH_T to wrangler | cloudflared | curl | cf, or
# fails. `cloudflare` is the npm package's second name for cf.
# A variable, not output: this runs for every word, and $(...) would fork.
sh_tool_of() {
  SH_T=""
  case "${1##*/}" in
    [Ww][Rr][Aa][Nn][Gg][Ll][Ee][Rr]|[Ww][Rr][Aa][Nn][Gg][Ll][Ee][Rr]@*) SH_T=wrangler ;;
    [Cc][Ll][Oo][Uu][Dd][Ff][Ll][Aa][Rr][Ee][Dd]) SH_T=cloudflared ;;
    [Cc][Uu][Rr][Ll]) SH_T=curl ;;
    [Cc][Ff]|[Cc][Ll][Oo][Uu][Dd][Ff][Ll][Aa][Rr][Ee]) SH_T=cf ;;
    *) return 1 ;;
  esac
}

# sh_skip_opts <index> "<value-taking options>" — advances SH_I past a
# wrapper's options. Anything not in the table is assumed NOT to take a value;
# for wrappers that is the safe direction, because a swallowed command word
# would hide the invocation entirely. Options listed in SH_CHDIR_OPTS set
# SH_CHDIR (the directory the wrapped command runs in).
sh_skip_opts() {
  local i="$1" valopts="$2" w o took
  SH_SPLITSTR=""
  while (( i < ${#SH_WORDS[@]} )); do
    w=${SH_WORDS[i]}
    case "$w" in
      --)      i=$((i + 1)); break ;;
      --*=*)   case " ${SH_CHDIR_OPTS:-} " in *" ${w%%=*} "*) SH_CHDIR="${w#*=}" ;; esac
               i=$((i + 1)); continue ;;
      -?*)     ;;
      *)       if [[ "$w" =~ $_sh_re_assign ]]; then i=$((i + 1)); continue; fi
               break ;;
    esac
    took=0
    for o in $valopts; do
      if [[ "$w" == "$o" ]]; then
        [[ "$o" == -S || "$o" == --split-string ]] && SH_SPLITSTR="${SH_WORDS[i+1]:-}"
        case " ${SH_CHDIR_OPTS:-} " in *" $o "*) SH_CHDIR="${SH_WORDS[i+1]:-}" ;; esac
        i=$((i + 2)); took=1; break
      fi
      if [[ ${#o} -eq 2 && "$w" == "$o"?* ]]; then
        [[ "$o" == -S ]] && SH_SPLITSTR="${w#-S}"
        case " ${SH_CHDIR_OPTS:-} " in *" $o "*) SH_CHDIR="${w#$o}" ;; esac
        i=$((i + 1)); took=1; break
      fi
    done
    (( took )) && continue
    i=$((i + 1))
  done
  SH_I=$i
}

# Sets exactly one outcome, by return code:
#   0  SH_TOOL + SH_START: the tool (wrangler|cloudflared|curl) in command
#      position and its index; SH_VIA names a package runner that may download
#      (npx, bunx, dlx, npm-exec); SH_CHDIR is a directory the command is told
#      to run in (env -C, sudo -D, pnpm -C, yarn --cwd), or empty
#   1  the segment runs none of the tools
#   2  SH_NESTED: a script string to check as a command line of its own
#   3  SH_HEAD_UNKNOWN: a head this file does not know, with a tool word behind it
#   4  SH_HEAD_UNKNOWN: the command name itself comes from the shell ($X, $(...))
#   5  a shell that reads its script from standard input (bash <<EOF, ... | sh)
# SH_ASSIGNS[] collects every VAR=value word in front of the command.
sh_scan() {
  SH_TOOL=""; SH_START=-1; SH_VIA=""; SH_NESTED=""; SH_HEAD_UNKNOWN=""; SH_ASSIGNS=()
  SH_CHDIR=""
  local n=${#SH_WORDS[@]} i=0 w base sub j hasc k
  while (( i < n )); do
    w=${SH_WORDS[i]}
    if [[ "$w" =~ $_sh_re_assign ]]; then
      SH_ASSIGNS[${#SH_ASSIGNS[@]}]="$w"
      i=$((i + 1)); continue
    fi
    if sh_tool_of "$w"; then SH_TOOL=$SH_T; SH_START=$i; return 0; fi
    case "$w" in *'$'*|*'`'*) SH_HEAD_UNKNOWN="$w"; return 4 ;; esac
    base=${w##*/}
    case "$base" in
      --|do|then|else|elif|if|while|until|'!'|'{'|time) i=$((i + 1)); continue ;;
      command|builtin)
        case "${SH_WORDS[i+1]:-}" in -v|-V) return 1 ;; esac
        i=$((i + 1)); continue ;;
      node|nodejs|bun)
        # node .../wrangler/bin/wrangler.js, node .../wrangler-dist/cli.js
        j=$((i + 1))
        while (( j < n )) && [[ "${SH_WORDS[j]}" == -* ]]; do j=$((j + 1)); done
        case "${SH_WORDS[j]:-}" in
          *[Ww]rangler*) SH_TOOL=wrangler; SH_START=$j; return 0 ;;
          */node_modules/cf/*|node_modules/cf/*) SH_TOOL=cf; SH_START=$j; return 0 ;;
        esac
        break ;;
      npx|bunx)
        # npx [-y] [-p pkg] wrangler ... — the package runner may download.
        sh_skip_opts $((i + 1)) "-p --package -c --call"; j=$SH_I
        if (( j < n )) && sh_tool_of "${SH_WORDS[j]}" && [[ $SH_T == wrangler || $SH_T == cf ]]; then
          SH_TOOL=$SH_T; SH_START=$j; SH_VIA=$base; return 0
        fi
        break ;;
      pnpm|yarn)
        SH_CHDIR_OPTS="-C --dir --cwd"
        sh_skip_opts $((i + 1)) "-C --dir --cwd --filter -F --workspace-concurrency --reporter --loglevel"
        SH_CHDIR_OPTS=""; j=$SH_I
        case "${SH_WORDS[j]:-}" in
          dlx)  j=$((j + 1)); SH_VIA=dlx ;;
          exec) j=$((j + 1)) ;;
        esac
        if sh_tool_of "${SH_WORDS[j]:-}" && [[ $SH_T == wrangler || $SH_T == cf ]]; then
          SH_TOOL=$SH_T; SH_START=$j; return 0
        fi
        SH_VIA=""; break ;;
      npm)
        case "${SH_WORDS[i+1]:-}" in
          exec|x)
            sh_skip_opts $((i + 2)) "-p --package -c --call -w --workspace"; j=$SH_I
            if (( j < n )) && sh_tool_of "${SH_WORDS[j]}" && [[ $SH_T == wrangler || $SH_T == cf ]]; then
              SH_TOOL=$SH_T; SH_START=$j; SH_VIA=npm-exec; return 0
            fi ;;
        esac
        break ;;
      env)
        SH_CHDIR_OPTS="-C --chdir"
        sh_skip_opts $((i + 1)) "-u -C -S --unset --chdir --split-string"
        SH_CHDIR_OPTS=""
        # env's own VAR=value operands are assignments for the command too.
        k=$((i + 1))
        while (( k < SH_I )); do
          [[ "${SH_WORDS[k]}" =~ $_sh_re_assign ]] && SH_ASSIGNS[${#SH_ASSIGNS[@]}]="${SH_WORDS[k]}"
          k=$((k + 1))
        done
        i=$SH_I
        if [[ -n "$SH_SPLITSTR" ]]; then SH_NESTED="$SH_SPLITSTR"; return 2; fi
        continue ;;
      sudo|doas)
        SH_CHDIR_OPTS="-D --chdir"
        sh_skip_opts $((i + 1)) "-u -g -p -h -C -D -r -t -U -T --user --group --prompt --host --chdir --chroot --role --type --other-user"
        SH_CHDIR_OPTS=""
        i=$SH_I; continue ;;
      exec)             sh_skip_opts $((i + 1)) "-a"; i=$SH_I; continue ;;
      nohup|caffeinate) sh_skip_opts $((i + 1)) "-t -w"; i=$SH_I; continue ;;
      nice)             sh_skip_opts $((i + 1)) "-n --adjustment"; i=$SH_I; continue ;;
      stdbuf)           sh_skip_opts $((i + 1)) "-i -o -e --input --output --error"; i=$SH_I; continue ;;
      timeout|gtimeout) sh_skip_opts $((i + 1)) "-s -k --signal --kill-after"; i=$((SH_I + 1)); continue ;;
      xargs)            sh_skip_opts $((i + 1)) "-I -i -n -P -L -d -a -s -E --max-args --max-procs --max-lines --delimiter --arg-file --max-chars --eof --replace"; i=$SH_I; continue ;;
      watch)            sh_skip_opts $((i + 1)) "-n --interval"; i=$SH_I; continue ;;
      perl)
        # perl -e 'alarm N; exec @ARGV' cmd ... — the documented macOS timeout.
        if [[ "${SH_WORDS[i+1]:-}" == -e && "${SH_WORDS[i+2]:-}" == *'exec @ARGV'* ]]; then
          i=$((i + 3)); [[ "${SH_WORDS[i]:-}" =~ ^[0-9]+$ ]] && i=$((i + 1)); continue
        fi
        break ;;
      eval)             SH_NESTED=$(sh_join $((i + 1))); return 2 ;;
      bash|sh|zsh|dash|ksh)
        # Options first. A cluster containing c makes the next operand a
        # script; -o/-O/+o/+O and --rcfile/--init-file take a value.
        j=$((i + 1)); hasc=0
        while (( j < n )); do
          case "${SH_WORDS[j]}" in
            --) j=$((j + 1)); break ;;
            --rcfile|--init-file) j=$((j + 2)); continue ;;
            --*) j=$((j + 1)); continue ;;
            -o|+o|-O|+O) j=$((j + 2)); continue ;;
            [-+]*c*) hasc=1 ;;
            [-+]?*) ;;
            *) break ;;
          esac
          j=$((j + 1))
        done
        if (( hasc )); then
          (( j < n )) && { SH_NESTED="${SH_WORDS[j]}"; return 2; }
          return 1
        fi
        # No -c: a script file operand runs a file the guard cannot see (a
        # documented limit); no operand reads the script from standard input.
        (( j < n )) && return 1
        return 5 ;;
      opgate)
        sub=${SH_WORDS[i+1]:-}
        case "$sub" in
          exec|run) sh_skip_opts $((i + 2)) "-f --env-file"; i=$SH_I; continue ;;
          *) return 1 ;;
        esac ;;
    esac
    case " $SH_NONRUNNERS " in *" $base "*) return 1 ;; esac
    for ((k = i + 1; k < n; k++)); do
      if sh_tool_of "${SH_WORDS[k]}"; then SH_HEAD_UNKNOWN="$w"; return 3; fi
    done
    return 1
  done
  return 1
}

# First word of a segment that is not an assignment, and the word after it.
sh_head() {
  SH_HEAD=""; SH_HEAD_ARG=""
  local i=0
  while (( i < ${#SH_WORDS[@]} )); do
    if [[ "${SH_WORDS[i]}" =~ $_sh_re_assign ]]; then i=$((i + 1)); continue; fi
    SH_HEAD=${SH_WORDS[i]##*/}; SH_HEAD_ARG="${SH_WORDS[i+1]:-}"
    return 0
  done
  return 1
}

# Is a value read from the command text, or does the shell supply it? A `$`
# anywhere means a variable or a substitution; an empty value means the whole
# word came from a substitution (the lexer leaves `$` in that case too).
is_literal() {
  [[ -n "$1" && "$1" != *'$'* && "$1" != *'`'* ]]
}
