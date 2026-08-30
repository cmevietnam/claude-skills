#!/usr/bin/env bash
# PreToolUse(Read) guard.
#
# The Read tool puts a file's contents straight into the conversation, so reading a
# plaintext .env is the single easiest way to leak every secret a project has. This
# asks first. It answers "ask", never "deny", because editing a .env by hand is a
# legitimate thing to want — the point is that you decide, not the agent.

payload=$(cat)

case "$payload" in
  *.env*|*.pem*|*.p12*|*.pfx*|*.jks*|*.key*|*id_rsa*|*id_ed25519*|*id_ecdsa*|*.netrc*|*.pgpass*|*.npmrc*|*credentials*) ;;
  *) exit 0 ;;
esac

if command -v jq >/dev/null 2>&1; then
  file_path=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // ""' 2>/dev/null) || file_path=""
else
  file_path=$(printf '%s' "$payload" \
    | sed -n 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
fi
[[ -n "$file_path" ]] && base=$(basename -- "$file_path") || exit 0

# Template and public forms are safe by construction and must not nag.
case "$base" in
  *.example|*.sample|*.tpl|*.template|*.op|*.pub|*.md|*.lock) exit 0 ;;
esac

secret=0
case "$base" in
  .env|.env.*|.netrc|.pgpass|.npmrc) secret=1 ;;
  *.pem|*.p12|*.pfx|*.jks|*.key)     secret=1 ;;
  id_rsa*|id_ed25519*|id_ecdsa*)     secret=1 ;;
  credentials|credentials.json)      secret=1 ;;
esac
(( secret )) || exit 0

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' \
  "Doc $base se dua toan bo noi dung - ke ca gia tri secret - vao context cua model va gui len provider. Neu chi can biet project co bien gi, dung: opgate list. Neu can chay lenh voi secret, dung: opgate run -- <cmd>."
