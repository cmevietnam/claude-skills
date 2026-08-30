#!/usr/bin/env bash
# The approval layer. Every opgate subcommand that can move a secret value calls
# gate_require() first; nothing else in this repo is allowed to touch `op`.

# Append one audit record. Fields are tab-separated so the log stays greppable.
# Never receives a secret value — only variable names and references.
audit() {
  local status="$1" action="$2" detail="$3"
  mkdir -p -- "$OPGATE_STATE_HOME"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "$status" \
    "$(detect_caller)" \
    "$(project_name)" \
    "$action" \
    "$detail" >> "$OPGATE_AUDIT_LOG"
  chmod 600 "$OPGATE_AUDIT_LOG" 2>/dev/null || true
}

_ttl_marker() {
  # One marker per (project, action) pair. Only consulted when OPGATE_TTL > 0.
  local action="$1" key
  key=$(printf '%s\t%s' "$PWD" "$action" | /usr/bin/shasum -a 256 | cut -d' ' -f1)
  printf '%s/ttl-%s' "$OPGATE_STATE_HOME" "$key"
}

_ttl_valid() {
  local marker="$1" now age mtime
  (( OPGATE_TTL > 0 )) || return 1
  [[ -f "$marker" ]] || return 1
  mtime=$(stat -f %m "$marker" 2>/dev/null) || return 1
  now=$(date +%s)
  age=$(( now - mtime ))
  (( age < OPGATE_TTL ))
}

# Run the configured authenticator. Returns 0 on approval.
_authenticate() {
  local reason="$1"
  case "$OPGATE_GATE" in
    touchid)
      [[ -x "$OPGATE_GATE_BIN" ]] || {
        info "gate binary missing, building it once…"
        bash "$OPGATE_SCRIPT_DIR/build-gate.sh" || return 2
      }
      "$OPGATE_GATE_BIN" ${OPGATE_ALLOW_PASSWORD:+--allow-password} --reason "$reason"
      ;;
    sudo)
      # Fallback for hosts where LocalAuthentication cannot present a sheet (SSH,
      # no GUI session). Requires pam_tid in /etc/pam.d/sudo_local.
      printf '%s\n' "$reason" >&2
      sudo -k
      sudo -v
      ;;
    none)
      warn "OPGATE_GATE=none — approval is DISABLED, this secret access is unguarded"
      return 0
      ;;
    *)
      die "unknown OPGATE_GATE=$OPGATE_GATE (expected: touchid, sudo, none)"
      ;;
  esac
}

# gate_require <action> <detail> <human-readable request>
#
#   action  short verb for the audit log      e.g. run, exec, inject, copy, put
#   detail  what is being reached for         e.g. "DATABASE_URL, JWT_SECRET"
#   reason  the sentence shown on the Touch ID sheet — this is what you read
#           before deciding, so it must name the project, the secrets and the
#           command.
#
# Exits 77 if the human declines. Returns 0 only on an explicit approval.
gate_require() {
  local action="$1" detail="$2" reason="$3"
  local marker; marker=$(_ttl_marker "$action")

  if _ttl_valid "$marker"; then
    audit "REUSED" "$action" "$detail"
    return 0
  fi

  audit "REQUESTED" "$action" "$detail"

  local rc=0
  _authenticate "$reason" || rc=$?

  case "$rc" in
    0)
      audit "APPROVED" "$action" "$detail"
      (( OPGATE_TTL > 0 )) && { mkdir -p -- "$OPGATE_STATE_HOME"; : > "$marker"; }
      return 0
      ;;
    1)
      audit "DENIED" "$action" "$detail"
      printf '%sopgate: từ chối — không có approval, lệnh không chạy.%s\n' "$_c_red" "$_c_reset" >&2
      exit 77
      ;;
    *)
      audit "UNAVAILABLE" "$action" "$detail"
      printf '%sopgate: không hiện được prompt xác thực (exit %s).%s\n' "$_c_red" "$rc" "$_c_reset" >&2
      printf '       Chạy `opgate doctor` để chẩn đoán.\n' >&2
      exit 78
      ;;
  esac
}
