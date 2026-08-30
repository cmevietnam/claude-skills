#!/usr/bin/env bash
# PreToolUse(Grep) guard.
#
# The Grep tool returns matching lines, so `Grep pattern=. path=.env` is `cat
# .env` by another name. This asks when the tool is pointed AT a secret file.
#
# Limit, stated plainly: a Grep over a whole directory also reads any .env in it,
# and asking on every directory-wide Grep would be unbearable. That case is not
# covered; it is listed in security-model.md.

payload=$(cat)
case "$payload" in
  *.env*|*.pem*|*.key*|*id_rsa*|*id_ed25519*|*.netrc*|*.npmrc*|*credential*) ;;
  *) exit 0 ;;
esac

if command -v jq >/dev/null 2>&1; then
  target=$(printf '%s' "$payload" | jq -r '(.tool_input.path // "") + " " + (.tool_input.glob // "")' 2>/dev/null) || target=""
else
  target=$(printf '%s' "$payload" | tr -d '\n' \
    | sed -n 's/.*"path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
fi
[[ -n "$target" ]] || exit 0

hit=0
for tok in $target; do
  b="${tok##*/}"
  case "$b" in
    *.example|*.sample|*.tpl|*.template|*.op|*.pub|*.md) continue ;;
    .env|.env.*|.env*|.envrc|.netrc|.npmrc|.git-credentials|credentials|credentials.json) hit=1 ;;
    *.pem|*.p12|*.pfx|*.jks|*.key|id_rsa*|id_ed25519*|id_ecdsa*) hit=1 ;;
  esac
done
(( hit )) || exit 0

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' \
  "Grep tren mot file secret tra ve noi dung dong khop - tuc la gia tri - vao context cua model. Neu chi can biet co bien gi, dung: opgate list."
