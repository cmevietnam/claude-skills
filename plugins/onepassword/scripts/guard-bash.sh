#!/usr/bin/env bash
# PreToolUse(Bash) guard.
#
# Two jobs, both about keeping secret VALUES out of the conversation transcript:
#   1. direct `op read` / `op item get` / `op run` … -> deny, and point at opgate
#   2. cat/grep/head of a plaintext secret file      -> ask
#
# This is an accident-preventer, not a sandbox: an agent that wants to evade it can.
# Its value is stopping the ordinary, likely mistake before the value is echoed.
#
# No dependencies beyond bash — a guard that breaks when jq is missing is worse
# than no guard, and every Bash call pays for this script's startup.

payload=$(cat)

# Fast path: nothing of interest, get out before doing any real work.
case "$payload" in
  *'op '*|*'op:'*|*.env*|*.pem*|*id_rsa*|*id_ed25519*|*.netrc*|*.pgpass*|*.npmrc*) ;;
  *) exit 0 ;;
esac

# Extract .tool_input.command. jq when available; otherwise a small scanner that
# walks the JSON string honouring backslash escapes, so an embedded `\"` (as in
# `bash -c "op read ..."`) does not truncate the command we inspect.
if command -v jq >/dev/null 2>&1; then
  command_line=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null) || command_line=""
else
  command_line=$(printf '%s' "$payload" | awk '
    { line = line $0 "\n" }
    END {
      k = index(line, "\"command\":")
      if (k == 0) exit
      rest = substr(line, k + 10)
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
    }')
fi
[[ -n "$command_line" ]] || exit 0

decide() {
  # $1 = allow|deny|ask, $2 = reason (must not contain " or newlines)
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$1" "$2"
  exit 0
}

# --- 1. direct `op` calls that can surface a secret value -------------------
# Word boundary that is not part of a longer word, so `opgate` and `develop` miss.
op_verb='(^|[[:space:]]|;|&|\||\(|`|\$\(|"|'"'"')op[[:space:]]+'

if printf '%s' "$command_line" | grep -Eq "${op_verb}(read|inject)([[:space:]]|$)" \
|| printf '%s' "$command_line" | grep -Eq "${op_verb}(item|document)[[:space:]]+get([[:space:]]|$)" \
|| printf '%s' "$command_line" | grep -Eq "${op_verb}run([[:space:]]|$)"; then
  decide deny "Goi op truc tiep bi chan. Dung opgate: 'opgate run -- <cmd>' de nap secret vao env (co Touch ID gate + audit log), 'opgate copy <ref>' de chep vao clipboard, 'opgate list' de xem co secret gi. Khong bao gio in gia tri secret ra stdout - no se vao transcript va duoc gui len model provider."
fi

# `op` subcommands that only list metadata are fine; fall through to normal flow.

# --- 2. shell-reading a plaintext secret file -------------------------------
readers='(cat|bat|head|tail|less|more|strings|xxd|od|nl|grep|rg|ag|awk|sed|printenv)'

if printf '%s' "$command_line" | grep -Eq "(^|[[:space:]]|;|&|\||\(|\`|\")${readers}[[:space:]]"; then
  # Any token that names a secret-ish file and is not one of the safe template
  # forms (.env.example, .env.op, *.pub, …). Tokenising keeps `.env.example` from
  # being read as a hit on `.env`.
  if printf '%s' "$command_line" \
     | tr " \t\"'\`;|&()<>" '\n\n\n\n\n\n\n\n\n\n\n\n\n' \
     | grep -E '(^|/)(\.env(\.[A-Za-z0-9_-]+)?|\.netrc|\.pgpass|\.npmrc|id_rsa[^/]*|id_ed25519[^/]*|id_ecdsa[^/]*)$|\.(pem|p12|pfx|jks|key)$' \
     | grep -Evq '\.(example|sample|tpl|template|op|pub|md|lock)$'; then
    decide ask "Lenh nay doc mot file co the chua secret plaintext. Doc no se dua gia tri vao context cua model va gui len provider. Neu chi can biet co bien gi, dung: opgate list. Neu can chay app voi secret, dung: opgate run -- <cmd>."
  fi
fi

exit 0
