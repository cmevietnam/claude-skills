#!/usr/bin/env bash
# Finding secrets that are sitting in the open, and naming where they should live.
#
# Nothing in here prints a value. Findings are reported as file:line plus the kind
# of credential matched — enough to go fix it, not enough to leak it into the
# transcript.

# Directories that are never worth walking.
SCAN_PRUNE='-name node_modules -o -name .git -o -name vendor -o -name dist -o -name build -o -name .next -o -name target -o -name __pycache__ -o -name .venv'

# env files belonging to a project, excluding the committable template forms.
find_env_files() { # <root>
  local root="$1"
  find "$root" \( $SCAN_PRUNE \) -prune -o \
       -type f \( -name '.env' -o -name '.env.*' \) -print 2>/dev/null \
    | grep -Ev '\.(example|sample|tpl|template|op)$' \
    | sort
}

# Config files that habitually end up holding a credential someone pasted.
find_config_files() { # <root>
  local root="$1"
  find "$root" \( $SCAN_PRUNE \) -prune -o \
       -type f \( -name '*.json' -o -name '*.ya?ml' -o -name '*.toml' -o -name '*.ini' \
                  -o -name '*.conf' -o -name '*.tf' -o -name '*.tfvars' -o -name '.npmrc' \
                  -o -name '*.sh' -o -name '*.zshrc' -o -name '*.bashrc' \) -print 2>/dev/null \
    | grep -Ev '(package-lock|yarn\.lock|pnpm-lock|composer\.lock|\.min\.js)' \
    | sort
}

# Credential shapes worth flagging wherever they appear. Each entry is
# "label<TAB>flags<TAB>ERE". The patterns match the credential itself, so the value
# is never printed — only the label, the file and the line number.
#
# `flags` is passed to grep: `i` for the generic assignment pattern, because env
# names are conventionally upper case (AWS_SECRET_ACCESS_KEY) while the pattern
# spells them lower case. The format-specific patterns stay case-sensitive so
# `AKIA…` does not match ordinary prose.
# Built with printf rather than a heredoc: the fields are tab-separated, and a
# literal tab is invisible in a diff and trivially turned into spaces by an editor
# or a copy-paste. That happened once here and silently reduced the scanner to a
# single pattern, so the separator is now explicit in the source.
#
# The flags field is '-' rather than empty for the same class of reason: tab is an
# IFS whitespace character, so `read` collapses two adjacent tabs into one
# delimiter and an empty middle field shifts every later field left.
scan_patterns() {
  printf '%s\t%s\t%s\n' \
    'AWS access key id'  '-' 'AKIA[0-9A-Z]{16}' \
    'GitHub token'       '-' 'gh[pousr]_[A-Za-z0-9]{30,}' \
    'GitLab PAT'         '-' 'glpat-[A-Za-z0-9_-]{15,}' \
    'Slack token'        '-' 'xox[baprs]-[A-Za-z0-9-]{10,}' \
    'Slack webhook'      '-' 'hooks\.slack\.com/services/[A-Za-z0-9/]{20,}' \
    'Stripe key'         '-' '[sprk]k_(live|test)_[A-Za-z0-9]{20,}' \
    'OpenAI-style key'   '-' 'sk-[A-Za-z0-9_-]{20,}' \
    'JWT'                '-' 'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}' \
    'private key block'  '-' '\-\-\-\-\-BEGIN [A-Z ]*PRIVATE KEY\-\-\-\-\-' \
    'URL with password'  '-' '[a-z][a-z0-9+.-]*://[^/@[:space:]"'"'"']+:[^/@[:space:]"'"'"']+@' \
    'assigned secret'    'i' '(password|passwd|secret|token|api[_-]?key|access[_-]?key|client[_-]?secret)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"']{12,}["'"'"']'
}

# scan_embedded <file> -> "line<TAB>label" for each hit. Never emits the match.
#
# Every grep is `|| true`: callers run under `set -e`, and a pattern that does not
# match exits 1. Without this the first non-matching pattern aborted the whole
# function, so only a file matching the very first pattern was ever reported.
scan_embedded() {
  local file="$1" label flags pattern
  while IFS=$'\t' read -r label flags pattern; do
    [[ -n "$label" && -n "$pattern" ]] || continue
    local -a gflags=(-nEI)
    [[ "$flags" == *i* ]] && gflags+=(-i)
    # Only line numbers leave grep: -o would print the credential, and printing the
    # whole matching line is worse.
    { grep "${gflags[@]}" -- "$pattern" "$file" 2>/dev/null || true; } \
      | cut -d: -f1 \
      | while IFS= read -r ln; do
          [[ -n "$ln" ]] && printf '%s\t%s\n' "$ln" "$label"
        done
  done < <(scan_patterns)
  return 0
}

# item_name_for <envfile> <project> <repo-root>
#
# api/.env             -> <project>-api
# .env                 -> <project>
# web/.env.production  -> <project>-web-production
# .env.local           -> <project>-local
#
# Slashes are collapsed to dashes because a `/` in an item title would collide
# with the section separator in an op:// reference.
item_name_for() {
  local file="$1" project="$2" root="$3"
  local rel="${file#"$root"/}"
  local dir; dir=$(dirname -- "$rel")
  local base; base=$(basename -- "$rel")

  local parts="$project"
  if [[ "$dir" != "." ]]; then
    parts="$parts-${dir//\//-}"
  fi
  local suffix="${base#.env}"
  suffix="${suffix#.}"
  [[ -n "$suffix" ]] && parts="$parts-$suffix"

  # Item titles feed op:// references; keep them to a charset that cannot be
  # misread as a path separator.
  printf '%s' "$parts" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-' | tr -s '-'
}
