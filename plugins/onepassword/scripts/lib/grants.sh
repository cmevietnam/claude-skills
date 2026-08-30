#!/usr/bin/env bash
# Time-bounded approval windows for LAYER 3 ONLY — the PreToolUse guards.
#
# What this is for: the guards answer "ask" every time the agent reaches for a
# plaintext secret file, and re-answering that prompt for the same file thirty
# times in one session trains you to stop reading it. A grant records that you
# already said yes to one specific file, and lets the guard answer "allow" until
# the window closes.
#
# What this is NOT for: the Touch ID gate in gate.sh. That gate is the layer that
# actually enforces something, and an earlier OPGATE_TTL that cached it was
# removed on purpose — see references/security-model.md. Nothing here touches it.
#
# Why caching layer 3 is defensible when caching layer 1 was not: layer 3 guards a
# file that is already plaintext on disk. Its threat model, stated in
# security-model.md, is "the agent leaks by accident", not "the agent evades on
# purpose" — an agent that wants the file can already reach it with a command the
# tokenizer does not recognise. A window does not lower that ceiling. It does
# widen the accident surface for one named file for one hour, which is the trade
# being made, and `opgate grants` / `opgate lock` are how you take it back.
#
# Forgery: a grant is a file in a directory you own, so anything running as you can
# write one. That is the same objection that killed OPGATE_TTL, and it is still
# true. The answer here is not prevention but evidence — every window opened and
# every window used writes an audit record, so a grant with no matching GRANT
# record in `opgate audit` is a forgery you can see.

# --- paths ------------------------------------------------------------------
# Derived from HOME unconditionally. Deliberately NOT honouring an environment
# variable: a redirectable grant directory is a grant directory an agent can point
# at one it prepared. Tests isolate themselves by overriding HOME instead.
OPGATE_STATE_HOME="$HOME/.local/state/opgate"
OPGATE_GRANT_DIR="$OPGATE_STATE_HOME/grants"
OPGATE_PENDING_DIR="$OPGATE_STATE_HOME/pending"

# The auto-remember window is a hard-coded constant, not a knob. A knob that
# widens a security window is a knob the thing being guarded can turn: an agent
# that can set OPGATE_GRANT_MINUTES=480 has silently bought itself a working day.
# `opgate unlock --minutes N` can ask for longer, because that path shows the
# number on the Touch ID sheet before it takes effect.
OPGATE_GRANT_DEFAULT_MINUTES=60
OPGATE_GRANT_MAX_MINUTES=480

# A pending record is written when a guard says "ask" and consumed when the tool
# actually runs. If you decline, nothing consumes it, so it has to expire on its
# own or the directory fills with keys to files you said no to.
OPGATE_PENDING_MAX_SECONDS=900

# Permission modes in which "the tool ran" is evidence that you approved it.
# Allowlist rather than denylist: under bypassPermissions or dontAsk no prompt is
# shown at all, so a PostToolUse firing proves nothing, and an unrecognised future
# mode must land on "record nothing" rather than "record".
OPGATE_GRANT_MODES=' default plan acceptEdits '

# --- small helpers ----------------------------------------------------------

_grant_now() { printf '%s' "${EPOCHSECONDS:-$(date +%s)}"; }

# Tab and newline are the audit log's field and record separators; a path
# containing either would forge a record.
_grant_clean() { local s="${1//	/ }"; s="${s//$'\n'/ }"; s="${s//$'\r'/ }"; printf '%s' "${s:0:200}"; }

# Prefer the real audit() from gate.sh when opgate is the caller, so CLI and hook
# records are identical. Hooks source this file alone and get the fallback.
grant_audit() { # <status> <action> <detail>
  if declare -f audit >/dev/null 2>&1; then audit "$1" "$2" "$3"; return 0; fi
  mkdir -p -- "$OPGATE_STATE_HOME" 2>/dev/null || return 0
  local log="$OPGATE_STATE_HOME/access.log" caller=shell
  [[ -n "${OPGATE_CALLER:-}" ]] && caller="${OPGATE_CALLER}"
  [[ "$caller" == shell && -n "${CLAUDE_PLUGIN_ROOT:-}${CLAUDECODE:-}" ]] && caller=claude
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "$(_grant_clean "$caller")" \
    "$(_grant_clean "${PWD##*/}")" "$(_grant_clean "$2")" "$(_grant_clean "$3")" \
    >>"$log" 2>/dev/null || true
  chmod 600 "$log" 2>/dev/null || true
  return 0
}

# --- keys -------------------------------------------------------------------

# Absolute, symlink-resolved path. The file itself need not exist — Read on a
# missing .env still asks, and still deserves a stable key.
grant_canonical_path() { # <path> [cwd]
  local p="${1:-}" base dir rdir
  [[ -n "$p" ]] || return 1
  case "$p" in
    /*)   ;;
    '~')  p="$HOME" ;;
    '~/'*) p="$HOME/${p#\~/}" ;;
    *)    p="${2:-$PWD}/$p" ;;
  esac
  base="${p##*/}"
  dir="${p%/*}"
  [[ -n "$dir" ]] || dir=/
  rdir=$(cd -- "$dir" 2>/dev/null && pwd -P) || rdir="$dir"
  printf '%s/%s' "${rdir%/}" "$base"
}

# Filename for a canonical path. Pure bash, no fork: this runs on the hot path of
# every guarded Bash call. Collisions are possible after the character squeeze and
# the length cap, and are harmless — grant_active re-checks the full path stored
# inside the file, so a collision fails closed to "ask" rather than open.
grant_slot() { # <canonical-path>
  local s="${1//[!A-Za-z0-9._-]/_}"
  # NOT `${s: -120}`: a negative offset larger than the string returns the empty
  # string in bash, and an empty slot name makes every path resolve to the grants
  # directory itself. Every grant then silently failed to be written.
  (( ${#s} > 120 )) && s="${s:${#s}-120}"
  printf '%s' "$s"
}

# --- grants -----------------------------------------------------------------
#
# Record format, one line, tab separated:
#   v1 <TAB> expiry-epoch <TAB> origin <TAB> session-id <TAB> canonical-path
#
# Anything that does not parse exactly is treated as no grant. A half-written or
# hand-edited file must not be able to mean "allow".

# Prints the seconds remaining and returns 0 while a grant is live.
grant_active() { # <canonical-path>
  local canon="${1:-}" slot file line ver exp origin sess path now
  [[ -n "$canon" ]] || return 1
  slot=$(grant_slot "$canon")
  file="$OPGATE_GRANT_DIR/$slot"
  [[ -f "$file" ]] || return 1
  IFS= read -r line <"$file" 2>/dev/null || return 1
  IFS=$'\t' read -r ver exp origin sess path <<<"$line"
  [[ "$ver" == v1 ]] || return 1
  [[ "$exp" =~ ^[0-9]+$ ]] || return 1
  # The stored path is the authority, not the filename. Without this check a slot
  # collision would hand one file's approval to a different file.
  [[ "$path" == "$canon" ]] || return 1
  now=$(_grant_now)
  (( exp > now )) || return 1
  printf '%s' $(( exp - now ))
  return 0
}

grant_open() { # <path> <minutes> <origin> [session]
  # Canonicalise here too, not only in the callers. A caller that passes an
  # uncanonical path would otherwise write a grant under a key nothing ever looks
  # up — a window that silently does nothing, which is the worst kind.
  local canon minutes="$2" origin="$3" sess="${4:-unknown}" exp
  canon=$(grant_canonical_path "$1") || return 1
  [[ "$minutes" =~ ^[0-9]+$ ]] || return 1
  (( minutes >= 1 )) || return 1
  (( minutes <= OPGATE_GRANT_MAX_MINUTES )) || minutes=$OPGATE_GRANT_MAX_MINUTES
  mkdir -p -- "$OPGATE_GRANT_DIR" 2>/dev/null || return 1
  chmod 700 "$OPGATE_STATE_HOME" "$OPGATE_GRANT_DIR" 2>/dev/null || true
  exp=$(( $(_grant_now) + minutes * 60 ))
  local file="$OPGATE_GRANT_DIR/$(grant_slot "$canon")"
  # umask so the window is never briefly world-readable between create and chmod.
  ( umask 077
    printf 'v1\t%s\t%s\t%s\t%s\n' "$exp" "$(_grant_clean "$origin")" \
      "$(_grant_clean "$sess")" "$canon" >"$file" ) || return 1
  chmod 600 "$file" 2>/dev/null || true
  # The action field carries the origin, so `opgate audit` distinguishes a window
  # you opened on purpose from one an approval opened for you.
  grant_audit "GRANT" "$origin" "${minutes}m ${canon}"
  return 0
}

grant_revoke() { # <path>
  local canon file
  canon=$(grant_canonical_path "$1") || return 1
  file="$OPGATE_GRANT_DIR/$(grant_slot "$canon")"
  [[ -f "$file" ]] || return 1
  rm -f -- "$file" 2>/dev/null || return 1
  grant_audit "GRANT-REVOKED" "lock" "${canon##*/}"
  return 0
}

grant_revoke_all() {
  local n=0 f
  # Always print a count: `opgate lock` interpolates it, and an empty string there
  # reads as a broken command rather than "there was nothing open".
  [[ -d "$OPGATE_GRANT_DIR" ]] || { printf 0; return 0; }
  for f in "$OPGATE_GRANT_DIR"/*; do
    [[ -f "$f" ]] || continue
    rm -f -- "$f" 2>/dev/null && n=$(( n + 1 ))
  done
  (( n )) && grant_audit "GRANT-REVOKED" "lock" "all ($n)"
  printf '%s' "$n"
  return 0
}

# Prints "<seconds-left><TAB><origin><TAB><path>" per live grant, and sweeps the
# expired ones on the way past so the directory does not grow without bound.
grant_list() {
  local f line ver exp origin sess path now
  [[ -d "$OPGATE_GRANT_DIR" ]] || return 0
  now=$(_grant_now)
  for f in "$OPGATE_GRANT_DIR"/*; do
    [[ -f "$f" ]] || continue
    IFS= read -r line <"$f" 2>/dev/null || { rm -f -- "$f"; continue; }
    IFS=$'\t' read -r ver exp origin sess path <<<"$line"
    if [[ "$ver" != v1 || ! "$exp" =~ ^[0-9]+$ ]]; then rm -f -- "$f"; continue; fi
    if (( exp <= now )); then rm -f -- "$f"; continue; fi
    printf '%s\t%s\t%s\n' $(( exp - now )) "$origin" "$path"
  done
}

# --- pending ----------------------------------------------------------------
#
# The bridge between the two hooks. A PreToolUse guard that answers "ask" writes
# the exact keys it would grant, filed under the tool_use_id; PostToolUse promotes
# them without re-deciding anything. That is the whole point: one classifier, in
# one place, so the two hooks cannot drift apart about what counts as a secret
# file. PostToolUse never runs for a call you declined, so a promotion is your yes.

# The key that lets the two hooks hand something to each other. It has to be the
# same string in PreToolUse and PostToolUse for one tool call, and different for
# every other call.
#
# `tool_use_id` is the right answer and is what we use. The digest fallback exists
# because the whole feature is silent when this key is missing — no error, no
# window, just a prompt that keeps coming back and no way to tell why. tool_input
# is identical in both events, so its digest is a serviceable substitute. Two
# byte-identical calls then share a key, which is harmless: a pending record is
# consumed once, and a call that ran is a call you approved.
grant_call_id() { # <payload>
  local id=""
  command -v jq >/dev/null 2>&1 || { printf ''; return 0; }
  id=$(printf '%s' "$1" | jq -r '.tool_use_id // ""' 2>/dev/null) || id=""
  if [[ -z "$id" ]]; then
    id=$(printf '%s' "$1" | jq -Sc '.tool_input // {}' 2>/dev/null \
         | /usr/bin/shasum -a 256 2>/dev/null | cut -c1-40) || id=""
    [[ -n "$id" ]] && id="ti-$id"
  fi
  printf '%s' "$id"
}

_pending_file() { # <call-id>
  local id="${1//[!A-Za-z0-9._-]/_}"
  (( ${#id} > 80 )) && id="${id:${#id}-80}"
  printf '%s/%s' "$OPGATE_PENDING_DIR" "$id"
}

# True while any pending record is waiting to be promoted. Pure bash, no fork:
# this is the fast bail for a PostToolUse hook that runs after every Read, Grep
# and Bash call, the overwhelming majority of which have nothing to do with
# secrets. An empty glob leaves the literal `*`, which -e rejects.
pending_any() {
  local f
  for f in "$OPGATE_PENDING_DIR"/*; do
    [[ -e "$f" ]] && return 0
  done
  return 1
}

pending_sweep() {
  [[ -d "$OPGATE_PENDING_DIR" ]] || return 0
  find "$OPGATE_PENDING_DIR" -type f -mmin +$(( OPGATE_PENDING_MAX_SECONDS / 60 )) \
    -delete 2>/dev/null || true
}

pending_write() { # <tool-use-id> <canonical-path>...
  local id="${1:-}"; shift
  [[ -n "$id" && $# -gt 0 ]] || return 1
  mkdir -p -- "$OPGATE_PENDING_DIR" 2>/dev/null || return 1
  chmod 700 "$OPGATE_STATE_HOME" "$OPGATE_PENDING_DIR" 2>/dev/null || true
  local file; file=$(_pending_file "$id")
  ( umask 077; printf '%s\n' "$@" >"$file" ) || return 1
  chmod 600 "$file" 2>/dev/null || true
  pending_sweep
  return 0
}

# Turn a pending record into grants. Returns 1 when there is nothing to promote,
# which is the ordinary case for every unguarded tool call.
pending_promote() { # <tool-use-id> <minutes> <origin> [session]
  local id="${1:-}" minutes="$2" origin="$3" sess="${4:-unknown}"
  [[ -n "$id" ]] || return 1
  local file; file=$(_pending_file "$id")
  [[ -f "$file" ]] || return 1

  # Read before unlinking: the record is consumed exactly once either way, but
  # reading a file we have already removed silently promotes nothing.
  local body age now mtime
  body=$(cat -- "$file" 2>/dev/null) || body=""
  now=$(_grant_now)
  mtime=$(/usr/bin/stat -f %m "$file" 2>/dev/null || stat -c %Y "$file" 2>/dev/null) || mtime=0
  [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
  age=$(( now - mtime ))
  rm -f -- "$file" 2>/dev/null || true

  # A pending record older than the window is not evidence of a fresh approval.
  (( age >= 0 && age <= OPGATE_PENDING_MAX_SECONDS )) || return 1

  local p n=0
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    grant_open "$p" "$minutes" "$origin" "$sess" && n=$(( n + 1 ))
  done <<<"$body"
  (( n > 0 ))
}
