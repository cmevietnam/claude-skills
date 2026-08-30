#!/usr/bin/env bash
# Finding secrets that are sitting in the open, and naming where they should live.
#
# Nothing in here prints a value. Findings are reported as file:line plus the kind
# of credential matched — enough to go fix it, not enough to leak it into the
# transcript.

# Directories that are never worth walking.
scan_prune_args() {
  printf '%s\n' -name node_modules -o -name .git -o -name vendor -o -name dist \
    -o -name build -o -name .next -o -name .nuxt -o -name out -o -name coverage \
    -o -name target -o -name __pycache__ -o -name .venv -o -name venv \
    -o -name .terraform -o -name Pods -o -name .gradle
}

# Files larger than this are skipped: a scanner that takes minutes on a large repo
# does not get run.
SCAN_MAX_SIZE="${SCAN_MAX_SIZE:-1024k}"

# A path containing a colon would be mis-split when parsing `grep -n` output as
# file:line, and a mis-split could put file CONTENT where a line number belongs.
# Dropping those few paths is cheaper than risking that.
_drop_colon_paths() { grep -v ':' || true; }

# env files belonging to a project, excluding the committable template forms.
find_env_files() { # <root>
  local root="$1"; local -a prune=(); local a
  while IFS= read -r a; do prune+=("$a"); done < <(scan_prune_args)
  find "$root" \( "${prune[@]}" \) -prune -o \
       -type f \( -name '.env' -o -name '.env.*' \) -print 2>/dev/null \
    | grep -Ev '\.(example|sample|tpl|template|op)$' \
    | _drop_colon_paths \
    | sort
}

# Config and source files that habitually end up holding a credential someone
# pasted. `-name '*.ya?ml'` used to stand in for yaml and yml; `?` matches exactly
# one character, so it matched neither and YAML was never scanned at all.
find_config_files() { # <root>
  local root="$1"; local -a prune=(); local a
  while IFS= read -r a; do prune+=("$a"); done < <(scan_prune_args)
  find "$root" \( "${prune[@]}" \) -prune -o \
       -type f -size "-$SCAN_MAX_SIZE" \( \
            -name '*.json' -o -name '*.yaml' -o -name '*.yml' -o -name '*.toml' \
         -o -name '*.ini'  -o -name '*.conf' -o -name '*.cfg'  -o -name '*.properties' \
         -o -name '*.tf'   -o -name '*.tfvars' -o -name '.npmrc' -o -name '.netrc' \
         -o -name '*.sh'   -o -name '*.bash' -o -name '*.zsh'  -o -name '*.fish' \
         -o -name '*.js'   -o -name '*.mjs'  -o -name '*.cjs'  -o -name '*.ts' \
         -o -name '*.jsx'  -o -name '*.tsx'  -o -name '*.py'   -o -name '*.rb' \
         -o -name '*.go'   -o -name '*.php'  -o -name '*.java' -o -name '*.cs' \
         -o -name '*.rs'   -o -name '*.tpl'  -o -name '*.tmpl' -o -name 'Dockerfile*' \
       \) -print 2>/dev/null \
    | grep -Ev '(package-lock|yarn\.lock|pnpm-lock|composer\.lock|go\.sum|Cargo\.lock|\.min\.(js|css)$)' \
    | _drop_colon_paths \
    | sort
}

# Credential shapes worth flagging wherever they appear. Fields are tab-separated
# and built with printf, not a heredoc: a literal tab is invisible in a diff and
# an editor turned them into spaces once, silently reducing this to one pattern.
#
# The flags field is '-' rather than empty for a related reason: tab is an IFS
# whitespace character, so `read` collapses two adjacent tabs and an empty middle
# field shifts every later field left.
scan_patterns() {
  printf '%s\t%s\t%s\n' \
    'AWS access key id'   '-' '(^|[^A-Za-z0-9])A(KIA|SIA)[0-9A-Z]{16}' \
    'GitHub token'        '-' 'gh[pousr]_[A-Za-z0-9]{30,}' \
    'GitHub fine-grained' '-' 'github_pat_[A-Za-z0-9_]{20,}' \
    'GitLab PAT'          '-' 'glpat-[A-Za-z0-9_-]{15,}' \
    'npm token'           '-' 'npm_[A-Za-z0-9]{30,}' \
    'Slack token'         '-' 'xox[baprs]-[A-Za-z0-9-]{10,}' \
    'Slack webhook'       '-' 'hooks\.slack\.com/services/[A-Za-z0-9/]{20,}' \
    'Discord webhook'     '-' 'discord(app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]{20,}' \
    'Stripe secret key'   '-' '[sr]k_(live|test)_[A-Za-z0-9]{20,}' \
    'OpenAI-style key'    '-' 'sk-[A-Za-z0-9_-]{20,}' \
    'JWT'                 '-' 'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}' \
    'private key block'   '-' '\-\-\-\-\-BEGIN [A-Z ]*PRIVATE KEY\-\-\-\-\-' \
    'URL with password'   '-' '[a-z][a-z0-9+.-]*://[^/@[:space:]"'"'"']+:[^/@[:space:]"'"'"']+@' \
    'assigned secret'     'i' '(password|passwd|secret|token|api[_-]?key|access[_-]?key|client[_-]?secret|auth[_-]?token)["'"'"']?[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"']{12,}["'"'"']' \
    'assigned secret'     'i' '(password|passwd|secret|token|api[_-]?key|access[_-]?key|client[_-]?secret|auth[_-]?token|_authToken)[[:space:]]*[:=][[:space:]]*[^"'"'"'[:space:]]{16,}'
}

# scan_embedded_list -> "file<TAB>line<TAB>label" for every hit across the file
# list on stdin. Never emits the match itself.
#
# One grep per pattern across all files, rather than per pattern per file: the old
# shape re-read every selected file 11 times.
scan_embedded_list() {
  local list; list=$(mktemp "${TMPDIR:-/tmp}/opgate-scan.XXXXXX")
  cat > "$list"
  [[ -s "$list" ]] || { rm -f "$list"; return 0; }

  local label flags pattern
  while IFS=$'\t' read -r label flags pattern; do
    [[ -n "$label" && -n "$pattern" ]] || continue
    local -a gflags=(-nEI)
    [[ "$flags" == *i* ]] && gflags+=(-i)
    # /dev/null keeps grep in multi-file mode so it always prefixes the filename.
    # cut leaves only file:line — the matched text never leaves the pipeline.
    { tr '\n' '\0' < "$list" \
        | xargs -0 grep "${gflags[@]}" -- "$pattern" /dev/null 2>/dev/null || true; } \
      | cut -d: -f1,2 \
      | while IFS=: read -r f ln; do
          [[ -n "$f" && -n "$ln" && "$f" != /dev/null ]] && printf '%s\t%s\t%s\n' "$f" "$ln" "$label"
        done
  done < <(scan_patterns)
  rm -f "$list"
  return 0
}

# Single-file form, kept for the tests.
scan_embedded() { # <file>
  printf '%s\n' "$1" | scan_embedded_list | cut -f2,3
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
