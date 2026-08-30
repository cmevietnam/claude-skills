#!/usr/bin/env bash
# PostToolUse(Read|Grep|Bash) — turn "you said yes" into a time-bounded window.
#
# This script deliberately knows NOTHING about what a secret file looks like. The
# PreToolUse guard already decided that and wrote the keys it would grant into
# pending/<tool_use_id>; all this does is promote that record. One classifier, in
# one place — a second copy of the matching rules here would drift from the guards
# within two commits, and a guard and a granter that disagree is how a window ends
# up open on a file nobody approved.
#
# Why a PostToolUse firing is evidence of an approval: Claude Code does not run
# PostToolUse for a call that was denied or cancelled. The tool ran, so either you
# approved it at the prompt, or no prompt was shown at all — which is what the
# permission_mode check below is for.

payload=$(cat)

# Pure-bash dirname, and grants.sh is sourced before anything forks: this hook is
# charged to every Read, Grep and Bash call in the session, so the path where
# there is nothing to do has to cost almost nothing. Measured at ~25 ms/call
# before this ordering, ~5 ms after.
source "${BASH_SOURCE[0]%/*}/lib/grants.sh"
pending_any || exit 0

_json_str() { # <key>
  printf '%s' "$payload" | awk -v key="$1" '
    { line = line $0 "\n" }
    END {
      pos = match(line, "\"" key "\"[ \t\r\n]*:")
      if (pos == 0) exit
      rest = substr(line, pos + RLENGTH)
      q = index(rest, "\"")
      if (q == 0) exit
      rest = substr(rest, q + 1)
      out = ""
      for (i = 1; i <= length(rest); i++) {
        c = substr(rest, i, 1)
        if (c == "\\") { out = out substr(rest, i + 1, 1); i++ }
        else if (c == "\"") break
        else out = out c
      }
      print out
    }'
}

# Must be computed exactly as the PreToolUse guard computed it, which is why it
# lives in grants.sh rather than being spelled out twice.
call_id=$(grant_call_id "$payload")
[[ -n "$call_id" ]] || exit 0

pending=$(_pending_file "$call_id")
[[ -f "$pending" ]] || exit 0

if command -v jq >/dev/null 2>&1; then
  mode=$(printf '%s' "$payload" | jq -r '.permission_mode // ""' 2>/dev/null) || mode=""
  session=$(printf '%s' "$payload" | jq -r '.session_id // ""' 2>/dev/null) || session=""
else
  mode=$(_json_str permission_mode); session=$(_json_str session_id)
fi

# Fail closed. Under bypassPermissions, dontAsk or auto no prompt is shown, so the
# tool running proves nothing about what you wanted; an unrecognised future mode
# has to land here too rather than be assumed benign.
case "$OPGATE_GRANT_MODES" in
  *" $mode "*) ;;
  *)
    rm -f -- "$pending" 2>/dev/null || true
    exit 0
    ;;
esac

pending_promote "$call_id" "$OPGATE_GRANT_DEFAULT_MINUTES" "auto" "${session:-unknown}" \
  >/dev/null 2>&1 || true
exit 0
