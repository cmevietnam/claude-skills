#!/usr/bin/env bash
# Reading a curl call to the Cloudflare REST API. Sourced by
# scripts/guard-cloudflare.sh.

# curl short options that take a value; a cluster such as -sSX or -XPOST ends at
# the first of these, and the rest of the cluster (or the next word) is its value.
CURL_SHORT_VAL="XHdFTouAebcKwmxErYyzCDUQ"
CURL_LONG_VAL=" --request --header --data --data-raw --data-binary --data-urlencode \
--data-ascii --json --form --form-string --upload-file --output --user --user-agent \
--referer --cookie --cookie-jar --config --write-out --max-time --connect-timeout \
--retry --retry-delay --retry-max-time --proxy --resolve --connect-to --cacert --capath \
--cert --key --cert-type --key-type --oauth2-bearer --url --range --limit-rate \
--interface --dns-servers --output-dir --variable --expand-url --expand-data \
--expand-header --proxy-user --aws-sigv4 --trace --trace-ascii --stderr --unix-socket \
--abstract-unix-socket --max-filesize --speed-limit --speed-time --keepalive-time \
--happy-eyeballs-timeout-ms --request-target --preproxy --mail-from --mail-rcpt "

# parse_curl <from> <to> — reads SH_WORDS[from, to): ONE transfer of a curl call
# (curl --next / -: starts another, with its own method and URLs). Sets:
#   C_METHOD          the HTTP method curl will send for this transfer
#   C_URLS[]          URLs that point at api.cloudflare.com, any case
#   C_DYN_URLS[]      URLs with a part the shell fills in ($VAR, $(...))
#   C_ODD_URLS[]      URLs that mention cloudflare but cannot be parsed plainly
#                     (curl URL globbing {a,b} [1-9], odd hosts)
#   C_SECRET_LIT      what carries a literal credential, if anything
#   C_CONFIG          1 when -K/--config reads options from a file
#   C_TARGET          1 when --request-target replaces the path sent
#   C_VERBOSE         1 when -v/--verbose/--trace prints the request headers
#   C_GLOBOFF         1 when -g/--globoff turns URL globbing off
parse_curl() {
  C_METHOD=""; C_URLS=(); C_DYN_URLS=(); C_ODD_URLS=(); C_SECRET_LIT=""; C_CONFIG=0
  C_TARGET=0; C_VERBOSE=0; C_GLOBOFF=0
  local from="$1" to="$2" j t f val k ch rest
  local explicit="" has_data=0 has_get=0 has_head=0 has_upload=0
  local -a vals=() flags=() urls=()
  j=$from
  while (( j < to )); do
    t=${SH_WORDS[j]}
    if [[ "$t" == --?* ]]; then
      f=${t%%=*}; val=""
      if [[ "$t" == *=* ]]; then val=${t#*=}
      elif [[ "$CURL_LONG_VAL" == *" $f "* ]]; then val="${SH_WORDS[j+1]:-}"; j=$((j + 1)); fi
      flags[${#flags[@]}]="$f"; vals[${#vals[@]}]="$val"
      j=$((j + 1)); continue
    fi
    if [[ "$t" == -?* ]]; then
      # A cluster of short options: -sS, -XPOST, -sSX POST, -fsSL.
      k=1
      while (( k < ${#t} )); do
        ch=${t:k:1}
        if [[ "$CURL_SHORT_VAL" == *"$ch"* ]]; then
          rest=${t:k+1}
          if [[ -n "$rest" ]]; then val="$rest"; else val="${SH_WORDS[j+1]:-}"; j=$((j + 1)); fi
          flags[${#flags[@]}]="-$ch"; vals[${#vals[@]}]="$val"
          break
        fi
        flags[${#flags[@]}]="-$ch"; vals[${#vals[@]}]=""
        k=$((k + 1))
      done
      j=$((j + 1)); continue
    fi
    urls[${#urls[@]}]="$t"
    j=$((j + 1))
  done

  local i=0 v lv
  while (( i < ${#flags[@]} )); do
    f=${flags[i]}; v=${vals[i]}
    case "$f" in
      -X|--request) explicit=$(printf '%s' "$v" | tr '[:lower:]' '[:upper:]') ;;
      -d|--data|--data-raw|--data-binary|--data-urlencode|--data-ascii|--json|-F|--form|--form-string|--expand-data) has_data=1 ;;
      -G|--get) has_get=1 ;;
      -I|--head) has_head=1 ;;
      -T|--upload-file) has_upload=1 ;;
      -K|--config) C_CONFIG=1 ;;
      -g|--globoff) C_GLOBOFF=1 ;;
      -v|--verbose|--trace|--trace-ascii) C_VERBOSE=1 ;;
      --request-target) C_TARGET=1 ;;
      --url|--expand-url) urls[${#urls[@]}]="$v" ;;
      -H|--header|--expand-header)
        lv=$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')
        case "$lv" in
          authorization:*bearer*)
            v=${v#*[Bb][Ee][Aa][Rr][Ee][Rr]}; v=${v// /}
            is_literal "$v" && C_SECRET_LIT="an 'Authorization: Bearer' header with the token written out" ;;
          x-auth-key:*)
            v=${v#*:}; v=${v// /}
            is_literal "$v" && C_SECRET_LIT="an 'X-Auth-Key' header with the key written out" ;;
        esac ;;
      --oauth2-bearer) is_literal "$v" && C_SECRET_LIT="--oauth2-bearer with the token written out" ;;
      -u|--user)       [[ "$v" == *:* ]] && is_literal "${v#*:}" && C_SECRET_LIT="-u user:password written out" ;;
    esac
    i=$((i + 1))
  done

  if [[ -n "$explicit" ]]; then C_METHOD="$explicit"
  elif (( has_head )); then C_METHOD=HEAD
  elif (( has_upload )); then C_METHOD=PUT
  elif (( has_data && ! has_get )); then C_METHOD=POST
  else C_METHOD=GET; fi

  for v in ${urls[@]+"${urls[@]}"}; do
    case "$v" in
      *'$'*|*'`'*) C_DYN_URLS[${#C_DYN_URLS[@]}]="$v"; continue ;;
    esac
    case "$(cf_url_kind "$v")" in
      api)  C_URLS[${#C_URLS[@]}]="$v" ;;
      odd)  C_ODD_URLS[${#C_ODD_URLS[@]}]="$v" ;;
    esac
  done
}

# cf_url_kind <url> — api (its host is api.cloudflare.com, any case), odd (it
# mentions cloudflare but cannot be read plainly: URL globbing, a host that only
# resembles the API's), or other.
cf_url_kind() {
  local u l host
  l=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$l" in *cloudflare*) ;; *) printf other; return ;; esac
  if (( ! C_GLOBOFF )) && [[ "$l" == *[{}\[\]]* ]]; then printf odd; return; fi
  host=${l#*://}; host=${host#*@}; host=${host%%[/?#]*}; host=${host%%:*}; host=${host%.}
  if [[ "$host" == api.cloudflare.com ]]; then printf api; return; fi
  case "$host" in *cloudflare.com) printf odd ;; *) printf other ;; esac
}

# api_path <url> — the part after /client/v4/, without query or fragment, with
# no leading or trailing slash. Fails when the URL is not a v4 API URL.
api_path() {
  local u="$1" l rest off
  l=$(printf '%s' "$u" | tr '[:upper:]' '[:lower:]')
  [[ "$l" == *api.cloudflare.com* ]] || return 1
  rest=${l#*api.cloudflare.com}
  # The same remainder from the original, so ids keep their own case.
  off=$(( ${#u} - ${#rest} )); rest=${u:off}
  [[ "$rest" == :* ]] && rest="/${rest#*/}"          # a port
  [[ "$(printf '%s' "${rest:0:10}" | tr '[:upper:]' '[:lower:]')" == /client/v4 ]] || return 1
  rest=${rest:10}
  rest=${rest%%\?*}; rest=${rest%%\#*}
  rest=${rest#/}; rest=${rest%/}
  printf '%s' "$rest"
}

# A path curl would rewrite before sending: dot segments (also percent-encoded)
# and empty segments. /zones/<ours>/../<theirs>/ reaches <theirs>.
path_is_unnormalised() {
  local l
  l=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "/$l/" in
    */./*|*/../*|*%2e*|*%2f*|*%5c*|*//*|*\\*) return 0 ;;
  esac
  return 1
}

# A path segment that is an opaque id (32 hex, or a UUID), not a name.
is_api_id() { [[ "$1" =~ ^[0-9a-fA-F]{32}$ ]] || is_uuid "$1"; }

# Variables assigned earlier on the same command line (API=https://...; curl
# "$API/..."; export TUNNEL_ORIGIN_CERT=...), so later commands can be checked
# against them. Parallel arrays: bash 3.2 has no associative arrays. A value
# the shell computes is stored as `$?` (unknown); LINE_VAR_EXPORTED marks the
# ones a child process inherits.
LINE_VAR_NAMES=(); LINE_VAR_VALUES=(); LINE_VAR_EXPORTED=()
line_var_set() {  # line_var_set <name> <value> <exported 0|1>
  local i=0
  while (( i < ${#LINE_VAR_NAMES[@]} )); do
    if [[ "${LINE_VAR_NAMES[i]}" == "$1" ]]; then
      LINE_VAR_VALUES[i]="$2"
      (( ${3:-0} )) && LINE_VAR_EXPORTED[i]=1
      return 0
    fi
    i=$((i + 1))
  done
  LINE_VAR_NAMES[${#LINE_VAR_NAMES[@]}]="$1"; LINE_VAR_VALUES[${#LINE_VAR_VALUES[@]}]="$2"
  LINE_VAR_EXPORTED[${#LINE_VAR_EXPORTED[@]}]=${3:-0}
}

# line_var_get <name> [exported-only] — sets LV and succeeds when known.
line_var_get() {
  local i=0
  LV=""
  while (( i < ${#LINE_VAR_NAMES[@]} )); do
    if [[ "${LINE_VAR_NAMES[i]}" == "$1" ]]; then
      [[ -n "${2:-}" && "${LINE_VAR_EXPORTED[i]}" != 1 ]] && return 1
      LV="${LINE_VAR_VALUES[i]}"; return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# expand_line_vars <text> — replaces $NAME and ${NAME} for every variable known
# from the line. What remains with a `$` could not be resolved.
expand_line_vars() {
  local s="$1" i=0 n v
  while (( i < ${#LINE_VAR_NAMES[@]} )); do
    n=${LINE_VAR_NAMES[i]}; v=${LINE_VAR_VALUES[i]}
    s=${s//\$\{$n\}/$v}
    # $NAME only when not followed by another name character.
    while [[ "$s" =~ ^(.*)\$$n([^A-Za-z0-9_].*)?$ ]]; do s="${BASH_REMATCH[1]}$v${BASH_REMATCH[2]}"; done
    i=$((i + 1))
  done
  printf '%s' "$s"
}
