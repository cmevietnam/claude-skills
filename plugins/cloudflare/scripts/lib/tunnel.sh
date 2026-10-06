#!/usr/bin/env bash
# Reading a cloudflared command line, and the origin certificate it will use.
# Sourced by scripts/guard-cloudflare.sh and bin/cfgate.
#
# Classified from `cloudflared <path> --help` on cloudflared 2024.11.1.

# path|kind|target — same kinds as WR_TABLE in wrangler.sh, plus `expose` for a
# quick tunnel, which publishes a local port on a random trycloudflare.com name.
CFD_TABLE='version|read|-
help|read|-
update|cli|-
tail|read|-
proxy-dns|local|-
service install|cli|-
service uninstall|cli|-
tunnel login|cli|-
tunnel create|write|tunnel
tunnel delete|write|tunnels
tunnel cleanup|write|tunnels
tunnel run|write|run
tunnel list|read|-
tunnel info|read|-
tunnel ready|read|-
tunnel token|secret|-
tunnel route dns|write|dns
tunnel route lb|write|lb
tunnel route ip add|ask|account
tunnel route ip delete|ask|account
tunnel route ip show|read|-
tunnel route ip list|read|-
tunnel route ip get|read|-
tunnel vnet add|ask|account
tunnel vnet delete|ask|account
tunnel vnet update|ask|account
tunnel vnet list|read|-
access login|cli|-
access token|secret|-
access curl|read|-
access tcp|local|-
access rdp|local|-
access ssh|local|-
access smb|local|-
access ssh-config|local|-
access ssh-gen|local|-
forward login|cli|-
forward token|secret|-'

# Options that take a value (from the same --help sweep, plus the ones it
# printed without the `value` marker).
CFD_VALFLAGS=" --app --autoupdate-freq --compression-quality --config --connector-id \
--credentials-contents --credentials-file --cred-file --edge-bind-address \
--edge-ip-version --features --grace-period --hostname --icmpv4-src --icmpv6-src \
--label --lb-pool --log-directory --logfile --loglevel --metrics --metrics-update-freq \
--name --origincert --pidfile --proxy-address --proxy-connection-timeout \
--proxy-dns-address --proxy-dns-bootstrap --proxy-dns-max-upstream-conns \
--proxy-dns-port --proxy-dns-upstream --proxy-expect-continue-timeout --proxy-port \
--region --retries --secret --sort-by --token --token-file --trace-output \
--transport-loglevel --unix-socket --vnet --url --id --output --origin-ca-pool \
--origin-server-name --http-host-header --proxy-connect-timeout \
--proxy-keepalive-connections --proxy-keepalive-timeout --proxy-tls-timeout \
--proxy-tcp-keepalive --when --name-prefix --exclude-name-prefix --protocol --edge \
--tag --ha-connections --service-op-ip --max-fetch-size --comment --vnet-id -c -n \
-vn --log-format "

CFD_SECRETFLAGS=" --token --credentials-contents --secret "

cfd_lookup() {
  local line
  while IFS= read -r line; do
    [[ "${line%%|*}" == "$1" ]] && { printf '%s' "${line#*|}"; return 0; }
  done <<< "$CFD_TABLE"
  return 1
}

# parse_cloudflared — reads SH_WORDS from SH_START + 1. Sets:
#   T_CMD T_KIND T_TARGET  command path and table entry ("" when unknown)
#   T_ARGS[]               positionals after the path
#   T_ORIGINCERT T_CONFIG T_URL T_HELP T_OVERWRITE
#   T_SECRET_LIT           first credential option with a literal value
#   T_FIRSTPOS T_NPOS      first positional and how many there were
parse_cloudflared() {
  T_CMD=""; T_KIND=""; T_TARGET=""; T_ARGS=(); T_ORIGINCERT=""; T_CONFIG=""; T_URL=""
  T_HELP=0; T_OVERWRITE=0; T_SECRET_LIT=""; T_FIRSTPOS=""; T_NPOS=0
  local n=${#SH_WORDS[@]} j=$((SH_START + 1)) t f val a
  local -a pos=()
  for a in ${SH_ASSIGNS[@]+"${SH_ASSIGNS[@]}"}; do
    case "$a" in TUNNEL_ORIGIN_CERT=*) T_ORIGINCERT=${a#TUNNEL_ORIGIN_CERT=} ;; esac
  done
  while (( j < n )); do
    t=${SH_WORDS[j]}
    if [[ "$t" == -- ]]; then
      j=$((j + 1))
      while (( j < n )); do pos[${#pos[@]}]="${SH_WORDS[j]}"; j=$((j + 1)); done
      break
    fi
    if [[ "$t" == -?* ]]; then
      f=${t%%=*}; val=""
      # urfave/cli accepts -flag as well as --flag.
      [[ "$f" == -[!-]?* && "$f" != -vn ]] && f="-$f"
      if [[ "$t" == *=* ]]; then
        val=${t#*=}
      elif [[ "$CFD_VALFLAGS" == *" $f "* ]]; then
        val="${SH_WORDS[j+1]:-}"; j=$((j + 1))
      fi
      case "$f" in
        -h|--help|-v|--version) T_HELP=1 ;;
        --origincert)           T_ORIGINCERT="$val" ;;
        --config)               T_CONFIG="$val" ;;
        --url|--hello-world)    T_URL="${val:-hello-world}" ;;
        -f|--overwrite-dns)     T_OVERWRITE=1 ;;
      esac
      if [[ "$CFD_SECRETFLAGS" == *" $f "* ]] && is_literal "$val" && [[ -z "$T_SECRET_LIT" ]]; then
        T_SECRET_LIT="$f"
      fi
      j=$((j + 1)); continue
    fi
    pos[${#pos[@]}]="$t"
    j=$((j + 1))
  done
  T_NPOS=${#pos[@]}
  T_FIRSTPOS="${pos[0]:-}"
  local k=${#pos[@]} p i entry
  (( k > 4 )) && k=4
  while (( k > 0 )); do
    p="${pos[0]}"; i=1
    while (( i < k )); do p="$p ${pos[i]}"; i=$((i + 1)); done
    if entry=$(cfd_lookup "$p"); then
      T_CMD="$p"; T_KIND=${entry%%|*}; T_TARGET=${entry#*|}
      i=$k
      while (( i < ${#pos[@]} )); do T_ARGS[${#T_ARGS[@]}]="${pos[i]}"; i=$((i + 1)); done
      return 0
    fi
    k=$((k - 1))
  done
  return 0
}

# A tunnel reference that is a UUID rather than a name.
is_uuid() { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; }

# --- the origin certificate ---------------------------------------------------
# `cloudflared tunnel login` writes cert.pem: a PEM block "ARGO TUNNEL TOKEN"
# whose base64 body is JSON with zoneID, accountID, apiToken and serviceKey. The
# zone is the one picked in the browser at login, and the tunnel commands that
# write DNS act inside that zone. Only accountID and zoneID are ever read here;
# the rest of the document never leaves this function.

# cfd_cert_path <cwd> — which cert.pem cloudflared will use, by its own order:
# --origincert, TUNNEL_ORIGIN_CERT, `origincert:` in the config file, then the
# default search path. Sets CFD_CERT (path) and CFD_CERT_SRC (where it came from).
cfd_cert_path() {
  local cwd="$1" home="${HOME:-}" cfg="" d v
  CFD_CERT=""; CFD_CERT_SRC=""
  _abs() { case "$1" in /*) printf '%s' "$1" ;; '~'|'~/'*) printf '%s%s' "$home" "${1#\~}" ;; *) printf '%s/%s' "$cwd" "$1" ;; esac; }
  if [[ -n "$T_ORIGINCERT" ]]; then
    is_literal "$T_ORIGINCERT" || { CFD_CERT_SRC="unreadable --origincert $T_ORIGINCERT"; return 1; }
    CFD_CERT=$(_abs "$T_ORIGINCERT"); CFD_CERT_SRC="--origincert"; return 0
  fi
  # `export TUNNEL_ORIGIN_CERT=...` earlier on the same command line.
  if line_var_get TUNNEL_ORIGIN_CERT exported; then
    is_literal "$LV" || { CFD_CERT_SRC="TUNNEL_ORIGIN_CERT exported from a value the shell computes"; return 1; }
    CFD_CERT=$(_abs "$LV"); CFD_CERT_SRC="TUNNEL_ORIGIN_CERT exported on this line"; return 0
  fi
  if [[ -n "${TUNNEL_ORIGIN_CERT:-}" ]]; then
    CFD_CERT=$(_abs "$TUNNEL_ORIGIN_CERT"); CFD_CERT_SRC="TUNNEL_ORIGIN_CERT"; return 0
  fi
  if [[ -n "$T_CONFIG" ]]; then
    is_literal "$T_CONFIG" || { CFD_CERT_SRC="unreadable --config $T_CONFIG"; return 1; }
    cfg=$(_abs "$T_CONFIG")
  else
    for d in "$home/.cloudflared" "$home/.cloudflare-warp" "$home/cloudflare-warp" /etc/cloudflared /usr/local/etc/cloudflared; do
      [[ -f "$d/config.yml" ]] && { cfg="$d/config.yml"; break; }
      [[ -f "$d/config.yaml" ]] && { cfg="$d/config.yaml"; break; }
    done
  fi
  if [[ -n "$cfg" && -r "$cfg" ]]; then
    v=$(sed -n 's/^[[:space:]]*origincert:[[:space:]]*//p' "$cfg" | head -1 | tr -d '"'"'"' ')
    if [[ -n "$v" ]]; then CFD_CERT=$(_abs "$v"); CFD_CERT_SRC="origincert in $cfg"; return 0; fi
  fi
  for d in "$home/.cloudflared" "$home/.cloudflare-warp" "$home/cloudflare-warp" /etc/cloudflared /usr/local/etc/cloudflared; do
    [[ -f "$d/cert.pem" ]] && { CFD_CERT="$d/cert.pem"; CFD_CERT_SRC="default search path"; return 0; }
  done
  CFD_CERT_SRC="no cert.pem found"
  return 1
}

# cfd_config_tunnel <cwd> — the `tunnel:` a config file names, for `tunnel run`
# without a name: --config, else the first default config.yml. Sets CFD_RUN_TUNNEL
# (empty when none) and fails when --config cannot be read.
cfd_config_tunnel() {
  local cwd="$1" home="${HOME:-}" cfg="" d
  CFD_RUN_TUNNEL=""
  if [[ -n "$T_CONFIG" ]]; then
    is_literal "$T_CONFIG" || return 1
    case "$T_CONFIG" in /*) cfg="$T_CONFIG" ;; '~'|'~/'*) cfg="$home${T_CONFIG#\~}" ;; *) cfg="$cwd/$T_CONFIG" ;; esac
    [[ -r "$cfg" ]] || return 1
  else
    for d in "$home/.cloudflared" "$home/.cloudflare-warp" "$home/cloudflare-warp" /etc/cloudflared /usr/local/etc/cloudflared; do
      [[ -f "$d/config.yml" ]] && { cfg="$d/config.yml"; break; }
      [[ -f "$d/config.yaml" ]] && { cfg="$d/config.yaml"; break; }
    done
    [[ -n "$cfg" ]] || return 0
  fi
  CFD_RUN_TUNNEL=$(sed -n 's/^tunnel:[[:space:]]*//p' "$cfg" | head -1 | tr -d '"'"'"' \r')
  return 0
}

# cfd_cert_ids <file> — sets CERT_ACCOUNT and CERT_ZONE. Fails when the file is
# missing or not an ARGO TUNNEL TOKEN; never prints anything from the file.
cfd_cert_ids() {
  local body doc
  CERT_ACCOUNT=""; CERT_ZONE=""
  [[ -r "$1" ]] || return 1
  body=$(awk '/-----BEGIN ARGO TUNNEL TOKEN-----/{f=1; next} /-----END/{f=0} f' "$1" | tr -d ' \r\n')
  [[ -n "$body" ]] || return 1
  doc=$(printf '%s' "$body" | base64 -d 2>/dev/null) || doc=$(printf '%s' "$body" | base64 -D 2>/dev/null) || return 1
  CERT_ACCOUNT=$(printf '%s' "$doc" | grep -o '"accountID"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]*"' | head -1 | grep -o '[0-9a-fA-F]\{32\}')
  CERT_ZONE=$(printf '%s' "$doc" | grep -o '"zoneID"[[:space:]]*:[[:space:]]*"[0-9a-fA-F]*"' | head -1 | grep -o '[0-9a-fA-F]\{32\}')
  doc=""
  [[ -n "$CERT_ACCOUNT" && -n "$CERT_ZONE" ]]
}
