#!/usr/bin/env bash
# The approval layer. Every opgate subcommand that can move a secret value calls
# gate_require() first.
#
# Scope, stated plainly: this binds honest callers of `opgate`. It is not a
# sandbox. Anything that can run arbitrary commands as you can call `op` directly
# once 1Password has authorized the terminal session, and no amount of hardening
# here changes that. See references/security-model.md.

# Append one audit record. Fields are tab-separated so the log stays greppable.
# Never receives a secret value — only variable names and references.
audit() {
  local status="$1" action="$2" detail="$3"
  mkdir -p -- "$OPGATE_STATE_HOME"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    "$status" \
    "$(sanitize_field "$(detect_caller)")" \
    "$(sanitize_field "$(project_name)")" \
    "$(sanitize_field "$action")" \
    "$(sanitize_field "$detail")" >> "$OPGATE_AUDIT_LOG"
  chmod 600 "$OPGATE_AUDIT_LOG" 2>/dev/null || true
}

# The gate binary lives in a directory you own, so anything running as you can
# replace it. Recording its hash at build time does not prevent that — it makes it
# visible, and forces a tamper to be deliberate rather than a one-line env tweak.
# Treat this as tamper-evidence, not tamper-proofing.
_verify_gate_binary() {
  [[ -x "$OPGATE_GATE_BIN" ]] || return 1
  [[ -f "$OPGATE_GATE_SUM" ]] || {
    warn "chưa có hash tham chiếu cho gate binary — chạy \`opgate build\` để ghi lại"
    return 0
  }
  local want got
  want=$(cut -d' ' -f1 <"$OPGATE_GATE_SUM")
  got=$(/usr/bin/shasum -a 256 <"$OPGATE_GATE_BIN" | cut -d' ' -f1)
  if [[ "$want" != "$got" ]]; then
    audit "TAMPER" "gate" "touchid-gate hash mismatch"
    printf '%sopgate: gate binary đã bị thay đổi kể từ lần build.%s\n' "$_c_red" "$_c_reset" >&2
    printf '       mong đợi %s\n       thực tế %s\n' "$want" "$got" >&2
    printf '       Nếu bạn không cố ý build lại, đây là dấu hiệu bị can thiệp.\n' >&2
    printf '       Xác nhận rồi chạy: opgate build\n' >&2
    return 2
  fi
  return 0
}

# gate_require <action> <detail> <human-readable request>
#
#   action  short verb for the audit log      e.g. run, exec, inject, copy, put
#   detail  what is being reached for         e.g. "DATABASE_URL, JWT_SECRET"
#   reason  the sentence shown on the Touch ID sheet — this is what you read
#           before deciding, so it must name the project, the secrets and the
#           command.
#
# Exits 77 if you decline, 78 if the prompt could not run. Returns 0 only after an
# explicit approval — there is no cache and no reuse window.
gate_require() {
  local action="$1" detail="$2" reason="$3"

  if [[ ! -x "$OPGATE_GATE_BIN" ]]; then
    info "gate binary chưa có, đang build…"
    bash "$OPGATE_SCRIPT_DIR/build-gate.sh" >&2 || {
      audit "UNAVAILABLE" "$action" "$detail"
      die "không build được gate binary"
    }
  fi

  local vrc=0; _verify_gate_binary || vrc=$?
  if (( vrc == 2 )); then
    audit "UNAVAILABLE" "$action" "$detail"
    exit 78
  fi

  audit "REQUESTED" "$action" "$detail"

  local -a gate_args=()
  # Only an explicit affirmative opts into device-password fallback; an empty or
  # "0" value must not silently widen what counts as authentication.
  case "${OPGATE_ALLOW_PASSWORD:-}" in
    1|true|yes) gate_args+=(--allow-password) ;;
  esac

  local rc=0
  # `"${a[@]}"` on an empty array is an unbound-variable error under `set -u` in
  # bash 3.2, which is what macOS ships.
  "$OPGATE_GATE_BIN" ${gate_args[@]+"${gate_args[@]}"} --reason "$reason" || rc=$?

  case "$rc" in
    0)
      audit "APPROVED" "$action" "$detail"
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
