#!/usr/bin/env bash
# PreToolUse(Bash) guard.
#
# Two jobs, both about keeping secret VALUES out of the conversation transcript:
#   1. direct `op read` / `op item get` / `op run` … -> deny, and point at opgate
#   2. cat/grep/head of a plaintext secret file      -> ask
#
# This is an accident-preventer, not a sandbox: a caller that wants to evade it
# can. Its value is stopping the ordinary, likely mistake before the value is
# echoed. See references/security-model.md.
#
# Detection is done by scanning TOKENS rather than matching the whole command
# string. An earlier regex-based version missed `/opt/homebrew/bin/op read`,
# `op --account work read`, `/bin/cat .env`, `bash -c 'cat .env'` and
# `.env.production.local` — all realistic, all invisible to a pattern anchored on
# "starts with `op `".
#
# No dependencies beyond bash and awk — a guard that breaks when jq is missing is
# worse than no guard, and every Bash call pays for this script's startup.

payload=$(cat)

# Fast path: nothing of interest, get out before doing any real work.
case "$payload" in
  *op*|*.env*|*.pem*|*id_rsa*|*id_ed25519*|*id_ecdsa*|*.netrc*|*.pgpass*|*.npmrc*|*credential*|*.key*) ;;
  *) exit 0 ;;
esac

# Extract .tool_input.command. jq when available; otherwise a scanner that walks
# the JSON string honouring backslash escapes, so an embedded `\"` (as in
# `bash -c "op read ..."`) does not truncate the command we inspect.
_json_str() { # <key> — same scanner, any top-level-ish string field
  printf '%s' "$payload" | awk -v key="$1" '
    { line = line $0 "\n" }
    END {
      # Tolerate whitespace before the colon: `"command" : "..."` is valid JSON,
      # and the jq path accepts it, so this path must too.
      pos = match(line, "\"" key "\"[ \t\r\n]*:")
      if (pos == 0) exit
      rest = substr(line, pos + RLENGTH)
      q = index(rest, "\"")
      if (q == 0) exit
      rest = substr(rest, q + 1)
      out = ""
      for (i = 1; i <= length(rest); i++) {
        c = substr(rest, i, 1)
        if (c == "\\") { n = substr(rest, i + 1, 1)
                         if (n == "n" || n == "t" || n == "r") out = out " "
                         else out = out n
                         i++ }
        else if (c == "\"") break
        else out = out c
      }
      print out
    }'
}

if command -v jq >/dev/null 2>&1; then
  command_line=$(printf '%s' "$payload" | jq -r '.tool_input.command // ""' 2>/dev/null) || command_line=""
else
  command_line=$(_json_str command)
fi
[[ -n "$command_line" ]] || exit 0

decide() {
  # $1 = allow|deny|ask, $2 = reason (fixed strings only — never interpolate
  # attacker-influenced text into hand-built JSON).
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$1" "$2"
  exit 0
}

# Split into tokens on whitespace and shell metacharacters. Quotes become
# separators, which is what lets `bash -c 'cat .env'` be seen as the three tokens
# that matter.
tokens=()
while IFS= read -r tok; do
  # Drop backslashes left over from shell quoting: open(\".env\") otherwise
  # yields the token `.env\`, which matches nothing.
  tok="${tok//\\/}"
  [[ -n "$tok" ]] && tokens+=("$tok")
  # The trailing newline matters: without it `read` discards the final token, which
  # is almost always the filename — `cat .env` would then look like just `cat`.
done < <(printf '%s\n' "$command_line" | tr ' \t\n"'"'"'`;|&()<>{}' '\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n')

# Inline ${t##*/} everywhere: a $(...) per token forked twice per token and took
# 8 s on a 6000-token heredoc, past the 10 s hook timeout, so the guard silently
# did not run at all on exactly the commands most likely to hide something.

# --- 1. direct `op` calls that can surface a secret value -------------------
# Find an `op` invocation (bare or by path), then look at what follows it. Listing
# metadata is fine; anything that resolves a secret is not.
saw_op=0 danger=0 noun="" since=0
for t in ${tokens[@]+"${tokens[@]}"}; do
  b="${t##*/}"
  if (( saw_op )); then
    since=$((since + 1))
    # Look at most 6 tokens past `op` — enough for `op --account work --format
    # json read`. Prose that mentions op and read further apart is not an
    # invocation. Adjacent prose ("docs: op read") still trips it; documented.
    (( since > 6 )) && { saw_op=0; noun=""; }
  fi
  if (( saw_op )); then
    case "$b" in
      read|inject|run) danger=1; break ;;
      --reveal|--raw)  danger=1; break ;;   # prints a value/token whatever the subcommand
      item|document|connect|service-account|account) noun="$b" ;;
      get)    [[ "$noun" == item || "$noun" == document ]] && { danger=1; break; } ;;
      share)  [[ "$noun" == item ]] && { danger=1; break; } ;;      # prints a bearer link
      create) [[ "$noun" == service-account ]] && { danger=1; break; } ;;  # prints a token
      token)  [[ "$noun" == connect ]] && { danger=1; break; } ;;   # `connect token create`
    esac
  fi
  [[ "$b" == "op" ]] && { saw_op=1; noun=""; since=0; }
done

if (( danger )); then
  decide deny "Calling op directly is blocked. Use opgate instead: 'opgate run -- <cmd>' loads the secrets into a child process env (Touch ID gate + audit log), 'opgate copy <ref>' puts one on the clipboard, 'opgate list' shows which secrets exist. Never print a secret value to stdout - it lands in the transcript and is shipped to the model provider. No approval window applies here."
fi

# --- 2. shell-reading a plaintext secret file -------------------------------
readers_re='^(cat|bat|head|tail|less|more|strings|xxd|od|nl|dd|base64|cut|paste|tr|sort|uniq|diff|cmp|cp|tee|source|\.|grep|egrep|fgrep|rg|ag|awk|sed|printenv|python|python3|perl|ruby|node|deno|bun|php)$'
# `.env`, `.env.production`, `.env.production.local`, and the `.env*` glob form.
secret_re='^(\.env[A-Za-z0-9_.*-]*|\.envrc|\.netrc|\.pgpass|\.npmrc|\.git-credentials|credentials(\.json)?|id_rsa[^/]*|id_ed25519[^/]*|id_ecdsa[^/]*|[^/]*\.(pem|p12|pfx|jks|key))$'
safe_re='\.(example|sample|tpl|template|op|pub|md|lock|ts|js|json5)$'

saw_reader=0 saw_secret=0
secret_tokens=()
for t in ${tokens[@]+"${tokens[@]}"}; do
  # `dd if=.env`, `--file=.env`: the filename sits after a `key=` prefix.
  [[ "$t" =~ ^[A-Za-z_-]+=(.+)$ ]] && t="${BASH_REMATCH[1]}"
  b="${t##*/}"
  [[ "$b" =~ $readers_re ]] && saw_reader=1
  if [[ "$b" =~ $secret_re ]] && ! [[ "$b" =~ $safe_re ]]; then
    saw_secret=1
    secret_tokens+=("$t")
  fi
done

if (( saw_reader && saw_secret )); then
  # The deny branch above is settled before this point and grants never reach it:
  # a window buys you a quieter prompt on a file already sitting on your disk, not
  # a way to call `op read`.
  guard_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  # shellcheck source=lib/grants.sh
  source "$guard_dir/lib/grants.sh"

  if command -v jq >/dev/null 2>&1; then
    cwd=$(printf '%s' "$payload" | jq -r '.cwd // ""' 2>/dev/null) || cwd=""
  else
    cwd=$(_json_str cwd)
  fi
  call_id=$(grant_call_id "$payload")

  # One command can touch several secret files. Every one of them must already be
  # open, or the command as a whole is not something you have approved.
  canons=() all_open=1
  for t in ${secret_tokens[@]+"${secret_tokens[@]}"}; do
    c=$(grant_canonical_path "$t" "${cwd:-$PWD}") || { all_open=0; continue; }
    canons+=("$c")
    grant_active "$c" >/dev/null || all_open=0
  done
  (( ${#canons[@]} )) || all_open=0

  if (( all_open )); then
    grant_audit "GRANT-USED" "bash" "${canons[0]##*/}"
    decide allow "opgate: an approval window is open for the secret file(s) this command reads. Run 'opgate grants' to see it, 'opgate lock' to close it now."
  fi

  [[ -n "$call_id" ]] && (( ${#canons[@]} )) && pending_write "$call_id" "${canons[@]}"

  decide ask "This command reads a file that may hold plaintext secrets. Reading it puts the values into the model context and ships them to the provider. To see which variables exist, use: opgate list. To run the app with its secrets, use: opgate run -- <cmd>. Approving opens a 60-minute window for THESE files only; 'opgate lock' closes it."
fi

exit 0
