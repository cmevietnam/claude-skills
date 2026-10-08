#!/usr/bin/env bash
# PreToolUse(Bash) guard.
#
# One job: keep every WRITE to Cloudflare inside the project that issues it. A
# Cloudflare account is flat - every Worker, bucket, queue, tunnel and zone of
# every project sits side by side - so the boundary is drawn from three things
# the repo declares in .cloudflare/project.json:
#
#   accountId   the account a write must be pinned to
#   zones       the zones (by name and id) whose hostnames are the project's
#   prefixes    the name prefix of every account-level resource it owns
#
# Reads are none of its business. Credentials are: a token written out on a
# command line, or printed to stdout, is refused or confirmed wherever it
# appears, project or not.
#
# The guard never calls the network. Every decision comes from the command text,
# the repo's files and the local cloudflared certificate, so it cannot time out
# on a slow API and fall open. It fails closed on everything it controls: an
# unknown command path, an unreadable value, a missing config, a command it
# cannot attribute, or an internal error in this script all end in a refusal or
# a prompt.

payload=$(cat)

# Fast path: nothing of interest, get out before doing any real work. Every Bash
# call in the session pays for this script's startup. The test runs on the text
# with quotes, backslashes and line continuations removed and case folded, so
# `wran""gler`, `wrang\<NL>ler` and `WRANGLER` (macOS file systems ignore case)
# are all seen. `\\\n` is how JSON spells a backslash-newline.
_norm=${payload//'\\\n'/}
_norm=$(printf '%s' "$_norm" | tr -d '"\\'"'" | tr '[:upper:]' '[:lower:]')
# `cf` (the Cloudflare CLI) is two letters, so it counts only as a whole word.
case "$_norm" in
  *wrangler*|*cloudflare*|*cf_api_*|*tunnel_token*) ;;
  *) [[ "$_norm" =~ (^|[^a-z0-9_.-])cf([^a-z0-9_.-]|$) ]] || exit 0 ;;
esac

emit() {
  # $1 = allow|deny|ask, $2 = reason. The reason quotes command fragments, so
  # quotes and backslashes are stripped: invalid JSON counts as no decision at
  # all, and no decision means the write proceeds.
  local reason
  reason=$(printf '%s' "$2" | tr -d '\000-\037' | tr '\\"' '  ')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$1" "$reason"
}

# From here on the payload mentions Cloudflare, so falling over silently would
# mean letting a write through. Anything that reaches EXIT undecided refuses.
guard_done=0
trap '[[ $guard_done -eq 1 ]] || emit deny "cfgate: the hook hit an internal error and could not verify this command. This refusal is deliberate (fail closed). Run: bash plugins/cloudflare/scripts/test-guard.sh to see what broke."' EXIT

# An `ask` is remembered, not issued: a later segment may still deserve a
# refusal, and a refusal outranks a prompt. Only deny exits early.
pending_ask=""
decide() {
  if [[ "$1" == ask ]]; then
    [[ -n "$pending_ask" ]] || pending_ask="$2"
    return 0
  fi
  guard_done=1; emit "$1" "$2"; exit 0
}

checked=""
note() { checked="${checked:+$checked; }$1"; }

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)
for f in common shell wrangler tunnel api cfcli; do
  [[ -r "$here/lib/$f.sh" ]] || decide deny \
    "cfgate: $here/lib/$f.sh is missing, so the guard cannot run. Reinstall the plugin or run 'claude plugin validate ./plugins/cloudflare'."
  # shellcheck disable=SC1090
  . "$here/lib/$f.sh" 2>/dev/null
done
# A library that failed to parse leaves these undefined; without this check the
# script would fall through to "nothing to guard" and let the write go.
for f in sh_split sh_scan parse_wrangler parse_cloudflared parse_curl parse_cf flatten_config load_project line_var_get; do
  type "$f" >/dev/null 2>&1 || decide deny \
    "cfgate: scripts/lib/*.sh failed to load ($f is undefined). Run: bash -n plugins/cloudflare/scripts/lib/*.sh"
done

if [[ "$CFGATE_GUARD" == off ]]; then guard_done=1; exit 0; fi

# bash 3.2 backs every here-string with a temp file. If that cannot be created
# the parsing loops silently never run, and no segments would read as "nothing
# to guard". Prove it works first.
_probe=""
read -r _probe <<< "probe" 2>/dev/null
[[ "$_probe" == probe ]] || decide deny \
  "cfgate: cannot create the temp file a here-string needs (TMPDIR=${TMPDIR:-/tmp} is full or not writable), so the command cannot be parsed. Free up TMPDIR and retry."

command_line=$(hook_command "$payload")
if [[ -z "$command_line" ]]; then
  case "$payload" in
    *'"command"'*) decide deny "cfgate: the payload has a command field but its contents could not be read, so the command cannot be verified. Check jq/awk on this machine." ;;
  esac
  guard_done=1; exit 0
fi

# Claude Code kills the hook at its timeout (15 s) and then DISCARDS its
# decision, so the command runs unchecked. Lexing grows with the command; a
# command this long gets a prompt now rather than a verdict too late.
CFGATE_MAX_BYTES="${CFGATE_MAX_BYTES:-65536}"
if (( ${#command_line} > CFGATE_MAX_BYTES )); then
  guard_done=1
  emit ask "This command is ${#command_line} bytes and mentions Cloudflare - too long to verify before the hook's time limit, after which it would run unchecked. Split it, or put the long part in a file. The user decides."
  exit 0
fi

# Does the line mention a Cloudflare tool at all (any case, quotes removed)?
# Commands the guard cannot attribute ask only when it does.
_lnorm=$(printf '%s' "$command_line" | tr -d '"\\'"'" | tr '[:upper:]' '[:lower:]')
case "$_lnorm" in
  *wrangler*|*cloudflared*|*api.cloudflare*) LINE_MENTIONS=1 ;;
  *) LINE_MENTIONS=0
     [[ "$_lnorm" =~ (^|[^a-z0-9_.-])(cf|cloudflare)([^a-z0-9_.-]|$) ]] && LINE_MENTIONS=1 ;;
esac

# Where the command runs. The Bash tool reports its cwd in the payload; that is
# the directory whose .cloudflare/project.json applies. A `cd` moves it again;
# "?" means a cd went somewhere the guard cannot know.
eff_cwd=$(payload_str "$payload" '.cwd' 'cwd')
[[ -n "$eff_cwd" ]] || eff_cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
inv_cwd="$eff_cwd"

# --- the project ----------------------------------------------------------------
proj_root=""
need_project() {
  local root problems
  [[ "$inv_cwd" != "?" ]] || decide deny \
    "cfgate cannot tell which directory this command runs in: an earlier cd on this line goes somewhere the shell computes (a variable, 'cd -', popd), so the wrangler config, .env files and project that apply are unknown. Write the cd target literally, or run the command from its directory."
  root=$(find_project_root "$inv_cwd") || decide deny \
    "No .cloudflare/project.json found from $inv_cwd upward, so there is no way to tell which project this write belongs to. Run 'cfgate init' at the repo root first (see skills/cloudflare/references/project-setup.md), then retry."
  [[ "$root" == "$proj_root" ]] && return 0
  proj_root="$root"
  load_project "$root" || decide deny "$root/$CFGATE_CONFIG could not be read."
  problems=$(project_problems)
  [[ -z "$problems" ]] || decide deny \
    "$root/$CFGATE_CONFIG is not usable: $(printf '%s' "$problems" | tr '\n' ';' | sed 's/;$//'). Fix it, then 'cfgate doctor'."
}

# A resource name must be inside the project, and a protected one asks.
check_name() {
  # $1 = kind of thing, $2 = name
  local what="$1" n="$2" g
  [[ -n "$n" ]] || decide deny \
    "This command writes a $what but names none on the command line, so there is no way to tell whose it is. Name it explicitly."
  is_literal "$n" || decide deny \
    "The $what is given as '$n', a value the shell supplies at run time, so the guard cannot verify it belongs to project '$CFG_PROJECT'. Write the name literally."
  name_in_project "$n" || decide deny \
    "$what '$n' is outside project '$CFG_PROJECT': its names start with [${CFG_PREFIXES[*]-}]${CFG_NAMES[0]+ or are one of [${CFG_NAMES[*]}]}. It may belong to another project on the same account - this is the hard boundary of this plugin, no exceptions. If it really is this project's, add it to names in .cloudflare/project.json."
  if g=$(protected_match "$n"); then
    decide ask "$what '$n' is protected in .cloudflare/project.json (matches '$g'). Every other check passed; the user confirms this write."
  fi
  note "$what $n"
}

# A hostname must be in one of the project's zones; a protected one asks.
check_host() {
  # $1 = what, $2 = hostname
  local what="$1" h="$2" z g
  is_literal "$h" || decide deny \
    "The $what is given as '$h', a value the shell supplies at run time, so the guard cannot verify which zone it is in. Write it literally."
  z=$(zone_of_host "$h") || decide deny \
    "$what '$h' is not in any zone of project '$CFG_PROJECT' ([${CFG_ZONE_NAMES[*]-}]). Hostnames in other zones belong to other projects. If the zone is really this project's, add it to zones in .cloudflare/project.json."
  if g=$(protected_match "$h") || g=$(protected_match "$z"); then
    decide ask "$what '$h' is protected in .cloudflare/project.json (matches '$g'). Every other check passed; the user confirms this write."
  fi
  HOST_ZONE="$z"
  note "$what $h"
}

# Does this segment's standard output stay out of the transcript? Follow the
# pipeline to its last stage: a redirect to a file there, `opgate put`, or a
# capture by the shell into a variable or a quiet curl header counts. A capture
# that a printing command then echoes (`echo $(wrangler auth token)`), a curl
# that prints its request headers (-v, --trace), and /dev/stdout do not.
stdout_is_kept_private() {
  local j="$1" o w only=1 first=1
  while (( j + 1 < ${#segs[@]} )) && [[ "${seg_piped[j]}" == 1 ]]; do j=$((j + 1)); done
  [[ "${seg_stdout[j]}" == 1 ]] && return 0
  sh_words "${segs[j]}"
  if sh_head && [[ "$SH_HEAD" == opgate && "$SH_HEAD_ARG" == put ]]; then return 0; fi
  if [[ "${seg_cap[j]}" == 1 ]]; then
    o=$(sh_outer_of "${seg_gid[j]}") || return 1
    sh_words "${segs[o]}"
    # Only assignments: X=$(...), export X=$(...).
    for w in ${SH_WORDS[@]+"${SH_WORDS[@]}"}; do
      if (( first )) && [[ "$w" == export || "$w" == local || "$w" == readonly || "$w" == declare ]]; then first=0; continue; fi
      first=0
      [[ "$w" =~ $_sh_re_assign ]] || { only=0; break; }
    done
    (( only )) && return 0
    if sh_head && [[ "$SH_HEAD" == curl ]]; then
      for w in "${SH_WORDS[@]}"; do
        case "$w" in
          --verbose|--trace|--trace=*|--trace-ascii|--trace-ascii=*) return 1 ;;
          --*) ;;
          -*v*) return 1 ;;
        esac
      done
      return 0
    fi
  fi
  return 1
}

secret_read() {
  # $1 = segment index, $2 = what prints the credential
  stdout_is_kept_private "$1" && { note "$2 (output kept private)"; return 0; }
  decide ask \
    "$2 prints a credential to stdout, i.e. into the conversation transcript and up to the model provider - once leaked it must be rotated. Send it where it is needed instead: into a variable (T=\$(...)), a git-ignored file (> file), or 1Password (| opgate put <item> <FIELD>). Piping into a command that still prints does not count. See skills/cloudflare/references/secrets.md"
}

SECRET_LIT_MSG="reads the secret from a here-string or heredoc written into the command, so the value is in the transcript and must be rotated. Pipe it from where it lives: opgate exec VAR=op://... -- sh -c 'printf %s \"\$VAR\" | wrangler ...', or < a git-ignored file. See skills/cloudflare/references/secrets.md"

# Where does standard input of a secret-setting command come from? Refuses a
# literal value, wherever in the pipeline it is typed, and a missing one.
check_secret_stdin() {
  # $1 = segment index, $2 = command
  local idx="$1" what="$2" fed w lit=0 args=0
  case "${seg_stdin[idx]}" in
    stdin-lit|heredoc) decide deny "'$what' $SECRET_LIT_MSG" ;;
    stdin) note "$what (stdin from the shell)"; return 0 ;;
  esac
  fed=${seg_fed[idx]}
  if (( fed < 0 )); then
    decide deny \
      "'$what' has nothing on standard input. Wrangler would prompt (and hang) or store an empty value. Pipe the value in from where it lives, never typed on the line: printf '%s' \"\$(cat <git-ignored file>)\" | wrangler $what ..., or through opgate. See skills/cloudflare/references/secrets.md"
  fi
  # `cat <<EOF | ...` and `cat <<< 'value' | ...` type the value just as surely.
  case "${seg_stdin[fed]}" in
    stdin-lit|heredoc) decide deny "'$what' $SECRET_LIT_MSG" ;;
  esac
  sh_words "${segs[fed]}"
  sh_head
  case "$SH_HEAD" in
    echo|printf)
      for w in "${SH_WORDS[@]}"; do
        [[ "$w" =~ $_sh_re_assign ]] && continue
        [[ "${w##*/}" == "$SH_HEAD" ]] && continue
        [[ "$SH_HEAD" == echo && "$w" == -[neE]* ]] && continue
        [[ "$SH_HEAD" == printf && "$w" == *%* ]] && continue
        args=$((args + 1))
        is_literal "$w" && lit=1
      done
      (( args == 0 )) && [[ "$SH_HEAD" == printf ]] && lit=1
      (( lit == 0 )) || decide deny \
        "The value piped into '$what' is written out on the command line ($SH_HEAD ...), so the secret is in the transcript and must be rotated. Take it from a variable filled by opgate, or from a git-ignored file. See skills/cloudflare/references/secrets.md" ;;
  esac
  note "$what (stdin from ${SH_HEAD:-a pipe})"
}

# Every place the account a wrangler write lands in can be decided: the command
# line, variables exported earlier on it, the environment, .env files and the
# config. Each one present must be the project's account, and at least one must
# be: wrangler with no pin uses whichever account the login can reach. Which one
# wins varies by command (Pages prefers the environment), so all must agree.
wr_check_account() {
  local flat="$1" a v src found=0 line
  shift
  for a in ${SH_ASSIGNS[@]+"${SH_ASSIGNS[@]}"}; do
    case "$a" in
      CLOUDFLARE_ACCOUNT_ID=*)
        v=${a#CLOUDFLARE_ACCOUNT_ID=}
        is_literal "$v" || decide deny \
          "CLOUDFLARE_ACCOUNT_ID is set to '$v', a value the shell supplies at run time, so the account this write lands in cannot be verified. Write the id literally: CLOUDFLARE_ACCOUNT_ID=$CFG_ACCOUNT"
        [[ "$v" == "$CFG_ACCOUNT" ]] || decide deny \
          "CLOUDFLARE_ACCOUNT_ID=$v on the command line is not project '$CFG_PROJECT''s account ($CFG_ACCOUNT). This write would land in another account."
        found=1 ;;
    esac
  done
  if line_var_get CLOUDFLARE_ACCOUNT_ID exported; then
    is_literal "$LV" || decide deny \
      "CLOUDFLARE_ACCOUNT_ID is exported earlier on this line from a value the shell computes, so the account this write lands in cannot be verified."
    [[ "$LV" == "$CFG_ACCOUNT" ]] || decide deny \
      "CLOUDFLARE_ACCOUNT_ID=$LV is exported earlier on this line and is not project '$CFG_PROJECT''s account ($CFG_ACCOUNT). This write would land in another account."
    found=1
  fi
  if [[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
    [[ "$CLOUDFLARE_ACCOUNT_ID" == "$CFG_ACCOUNT" ]] || decide deny \
      "The environment sets CLOUDFLARE_ACCOUNT_ID=$CLOUDFLARE_ACCOUNT_ID, which is not project '$CFG_PROJECT''s account ($CFG_ACCOUNT). Unset it, or override it on the command line."
    found=1
  fi
  while IFS=$'\t' read -r src v; do
    [[ -n "$src" ]] || continue
    [[ "$v" == "$CFG_ACCOUNT" ]] || decide deny \
      "$src sets CLOUDFLARE_ACCOUNT_ID=$v, and wrangler loads that file for itself. It is not project '$CFG_PROJECT''s account ($CFG_ACCOUNT)."
    found=1
  done <<< "$(wr_envfile_accounts "$@")"
  if [[ -n "$flat" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      v=${line#*$'\t'}
      [[ "$v" == "$CFG_ACCOUNT" ]] || decide deny \
        "$WR_CFG sets ${line%%$'\t'*} = $v, which is not project '$CFG_PROJECT''s account ($CFG_ACCOUNT)."
      found=1
    done <<< "$(printf '%s\n' "$flat" | flat_grep '^(env/[^/]+/)?account_id$')"
  fi
  (( found )) || decide deny \
    "Nothing pins this wrangler write to project '$CFG_PROJECT''s account, so wrangler would use whichever account the login reaches first. Set account_id to $CFG_ACCOUNT in ${WR_CFG:-the wrangler config} (once, committed), or prefix the command: CLOUDFLARE_ACCOUNT_ID=$CFG_ACCOUNT wrangler ..."
  note "account $CFG_ACCOUNT"
}

# Everything a deploy publishes beyond its name: routes and the resources its
# bindings reach. A Worker bound to another project's bucket can write to it,
# and deploying a workflow binding claims that account-level workflow.
WR_BINDING_NAMES_RE='(^|/)(r2_buckets\[\]/(bucket_name|preview_bucket_name)|queues/(producers|consumers)\[\]/(queue|dead_letter_queue)|d1_databases\[\]/database_name|services\[\]/service|tail_consumers\[\]/service|durable_objects/bindings\[\]/script_name|workflows\[\]/(name|script_name)|vectorize\[\]/index_name|analytics_engine_datasets\[\]/dataset|dispatch_namespaces\[\]/namespace|pipelines\[\]/pipeline)$'
wr_check_config_boundary() {
  local flat="$1" line p v
  [[ -n "$flat" ]] || return 0
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    p=${line%%$'\t'*}; v=${line#*$'\t'}
    case "$p" in
      */zone_name|zone_name)
        zone_name_is_ours "$v" || decide deny \
          "$WR_CFG routes to zone '$v' ($p), which is not a zone of project '$CFG_PROJECT' ([${CFG_ZONE_NAMES[*]-}])." ;;
      */zone_id|zone_id)
        zone_id_is_ours "$v" || decide deny \
          "$WR_CFG routes to zone id '$v' ($p), which is not a zone of project '$CFG_PROJECT'." ;;
      *) check_host "route ($p in $(basename "$WR_CFG"))" "$(host_of_pattern "$v")" ;;
    esac
  done <<< "$(printf '%s\n' "$flat" | flat_grep '(^|/)(routes\[\]|route)(/(pattern|zone_name|zone_id))?$')"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    p=${line%%$'\t'*}; v=${line#*$'\t'}
    name_in_project "$v" || decide deny \
      "$WR_CFG binds '$v' ($p), which is outside project '$CFG_PROJECT' (prefixes [${CFG_PREFIXES[*]-}]). A Worker bound to another project's resource can read and write it. If it really is this project's, add it to names in .cloudflare/project.json."
  done <<< "$(printf '%s\n' "$flat" | flat_grep "$WR_BINDING_NAMES_RE")"
}

# --- wrangler ---------------------------------------------------------------------
# What a positional names, in words a refusal can use.
wr_label() {
  case "$1" in
    'r2 bucket'*)          printf 'R2 bucket' ;;
    'kv namespace'*)       printf 'KV namespace' ;;
    d1*)                   printf 'D1 database' ;;
    queues*)               printf 'queue' ;;
    'pages project'*)      printf 'Pages project' ;;
    vectorize*)            printf 'Vectorize index' ;;
    workflows*)            printf 'workflow' ;;
    dispatch-namespace*)   printf 'dispatch namespace' ;;
    pipelines*)            printf 'pipeline' ;;
    pubsub*)               printf 'Pub/Sub resource' ;;
    hyperdrive*)           printf 'Hyperdrive config' ;;
    secrets-store*)        printf 'secrets store' ;;
    'vpc service'*)        printf 'VPC service' ;;
    *)                     printf '%s' "${1% *}" ;;
  esac
}

guard_wrangler() {
  local idx="$1" base flat="" name v a r
  parse_wrangler
  # CLOUDFLARE_ENV picks the environment too: on the line, exported earlier on
  # it, or in the environment. --env wins over all of them.
  if [[ -z "$W_ENV" ]]; then
    if line_var_get CLOUDFLARE_ENV exported; then W_ENV="$LV"
    elif [[ -n "${CLOUDFLARE_ENV:-}" ]]; then W_ENV="$CLOUDFLARE_ENV"; fi
  fi

  (( W_HELP == 1 )) && return 0
  [[ -z "$W_SECRET_LIT" ]] || decide deny \
    "$W_SECRET_LIT is given a literal value on the command line; it lands in the transcript and the shell history and must be rotated. Pass it from a variable filled by opgate: opgate exec VAR=op://... -- wrangler ... $W_SECRET_LIT \"\$VAR\". See skills/cloudflare/references/secrets.md"

  if [[ -z "$W_CMD" ]]; then
    [[ -z "$W_FIRSTPOS" ]] && return 0      # bare `wrangler`: prints help
    decide deny \
      "cfgate does not know 'wrangler $W_FIRSTPOS ...', so it cannot tell whether it writes. Check 'wrangler $W_FIRSTPOS --help'; if this is a new command, classify it in plugins/cloudflare/scripts/lib/wrangler.sh."
  fi

  case "$W_KIND" in
    local|read) return 0 ;;
    secret) secret_read "$idx" "'wrangler $W_CMD'"; return 0 ;;
    cli) decide ask "'wrangler $W_CMD' changes wrangler's own login, not a resource of any project. The user decides."; return 0 ;;
    rlocal) (( W_REMOTE == 1 )) || { note "wrangler $W_CMD (local state only)"; return 0; } ;;
  esac
  case "$W_CMD" in
    deploy|delete|'versions upload') (( W_DRYRUN == 1 )) && return 0 ;;
  esac

  # --- a write that reaches the account ---
  case "$SH_VIA" in
    npx|bunx|dlx|npm-exec)
      decide deny \
        "'$SH_VIA wrangler' may silently download and run a different wrangler than the project pins (from a directory with no local install it fetches the latest), and this command writes. Run the project's own binary by path, e.g. ./node_modules/.bin/wrangler $W_CMD ..., or the global 'wrangler'." ;;
  esac
  (( W_NAMES <= 1 )) || decide deny \
    "--name is given more than once; wrangler would act on one of them and the guard cannot know which. Give it once."
  need_project
  base=$(wr_basedir "$inv_cwd")
  wr_find_config "$base"
  if [[ -n "$WR_CFG_WHY" ]]; then
    decide deny \
      "cfgate cannot tell which wrangler config this command reads: $WR_CFG_WHY. Pass the config explicitly with -c <file>."
  fi
  if [[ -n "$WR_CFG" ]]; then
    flat=$(flatten_config "$WR_CFG")
    wr_check_account "$flat" "$base" "$(dirname "$WR_CFG")"
  else
    wr_check_account "" "$base"
  fi

  case "$W_TARGET" in
    worker)
      if [[ "$W_CMD" == delete && -n "${W_ARGS[0]:-}" ]]; then name="${W_ARGS[0]}"
      else name=$(wr_worker_name "$flat") || name=""; fi
      [[ -n "$name" ]] || decide deny \
        "'wrangler $W_CMD' acts on a Worker, but there is no --name and ${WR_CFG:-no wrangler config was found} gives no name, so there is no way to tell whose Worker it is. Run it where the config is, or pass -c / --name."
      check_name Worker "$name"
      case "$W_CMD" in
        deploy|'versions upload'|'triggers deploy') wr_check_config_boundary "$flat" ;;
      esac
      for r in ${W_ROUTES[@]+"${W_ROUTES[@]}"}; do check_host "route (--route)" "$(host_of_pattern "$r")"; done
      for r in ${W_DOMAINS[@]+"${W_DOMAINS[@]}"}; do check_host "custom domain" "$r"; done
      [[ -n "$W_DISPATCH" ]] && check_name "dispatch namespace" "$W_DISPATCH"
      case "$W_CMD" in
        'secret put'|'versions secret put') check_secret_stdin "$idx" "$W_CMD" ;;
        'secret bulk'|'versions secret bulk') [[ -n "${W_ARGS[0]:-}" ]] || check_secret_stdin "$idx" "$W_CMD" ;;
      esac ;;
    pos)
      check_name "$(wr_label "$W_CMD")" "${W_ARGS[0]:-}" ;;
    pos2)
      check_name queue "${W_ARGS[0]:-}"
      check_name Worker "${W_ARGS[1]:-}" ;;
    bucket)
      v="${W_ARGS[0]:-}"
      check_name "R2 bucket" "${v%%/*}" ;;
    domain)
      check_name "R2 bucket" "${W_ARGS[0]:-}"
      for r in ${W_DOMAINS[@]+"${W_DOMAINS[@]}"}; do check_host "R2 custom domain" "$r"; done
      if [[ -n "$W_ZONEID" ]]; then
        zone_id_is_ours "$W_ZONEID" || decide deny "--zone-id $W_ZONEID is not a zone of project '$CFG_PROJECT'."
      fi ;;
    kv)
      if [[ -n "$W_BINDING" ]]; then
        [[ -n "$flat" ]] && printf '%s\n' "$flat" | flat_grep '(^|/)kv_namespaces\[\]/binding$' | cut -f2 | grep -qxF -- "$W_BINDING" || decide deny \
          "--binding $W_BINDING is not a kv_namespaces binding in ${WR_CFG:-any wrangler config found from here}, so the namespace it resolves to is unknown. Run it next to the config that declares it, or pass -c."
        name=$(wr_worker_name "$flat") && check_name Worker "$name"
        note "KV binding $W_BINDING"
      elif [[ -n "$W_NSID" ]]; then
        [[ -n "$flat" ]] && printf '%s\n' "$flat" | flat_grep '(^|/)kv_namespaces\[\]/(id|preview_id)$' | cut -f2 | grep -qxF -- "$W_NSID" || decide deny \
          "--namespace-id $W_NSID is not declared in ${WR_CFG:-any wrangler config found from here}. A namespace id says nothing about whose it is; use --binding from the project's config instead."
        name=$(wr_worker_name "$flat") && check_name Worker "$name"
        note "KV namespace $W_NSID"
      else
        check_name "KV namespace" "${W_ARGS[0]:-}"
      fi ;;
    d1)
      v="${W_ARGS[0]:-}"
      [[ -n "$v" ]] || decide deny "'wrangler $W_CMD' names no database."
      if name_in_project "$v"; then
        check_name "D1 database" "$v"
      elif [[ -n "$flat" ]] && printf '%s\n' "$flat" | flat_grep '(^|/)d1_databases\[\]/binding$' | cut -f2 | grep -qxF -- "$v"; then
        # A binding: every database the config declares must be the project's.
        while IFS= read -r a; do
          [[ -n "$a" ]] && check_name "D1 database" "$a"
        done <<< "$(printf '%s\n' "$flat" | flat_grep '(^|/)d1_databases\[\]/database_name$' | cut -f2)"
        name=$(wr_worker_name "$flat") && check_name Worker "$name"
      else
        check_name "D1 database" "$v"
      fi ;;
    pages)
      name="$W_PROJECT"
      [[ -n "$name" ]] || name=$(printf '%s\n' "$flat" | flat_get name | head -1)
      check_name "Pages project" "$name"
      case "$W_CMD" in
        'pages secret put') check_secret_stdin "$idx" "$W_CMD" ;;
        'pages secret bulk') [[ -n "${W_ARGS[0]:-}" ]] || check_secret_stdin "$idx" "$W_CMD" ;;
      esac ;;
    id)
      decide ask "'wrangler $W_CMD ${W_ARGS[*]-}' addresses its target by id, and an id says nothing about which project owns it. The account is the project's; the user confirms the target." ;;
    account)
      decide ask "'wrangler $W_CMD' changes account-level state that belongs to no single project. The user decides." ;;
  esac
  [[ "$W_KIND" == ask ]] && decide ask "'wrangler $W_CMD' cannot be attributed to project '$CFG_PROJECT' from the command alone. The user decides."
  note "wrangler $W_CMD"
}

# --- cloudflared ----------------------------------------------------------------------
cfd_check_cert() {
  local z
  cfd_cert_path "$inv_cwd" || decide deny \
    "cfgate cannot tell which origin certificate cloudflared will use ($CFD_CERT_SRC), so the account and zone of this write are unknown. Pass --origincert <file>."
  cfd_cert_ids "$CFD_CERT" || decide deny \
    "$CFD_CERT ($CFD_CERT_SRC) is missing or is not a cloudflared origin certificate, so the account and zone of this write are unknown. Run 'cloudflared tunnel login' for a zone of project '$CFG_PROJECT' and keep the file under a name that says which zone it is for."
  [[ "$CERT_ACCOUNT" == "$CFG_ACCOUNT" ]] || decide deny \
    "$CFD_CERT ($CFD_CERT_SRC) belongs to account $CERT_ACCOUNT, not project '$CFG_PROJECT''s account $CFG_ACCOUNT."
  z=$(zone_name_of_id "$CERT_ZONE") || decide deny \
    "$CFD_CERT ($CFD_CERT_SRC) was issued for zone id $CERT_ZONE, which is not a zone of project '$CFG_PROJECT' ([${CFG_ZONE_NAMES[*]-}]). cloudflared acts inside the certificate's zone. Pass --origincert with this project's certificate, e.g. --origincert ~/.cloudflared/cert.pem.<zone>."
  CERT_ZONE_NAME="$z"
  note "cert $CFD_CERT (zone $z)"
}

cfd_check_tunnel_ref() {
  # $1 = tunnel name or UUID
  if is_uuid "$1"; then
    decide ask "The tunnel is named by UUID ($1), which says nothing about which project owns it. The user confirms it is project '$CFG_PROJECT''s tunnel."
    return 0
  fi
  check_name tunnel "$1"
}

guard_cloudflared() {
  local idx="$1" t h
  parse_cloudflared
  (( T_HELP == 1 )) && return 0
  [[ -z "$T_SECRET_LIT" ]] || decide deny \
    "cloudflared $T_SECRET_LIT is given a literal value; a tunnel token runs the tunnel for anyone who has it, and it is now in the transcript - rotate it. Pass it from the environment instead: opgate exec TUNNEL_TOKEN=op://... -- cloudflared tunnel run. See skills/cloudflare/references/secrets.md"
  if [[ "$T_CMD" == 'service install' && -n "${T_ARGS[0]:-}" ]] && is_literal "${T_ARGS[0]}"; then
    decide deny \
      "cloudflared service install is given a tunnel token written out on the command line; it is now in the transcript - rotate it. Install from a variable filled by opgate, and let the user run it (it needs root)."
  fi

  if [[ -z "$T_CMD" ]]; then
    if [[ -n "$T_URL" ]] && [[ -z "$T_FIRSTPOS" || ( "$T_FIRSTPOS" == tunnel && $T_NPOS -eq 1 ) ]]; then
      decide ask \
        "This starts a quick tunnel: it publishes '$T_URL' on a random public trycloudflare.com hostname, reachable by anyone, outside every zone and access policy. The user decides."
      return 0
    fi
    [[ -z "$T_FIRSTPOS" || "$T_FIRSTPOS" == tunnel && $T_NPOS -eq 1 ]] && return 0
    decide deny \
      "cfgate does not know 'cloudflared $T_FIRSTPOS ...', so it cannot tell whether it writes. If this is a new command, classify it in plugins/cloudflare/scripts/lib/tunnel.sh."
  fi

  case "$T_KIND" in
    local|read) return 0 ;;
    secret) secret_read "$idx" "'cloudflared $T_CMD'"; return 0 ;;
    cli) decide ask "'cloudflared $T_CMD' changes cloudflared's login, binary or system service, not a resource of any project. The user decides."; return 0 ;;
  esac

  need_project
  case "$T_TARGET" in
    tunnel)
      cfd_check_cert
      check_name tunnel "${T_ARGS[0]:-}" ;;
    tunnels)
      cfd_check_cert
      (( ${#T_ARGS[@]} > 0 )) || decide deny "'cloudflared $T_CMD' names no tunnel."
      for t in "${T_ARGS[@]}"; do cfd_check_tunnel_ref "$t"; done ;;
    run)
      # Running a connector writes no configuration, but it joins a tunnel: the
      # one named here, or the `tunnel:` of the config file it reads.
      t="${T_ARGS[0]:-}"
      if [[ -z "$t" ]]; then
        cfd_config_tunnel "$inv_cwd" || decide deny \
          "cfgate cannot read the config file '$T_CONFIG' to see which tunnel this connector joins. Name the tunnel: cloudflared tunnel run <name>."
        t="$CFD_RUN_TUNNEL"
      fi
      if [[ -n "$t" ]]; then cfd_check_tunnel_ref "$t"; fi ;;
    dns|lb)
      cfd_check_cert
      cfd_check_tunnel_ref "${T_ARGS[0]:-}"
      h="${T_ARGS[1]:-}"
      [[ -n "$h" ]] || decide deny "'cloudflared $T_CMD' names no hostname."
      check_host "tunnel hostname" "$h"
      [[ "$HOST_ZONE" == "$CERT_ZONE_NAME" ]] || decide deny \
        "Hostname '$h' is in zone $HOST_ZONE, but the origin certificate ($CFD_CERT) is for zone $CERT_ZONE_NAME. cloudflared creates the record inside the certificate's zone, so this would make '$h.$CERT_ZONE_NAME', not '$h'. Pass the certificate for $HOST_ZONE with --origincert."
      if (( T_OVERWRITE == 1 )); then
        decide ask "--overwrite-dns replaces whatever record '$h' points to now, which may be live traffic. The user confirms."
      fi
      [[ "$T_TARGET" == lb ]] && decide ask "'cloudflared tunnel route lb' creates or changes a load balancer and its pool, account-level and billed. The user confirms." ;;
    account)
      decide ask "'cloudflared $T_CMD' changes the account's private network routing, which belongs to no single project. The user decides." ;;
  esac
  note "cloudflared $T_CMD"
}

# --- cf, the Cloudflare CLI -----------------------------------------------------------
# cf resolves its account in this order: CLOUDFLARE_ACCOUNT_ID, accountId in the
# nearest cloudflare.config.ts, the account it saved for the project on an
# earlier command, then the only account the login reaches. It does NOT read a
# wrangler config's account_id. Every source present must be the project's
# account, and at least one must be: the last fallback is a guess.
cf_check_account() {
  local a v src found=0 cfg
  for a in ${SH_ASSIGNS[@]+"${SH_ASSIGNS[@]}"}; do
    case "$a" in
      CLOUDFLARE_ACCOUNT_ID=*)
        v=${a#CLOUDFLARE_ACCOUNT_ID=}
        is_literal "$v" || decide deny \
          "CLOUDFLARE_ACCOUNT_ID is set to '$v', a value the shell supplies at run time, so the account this cf write lands in cannot be verified. Write the id literally: CLOUDFLARE_ACCOUNT_ID=$CFG_ACCOUNT"
        [[ "$v" == "$CFG_ACCOUNT" ]] || decide deny \
          "CLOUDFLARE_ACCOUNT_ID=$v on the command line is not project '$CFG_PROJECT''s account ($CFG_ACCOUNT). This cf write would land in another account."
        found=1 ;;
    esac
  done
  if line_var_get CLOUDFLARE_ACCOUNT_ID exported; then
    [[ "$LV" == "$CFG_ACCOUNT" ]] || decide deny \
      "CLOUDFLARE_ACCOUNT_ID=$LV is exported earlier on this line and is not project '$CFG_PROJECT''s account ($CFG_ACCOUNT)."
    found=1
  fi
  if [[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
    [[ "$CLOUDFLARE_ACCOUNT_ID" == "$CFG_ACCOUNT" ]] || decide deny \
      "The environment sets CLOUDFLARE_ACCOUNT_ID=$CLOUDFLARE_ACCOUNT_ID, which is not project '$CFG_PROJECT''s account ($CFG_ACCOUNT)."
    found=1
  fi
  if cfg=$(cf_config_ts "$inv_cwd"); then
    if grep -q 'accountId' "$cfg" 2>/dev/null; then
      while IFS= read -r v; do
        [[ -n "$v" ]] || continue
        [[ "$v" == "$CFG_ACCOUNT" ]] || decide deny \
          "$cfg sets accountId $v, which is not project '$CFG_PROJECT''s account ($CFG_ACCOUNT)."
        found=1
      done <<< "$(grep -o 'accountId[^,}]*' "$cfg" | grep -o '[0-9a-f]\{32\}')"
      if (( ! found )); then
        decide deny \
          "$cfg sets accountId from code the guard cannot evaluate (a variable, process.env, the mode), so the account this cf write lands in is unknown. Write the id as a literal string there, or prefix the command: CLOUDFLARE_ACCOUNT_ID=$CFG_ACCOUNT cf ..."
      fi
    fi
  fi
  while IFS=$'\t' read -r src v; do
    [[ -n "$src" ]] || continue
    [[ "$v" == "$CFG_ACCOUNT" ]] || decide deny \
      "$src is the account cf saved for this directory, $v, which is not project '$CFG_PROJECT''s account ($CFG_ACCOUNT). Delete that file, or pin the account: CLOUDFLARE_ACCOUNT_ID=$CFG_ACCOUNT cf ..."
    found=1
  done <<< "$(cf_saved_accounts "$inv_cwd")"
  # cf loads .env and .env.local from the run directory, and with -m <mode> also
  # .env.<mode> and .env.<mode>.local.
  is_literal "${CF_MODE:-x}" || decide deny \
    "--mode is '$CF_MODE', a value the shell supplies at run time, so the guard cannot tell which .env.<mode> file sets this cf write's account. Write the mode literally."
  W_ENVFILES=(); W_ENV="$CF_MODE"
  while IFS=$'\t' read -r src v; do
    [[ -n "$src" ]] || continue
    [[ "$v" == "$CFG_ACCOUNT" ]] || decide deny \
      "$src sets CLOUDFLARE_ACCOUNT_ID=$v, which is not project '$CFG_PROJECT''s account ($CFG_ACCOUNT)."
    found=1
  done <<< "$(wr_envfile_accounts "$inv_cwd")"
  (( found )) || decide deny \
    "Nothing pins this cf write to project '$CFG_PROJECT''s account, so cf would use whichever account its login reaches. cf ignores the wrangler config's account_id. Prefix the command with CLOUDFLARE_ACCOUNT_ID=$CFG_ACCOUNT, or set accountId to $CFG_ACCOUNT in cloudflare.config.ts."
  note "account $CFG_ACCOUNT"
}

# The zone of a zone-scoped cf command: --zone/-z, else CLOUDFLARE_ZONE_ID. Either
# may be an id or a domain name. Sets CF_ZID; refuses anything else. A variable,
# not output: called as $(...), its refusal would vanish into the subshell.
cf_zone_id() {
  local z="$CF_ZONE" a src="--zone"
  if [[ -z "$z" ]]; then
    for a in ${SH_ASSIGNS[@]+"${SH_ASSIGNS[@]}"}; do
      case "$a" in CLOUDFLARE_ZONE_ID=*) z=${a#CLOUDFLARE_ZONE_ID=}; src="CLOUDFLARE_ZONE_ID" ;; esac
    done
  fi
  if [[ -z "$z" ]] && line_var_get CLOUDFLARE_ZONE_ID exported; then z="$LV"; src="CLOUDFLARE_ZONE_ID exported on this line"; fi
  if [[ -z "$z" && -n "${CLOUDFLARE_ZONE_ID:-}" ]]; then z="$CLOUDFLARE_ZONE_ID"; src="CLOUDFLARE_ZONE_ID"; fi
  [[ -n "$z" ]] || decide deny \
    "'cf $CF_CMD' acts on a zone, but no zone is given (--zone or CLOUDFLARE_ZONE_ID), so there is no way to tell whose zone it changes. Pass --zone <zone id or domain>."
  is_literal "$z" || decide deny \
    "The zone ($src) is '$z', a value the shell supplies at run time, so the guard cannot tell whose zone this changes. Write it literally."
  if [[ "$z" =~ ^[0-9a-fA-F]{32}$ ]]; then
    zone_id_is_ours "$z" || decide deny \
      "Zone id $z ($src) is not a zone of project '$CFG_PROJECT' ([${CFG_ZONE_NAMES[*]-}]). Its DNS, rules and settings belong to another project."
    CF_ZID="$z"; return 0
  fi
  local i=0 n
  n=$(lower "${z%.}")
  while (( i < ${#CFG_ZONE_NAMES[@]} )); do
    [[ "${CFG_ZONE_NAMES[i]}" == "$n" ]] && { CF_ZID="${CFG_ZONE_IDS[i]}"; return 0; }
    i=$((i + 1))
  done
  decide deny \
    "Zone $z ($src) is not a zone of project '$CFG_PROJECT' ([${CFG_ZONE_NAMES[*]-}]). Its DNS, rules and settings belong to another project."
}

guard_cf() {
  local idx="$1" a v path p named=0 t
  [[ -r "$CF_TABLE" ]] || decide deny \
    "cfgate: $CF_TABLE is missing, so cf commands cannot be classified. Regenerate it: python3 plugins/cloudflare/scripts/gen-cf-table.py <node_modules/cf>."
  parse_cf
  # A literal credential is in the transcript whether or not cf then runs.
  [[ -z "$CF_SECRET_LIT" ]] || decide deny \
    "$CF_SECRET_LIT is given a literal value on the command line; it lands in the transcript and the shell history and must be rotated. Pass it from a variable filled by opgate: opgate exec VAR=op://... -- cf ... $CF_SECRET_LIT \"\$VAR\". See skills/cloudflare/references/secrets.md"
  [[ -z "$CF_BADLEAD" ]] || decide deny \
    "cfgate cannot read 'cf $CF_BADLEAD ...': '$CF_BADLEAD' before the command path is not one of cf's global options, and cf would read the words after it differently from the guard. Put the command path first: cf <command> <subcommand> ... $CF_BADLEAD"
  (( CF_HELP == 1 )) && return 0
  # API requests carry the credential; a different base URL sends it elsewhere.
  for a in ${SH_ASSIGNS[@]+"${SH_ASSIGNS[@]}"}; do
    case "$a" in CLOUDFLARE_API_BASE_URL=*) v=${a#*=} ;; *) continue ;; esac
    [[ "$v" == https://api.cloudflare.com/* || "$v" == https://api.cloudflare.com ]] || decide deny \
      "CLOUDFLARE_API_BASE_URL='$v' sends every cf request, credential included, to an endpoint other than api.cloudflare.com. Remove it."
  done
  if line_var_get CLOUDFLARE_API_BASE_URL exported && [[ "$LV" != https://api.cloudflare.com* ]]; then
    decide deny "CLOUDFLARE_API_BASE_URL is exported on this line to '$LV', which sends cf's credential to another endpoint. Remove it."
  fi

  if [[ -z "$CF_CMD" ]]; then
    [[ -z "$CF_FIRSTPOS" ]] && return 0      # bare `cf`: prints help
    decide deny \
      "cfgate does not know 'cf $CF_FIRSTPOS ...' (a group without a subcommand prints help; anything else may be newer than the table). If this is a new cf command, regenerate plugins/cloudflare/scripts/lib/cf-commands.tsv with scripts/gen-cf-table.py."
  fi
  [[ -z "$CF_DUP" ]] || decide deny \
    "$CF_DUP is given more than once with different values; cf would use one of them and the guard cannot know which. Give it once."

  case "$CF_KIND" in
    local|read)
      case "$CF_API" in
        */token|*/token/*) secret_read "$idx" "'cf $CF_CMD'" ;;
      esac
      return 0 ;;
    secret) secret_read "$idx" "'cf $CF_CMD'"; return 0 ;;
    cli) decide ask "'cf $CF_CMD' changes cf's own login or profiles, not a resource of any project. The user decides."; return 0 ;;
    expose) decide ask "'cf $CF_CMD' publishes a local service on a random public hostname, reachable by anyone, outside every zone and access policy. The user decides."; return 0 ;;
  esac
  (( CF_DRYRUN == 1 )) && { note "cf $CF_CMD (dry run)"; return 0; }

  # --- a write that reaches the account ---
  case "$SH_VIA" in
    npx|bunx|dlx|npm-exec)
      decide deny \
        "'$SH_VIA cf' may silently download and run a different cf than the project pins, and this command writes. Run the installed cf (cf, or ./node_modules/.bin/cf)." ;;
  esac
  need_project
  cf_check_account

  case "$CF_KIND" in
    account)
      decide ask "'cf $CF_CMD' changes account-level state that belongs to no single project. The user decides."; return 0 ;;
    project)
      cf_opt worker && check_name Worker "$CF_V"
      cf_opt dispatch-namespace && check_name "dispatch namespace" "$CF_V"
      decide ask \
        "'cf $CF_CMD' deploys what cloudflare.config.ts describes, and that file is code the guard cannot evaluate (the Worker name, routes and bindings may depend on --mode or the environment). Run 'cf $CF_CMD --dry-run' first and check the Worker and bindings it prints; then the user confirms."
      return 0 ;;
    d1id)
      decide ask "'cf $CF_CMD ${CF_ARGV[*]-}' addresses a D1 database by id, which says nothing about which project owns it. The user confirms the database."
      return 0 ;;
    tunnelrun)
      t="${CF_ARGV[0]:-}"
      [[ -n "$t" ]] && cfd_check_tunnel_ref "$t"
      return 0 ;;
    write) ;;
    *) decide deny "cfgate: unknown kind '$CF_KIND' for 'cf $CF_CMD' in $CF_TABLE." ;;
  esac

  # Fill the API path template from the command line.
  path=${CF_API#/}
  case "$path" in
    *'{account_or_zone}'*|*'{account_or_zone_id}'*)
      decide ask "'cf $CF_CMD' sends $CF_METHOD /$path, which targets the account or a zone depending on how cf resolves it at run time; the guard cannot tell which, or whose. The user confirms."
      return 0 ;;
  esac
  if [[ "$path" == *'{zone_id}'* || "$path" == *'{zone_identifier}'* ]]; then
    cf_zone_id
    path=${path//\{zone_id\}/$CF_ZID}; path=${path//\{zone_identifier\}/$CF_ZID}
  fi
  path=${path//\{account_id\}/$CFG_ACCOUNT}
  while [[ "$path" =~ \{([A-Za-z0-9_]+)\} ]]; do
    p=${BASH_REMATCH[1]}
    cf_param "$p" || decide deny \
      "'cf $CF_CMD' sends $CF_METHOD $CF_API, and the guard cannot find the value of {$p} on the command line, so it cannot tell what this changes. Pass it explicitly."
    is_literal "$CF_V" || decide deny \
      "{$p} of 'cf $CF_CMD' is given as '$CF_V', a value the shell supplies at run time, so the guard cannot verify whose resource this changes. Write it literally."
    [[ "$CF_V" != */* && "$CF_V" != *..* ]] || decide deny \
      "{$p} of 'cf $CF_CMD' is '$CF_V'; a slash or dot segment in a path parameter changes which resource the request reaches."
    path=${path//\{$p\}/$CF_V}
  done

  # An account-level create names its new resource in an option, not in the
  # path. (Inside a zone - a DNS record, a rule - the zone is the boundary.)
  if [[ "$CF_CATEGORY" == create && "$path" == accounts/* ]]; then
    if cf_create_name; then
      check_name "$(cf_label "$path")" "$CF_V"; named=1
    elif [[ -n "$CF_BODY" ]]; then
      decide ask "'cf $CF_CMD' takes the new resource's name from --body, which the guard does not parse. Use the command's own name option, or the user confirms."
    fi
  fi
  check_api_write "$CF_METHOD" "$path" "$named"
  note "cf $CF_CMD"
}

# What a create's collection path holds, in words a refusal can use.
cf_label() {
  case "$1" in
    */r2/buckets*) printf 'R2 bucket' ;;
    */storage/kv/namespaces*) printf 'KV namespace' ;;
    */d1/database*) printf 'D1 database' ;;
    */queues*) printf 'queue' ;;
    */pages/projects*) printf 'Pages project' ;;
    */workers/scripts*|*/workers/workers*) printf 'Worker' ;;
    */cfd_tunnel*|*/tunnels*) printf 'tunnel' ;;
    */vectorize/*) printf 'Vectorize index' ;;
    */hyperdrive/*) printf 'Hyperdrive config' ;;
    */workflows*) printf 'workflow' ;;
    *) printf 'resource' ;;
  esac
}

# --- the REST API through curl -------------------------------------------------------
# One curl call can hold several transfers (--next / -:), each with its own
# method and URLs; each is checked on its own.
guard_curl() {
  local idx="$1" from j n=${#SH_WORDS[@]}
  from=$((SH_START + 1)); j=$from
  while (( j <= n )); do
    if (( j == n )) || [[ "${SH_WORDS[j]}" == --next || "${SH_WORDS[j]}" == -: ]]; then
      guard_curl_transfer "$idx" "$from" "$j"
      from=$((j + 1))
    fi
    j=$((j + 1))
  done
}

guard_curl_transfer() {
  local idx="$1" u p a0 a1 a2 a3 z g x write=0
  parse_curl "$2" "$3"
  [[ "$C_METHOD" == GET || "$C_METHOD" == HEAD ]] || write=1
  # A URL the shell builds: resolve what this line assigned, refuse what is left
  # when the call writes - "$API/zones/$Z/..." could point anywhere.
  for u in ${C_DYN_URLS[@]+"${C_DYN_URLS[@]}"}; do
    x=$(expand_line_vars "$u")
    if [[ "$x" != *'$'* && "$x" != *'`'* ]]; then
      case "$(cf_url_kind "$x")" in
        api) C_URLS[${#C_URLS[@]}]="$x" ;;
        odd) C_ODD_URLS[${#C_ODD_URLS[@]}]="$x" ;;
      esac
    elif (( write )); then
      decide deny \
        "This $C_METHOD sends curl to '$u', a URL the shell builds from variables this command line does not set, so the guard cannot tell whether it changes Cloudflare - or whose zone. Write the URL literally: https://api.cloudflare.com/client/v4/zones/<zone id>/..."
    fi
  done
  if (( write )); then
    for u in ${C_ODD_URLS[@]+"${C_ODD_URLS[@]}"}; do
      case "$u" in
        *[{}\[\]]*) decide deny \
          "curl expands '$u' with URL globbing ({...} or [...]), so the guard cannot tell which hosts and paths this $C_METHOD reaches. Write one literal URL per transfer, or add -g." ;;
        *) decide ask "'$u' mentions Cloudflare but is not api.cloudflare.com, so the guard cannot classify this $C_METHOD. The user decides." ;;
      esac
    done
  fi
  (( ${#C_URLS[@]} > 0 )) || return 0
  [[ -z "$C_SECRET_LIT" ]] || decide deny \
    "This curl call to the Cloudflare API carries $C_SECRET_LIT; the credential is now in the transcript and must be rotated. Reference it from the environment: -H \"Authorization: Bearer \$CLOUDFLARE_API_TOKEN\", with the variable filled by opgate. See skills/cloudflare/references/secrets.md"
  (( C_CONFIG == 0 )) || decide ask \
    "This curl call reads options from a file (-K/--config), which may set the method, URL or credentials out of the guard's sight. The user decides."
  if (( write && C_TARGET )); then
    decide deny "This $C_METHOD to the Cloudflare API uses --request-target, which replaces the path curl sends, so the URL the guard reads is not the one that is changed. Drop --request-target."
  fi

  for u in "${C_URLS[@]}"; do
    p=$(api_path "$u") || { (( write )) && decide ask "'$u' is on api.cloudflare.com but not under /client/v4, so the guard cannot classify it. The user decides."; continue; }
    # GraphQL is POST, and it only reads (analytics).
    [[ "$p" == graphql ]] && continue

    if (( ! write )); then
      case "$p" in
        */cfd_tunnel/*/token|*/warp_connector/*/token) secret_read "$idx" "GET /$p" ;;
      esac
      continue
    fi

    check_api_write "$C_METHOD" "$p"
  done
}

# check_api_write <method> <path after /client/v4/> [named] — the boundary for
# one API write, shared by curl and cf. named=1 when the caller already checked
# the name a create gives its new resource, so a collection path that names
# nothing is not a reason to ask.
check_api_write() {
  local method="$1" p="$2" named="${3:-0}" a0 a1 a2 a3 z g
  path_is_unnormalised "$p" && decide deny \
    "The path /client/v4/$p has a dot segment, an encoded separator or an empty segment; curl normalises it before sending, so /zones/<ours>/../<theirs>/ reaches <theirs>. Write the plain path."
  IFS=/ read -r a0 a1 a2 a3 _ <<< "$p"
  need_project
  case "$a0" in
    zones)
      if [[ -z "$a1" ]]; then
        decide ask "$method /zones creates a zone on the account. The user decides."; return 0
      fi
      z=$(zone_name_of_id "$a1") || decide deny \
        "Zone id $a1 is not a zone of project '$CFG_PROJECT' ([${CFG_ZONE_NAMES[*]-}]). Its DNS, rules and settings belong to another project."
      if [[ -z "$a2" ]]; then
        decide ask "$method on zone $z itself changes or deletes the whole zone. The user confirms."
      elif g=$(protected_match "$z"); then
        decide ask "Zone $z is protected in .cloudflare/project.json (matches '$g'). $method /$p passed every other check; the user confirms."
      fi
      note "API $method zone $z" ;;
    accounts)
      [[ "$a1" == "$CFG_ACCOUNT" ]] || decide deny \
        "Account $a1 is not project '$CFG_PROJECT''s account ($CFG_ACCOUNT)."
      case "$a2" in
        ''|members|roles|subscriptions|billing|audit_logs|organizations|custom_pages)
          decide deny "$method /accounts/$a1${a2:+/$a2} changes the account itself (members, billing, settings), which belongs to no project. Let the user do it in the dashboard." ;;
        tokens)
          decide ask "$method /accounts/$a1/tokens creates or changes an API token. A created token's value comes back in the response, so send it to opgate, not the transcript. The user decides." ;;
        workers)
          if [[ "$a3" == scripts ]]; then
            IFS=/ read -r _ _ _ _ a3 _ <<< "$p"
            if [[ -n "$a3" ]]; then check_name Worker "$a3"
            elif (( ! named )); then decide ask "$method /$p does not name a Worker in its path. The user decides."; fi
          elif (( ! named )); then
            decide ask "$method /$p changes Workers settings the path does not attribute to a project. The user decides."
          fi ;;
        r2|pages)
          IFS=/ read -r _ _ _ a3 g _ <<< "$p"
          if [[ "$a3" == buckets && -n "$g" ]]; then check_name "R2 bucket" "$g"
          elif [[ "$a3" == projects && -n "$g" ]]; then check_name "Pages project" "$g"
          elif (( ! named )); then decide ask "$method /$p does not name its target in the path. The user decides."; fi ;;
        *)
          (( named )) || decide ask "$method /$p addresses its target by id or not at all; an id says nothing about which project owns it. The account is the project's; the user confirms the target." ;;
      esac
      note "API $method account $a2" ;;
    user)
      if [[ "$a1" == tokens ]]; then
        decide ask "$method /user/tokens creates or changes an API token. A created token's value comes back in the response, so send it to opgate, not the transcript. The user decides."
      else
        decide deny "$method /$p changes the Cloudflare user profile, which belongs to no project. Let the user do it."
      fi ;;
    *)
      decide deny "cfgate does not know how to attribute $method /client/v4/$p to a project. If it is needed, let the user run it, or extend plugins/cloudflare/scripts/guard-cloudflare.sh." ;;
  esac
}

# --- credentials written on the line, in any segment --------------------------------
check_literal_creds() {
  local w v n
  for w in ${SH_WORDS[@]+"${SH_WORDS[@]}"}; do
    case "$w" in
      CLOUDFLARE_API_TOKEN=*|CLOUDFLARE_API_KEY=*|CF_API_TOKEN=*|CF_API_KEY=*|TUNNEL_TOKEN=*|CLOUDFLARE_ACCESS_CLIENT_SECRET=*)
        n=${w%%=*}; v=${w#*=}
        # An op:// reference names a secret in 1Password; it is not the secret.
        [[ "$v" == op://* ]] && continue
        is_literal "$v" && decide deny \
          "$n is set to a literal value on the command line; it is now in the transcript and must be rotated. Reference it instead: opgate exec $n=op://<vault>/<item>/<field> -- <command>. See skills/cloudflare/references/secrets.md" ;;
    esac
  done
}

# --- the shell around the tools ------------------------------------------------------

# A segment made only of assignments (API=https://...; export X=...) defines
# variables for what follows on the line. A value the shell computes is
# recorded as unknown (`$?`).
track_assignments() {
  local w first=1 exported=0
  for w in "${SH_WORDS[@]}"; do
    if (( first )) && [[ "$w" == export ]]; then exported=1; first=0; continue; fi
    first=0
    [[ "$w" =~ $_sh_re_assign ]] || return 0
  done
  for w in "${SH_WORDS[@]}"; do
    [[ "$w" =~ $_sh_re_assign ]] || continue
    if is_literal "${w#*=}"; then line_var_set "${w%%=*}" "${w#*=}" $exported
    else line_var_set "${w%%=*}" '$?' $exported; fi
  done
}

# cd, pushd and popd move the directory for what follows - unless they run in a
# pipeline stage, which is a subshell. A target the guard cannot read makes the
# directory unknown ("?"), and every later write that depends on it is refused.
track_cd() {
  local idx="$1" i=0 n=${#SH_WORDS[@]} w head target=""
  while (( i < n )); do
    w=${SH_WORDS[i]}
    if [[ "$w" =~ $_sh_re_assign || "$w" == command || "$w" == builtin ]]; then i=$((i + 1)); continue; fi
    break
  done
  head=${SH_WORDS[i]:-}
  case "$head" in cd|pushd|popd) ;; *) return 0 ;; esac
  [[ "${seg_piped[idx]}" == 1 || "${seg_fed[idx]}" -ge 0 ]] && return 0
  [[ "$head" == popd ]] && { eff_cwd="?"; return 0; }
  i=$((i + 1))
  while (( i < n )); do
    w=${SH_WORDS[i]}
    case "$w" in
      --) target="${SH_WORDS[i+1]:-}"; break ;;
      -) target=-; break ;;
      -*|+*) [[ "$head" == pushd ]] && { target=-; break; }; i=$((i + 1)); continue ;;
      *) target="$w"; break ;;
    esac
  done
  target=$(expand_line_vars "$target")
  case "$target" in
    '') eff_cwd="${HOME:-?}" ;;
    -|*'$'*|*'`'*) eff_cwd="?" ;;
    '~'|'~/'*) eff_cwd="${HOME:-/}${target#\~}" ;;
    /*) eff_cwd="$target" ;;
    *) [[ "$eff_cwd" == "?" ]] || eff_cwd="$eff_cwd/$target" ;;
  esac
}

# The directory one invocation runs in: the line's, moved by a wrapper's own
# -C/--chdir/--cwd (env -C, sudo -D, pnpm -C, yarn --cwd).
set_inv_cwd() {
  local t
  inv_cwd="$eff_cwd"
  [[ -n "$SH_CHDIR" ]] || return 0
  t=$(expand_line_vars "$SH_CHDIR")
  if ! is_literal "$t"; then inv_cwd="?"; return 0; fi
  case "$t" in
    '~'|'~/'*) inv_cwd="${HOME:-/}${t#\~}" ;;
    /*) inv_cwd="$t" ;;
    *) [[ "$inv_cwd" == "?" ]] || inv_cwd="$inv_cwd/$t" ;;
  esac
}

# check_line <command line> <nesting level> — every segment, in order. A nested
# script (bash -c, eval, a heredoc fed to a shell) is checked in place, with the
# directory it starts in, and cannot move the directory of what follows it.
check_line() {
  local line="$1" level="$2"
  (( level <= 8 )) || decide deny \
    "cfgate: scripts nested more than 8 levels deep (bash -c inside bash -c ...) cannot be verified. Run the inner command directly."
  local -a segs=() seg_stdout=() seg_piped=() seg_stdin=() seg_fed=() seg_cap=() seg_gid=() seg_kids=() seg_depth=() seg_hd=()
  local -a dcwd=()
  local idx=-1 segment rc prev_d=0 d k saved body fed w script
  sh_split "$line"
  if (( level == 0 )); then
    # A non-empty command always lexes to at least one segment plus the last one.
    (( ${#segs[@]} >= 2 )) || decide deny \
      "cfgate: could not split the command line into commands (awk or here-string failed), so nothing could be verified."
  fi
  for segment in "${segs[@]}"; do
    idx=$((idx + 1))
    # Leaving a ( ) subshell restores the directory it started in.
    d=${seg_depth[idx]:-0}
    if (( d > prev_d )); then
      k=$((prev_d + 1)); while (( k <= d )); do dcwd[k]="$eff_cwd"; k=$((k + 1)); done
    elif (( d < prev_d )); then
      eff_cwd="${dcwd[d+1]:-$eff_cwd}"
    fi
    prev_d=$d
    sh_words "$segment"
    (( ${#SH_WORDS[@]} > 0 )) || continue
    check_literal_creds
    sh_scan
    rc=$?
    case $rc in
      1)
        track_assignments
        track_cd "$idx"
        sh_words "$segment"
        if sh_head; then
          case "$SH_HEAD" in
            wget|http|https|xh)
              case "$(printf '%s' "$segment" | tr '[:upper:]' '[:lower:]')" in *api.cloudflare.com*)
                decide ask "'$SH_HEAD' calls the Cloudflare API, and cfgate only reads curl. Use curl so the call can be verified, or the user confirms." ;;
              esac ;;
          esac
        fi
        continue ;;
      2)
        # VAR=value in front of `bash -c`, `env`, `sudo` reaches the script's
        # commands as an exported variable - for that script only.
        saved="$eff_cwd"
        local -a sv_n=(${LINE_VAR_NAMES[@]+"${LINE_VAR_NAMES[@]}"}) sv_v=(${LINE_VAR_VALUES[@]+"${LINE_VAR_VALUES[@]}"}) sv_e=(${LINE_VAR_EXPORTED[@]+"${LINE_VAR_EXPORTED[@]}"})
        for w in ${SH_ASSIGNS[@]+"${SH_ASSIGNS[@]}"}; do
          if is_literal "${w#*=}"; then line_var_set "${w%%=*}" "${w#*=}" 1
          else line_var_set "${w%%=*}" '$?' 1; fi
        done
        check_line "$SH_NESTED" $((level + 1))
        LINE_VAR_NAMES=(${sv_n[@]+"${sv_n[@]}"}); LINE_VAR_VALUES=(${sv_v[@]+"${sv_v[@]}"}); LINE_VAR_EXPORTED=(${sv_e[@]+"${sv_e[@]}"})
        eff_cwd="$saved"
        continue ;;
      3)
        decide ask \
          "'$SH_HEAD_UNKNOWN' precedes a Cloudflare CLI on this line, and cfgate does not know whether it executes what follows - if it does (find -exec, a task runner), the guard is being bypassed. If it only reads that text as data, confirm; if it runs the CLI, run the CLI directly so cfgate can check it."
        continue ;;
      4)
        (( LINE_MENTIONS )) && decide ask \
          "The command name comes from the shell ('$SH_HEAD_UNKNOWN'), on a line that mentions a Cloudflare CLI, so cfgate cannot tell what runs. Write the command name literally (wrangler, ./node_modules/.bin/wrangler) so it can be checked."
        continue ;;
      5)
        # A shell that reads its script from standard input.
        saved="$eff_cwd"
        if [[ -n "${seg_hd[idx]}" ]]; then
          body=${seg_hd[idx]//$'\001'/$'\n'}
          check_line "$body" $((level + 1))
        elif (( ${seg_fed[idx]} >= 0 )); then
          fed=${seg_fed[idx]}
          sh_words "${segs[fed]}"; sh_head
          case "$SH_HEAD" in
            echo|printf)
              script=""
              for w in "${SH_WORDS[@]}"; do
                [[ "$w" =~ $_sh_re_assign || "${w##*/}" == "$SH_HEAD" ]] && continue
                [[ "$SH_HEAD" == echo && "$w" == -[neE]* ]] && continue
                script="$script $w"
              done
              check_line "${script# }" $((level + 1)) ;;
            *)
              (( LINE_MENTIONS )) && decide ask \
                "A shell here reads its script from standard input ('$SH_HEAD ... | sh'), on a line that mentions a Cloudflare CLI, so cfgate cannot see the commands it runs. Run them directly so they can be checked." ;;
          esac
        elif [[ "${seg_stdin[idx]}" == stdin ]]; then
          (( LINE_MENTIONS )) && decide ask \
            "A shell here reads its script from a file on standard input, on a line that mentions a Cloudflare CLI, so cfgate cannot see the commands it runs. Run them directly so they can be checked."
        fi
        eff_cwd="$saved"
        continue ;;
    esac
    set_inv_cwd
    case "$SH_TOOL" in
      wrangler)    guard_wrangler "$idx" ;;
      cloudflared) guard_cloudflared "$idx" ;;
      curl)        guard_curl "$idx" ;;
      cf)          guard_cf "$idx" ;;
    esac
  done
}

check_line "$command_line" 0

if [[ -n "$pending_ask" ]]; then
  guard_done=1; emit ask "$pending_ask"; exit 0
fi
guard_done=1
if [[ "${CFGATE_DEBUG:-}" == 1 && -n "$checked" ]]; then
  emit allow "cfgate checked: $checked"
fi
exit 0
