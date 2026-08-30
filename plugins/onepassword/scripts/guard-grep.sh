#!/usr/bin/env bash
# PreToolUse(Grep) guard.
#
# The Grep tool returns matching lines, so `Grep pattern=. path=.env` is `cat
# .env` by another name. This asks when the tool is pointed AT a secret file.
#
# Limit, stated plainly: a Grep over a whole directory also reads any .env in it,
# and asking on every directory-wide Grep would be unbearable. That case is not
# covered; it is listed in security-model.md.
#
# An approval opens a window for the matched file (lib/grants.sh), the same one
# guard-read opens, so approving a Read and then grepping the same file does not
# ask twice.

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
hits=()
for tok in $target; do
  b="${tok##*/}"
  case "$b" in
    *.example|*.sample|*.tpl|*.template|*.op|*.pub|*.md) continue ;;
    .env|.env.*|.env*|.envrc|.netrc|.npmrc|.git-credentials|credentials|credentials.json) hit=1; hits+=("$tok") ;;
    *.pem|*.p12|*.pfx|*.jks|*.key|id_rsa*|id_ed25519*|id_ecdsa*) hit=1; hits+=("$tok") ;;
  esac
done
(( hit )) || exit 0

guard_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/grants.sh
source "$guard_dir/lib/grants.sh"

if command -v jq >/dev/null 2>&1; then
  cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null) || cwd=""
else
  cwd=$(printf '%s' "$payload" | tr -d '\n' | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
fi
call_id=$(grant_call_id "$payload")

# Every matched target must be covered. A Grep that touches one file you approved
# and one you did not is a Grep you have not approved.
canons=() all_open=1
for tok in ${hits[@]+"${hits[@]}"}; do
  c=$(grant_canonical_path "$tok" "${cwd:-$PWD}") || { all_open=0; continue; }
  canons+=("$c")
  grant_active "$c" >/dev/null || all_open=0
done
(( ${#canons[@]} )) || all_open=0

if (( all_open )); then
  grant_audit "GRANT-USED" "grep" "${canons[0]##*/}"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"%s"}}\n' \
    "opgate: an approval window is open for the file(s) this Grep targets. Run 'opgate grants' to see it, 'opgate lock' to close it now."
  exit 0
fi

[[ -n "$call_id" ]] && (( ${#canons[@]} )) && pending_write "$call_id" "${canons[@]}"

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' \
  "Grepping a secret file returns the matching lines - the values themselves - into the model context. To see which variables exist, use: opgate list. Approving opens a 60-minute window for THIS file only; 'opgate lock' closes it."
