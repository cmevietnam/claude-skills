#!/usr/bin/env bash
# PreToolUse(Bash) guard.
#
# One job: keep every WRITE to Linode inside two boundaries at once — the project
# tag that says who owns a resource, and the env tag that says which deployment
# it is. Reads are none of its business; you cannot break production by listing
# it, and a guard that fights reads only teaches you to work around it.
#
# It fails closed on everything it can control: an unknown id, an API error, an
# action it has never heard of, a wrapper it does not recognise, or an internal
# error in this script itself all end in a refusal or a prompt. It cannot fail
# closed on the one thing outside its control — if the whole hook exceeds its
# timeout, Claude Code discards the decision and the command proceeds. That is
# why API lookups share one budget well inside that timeout; see
# references/guard-rules.md, which states the limit plainly.
#
# No dependencies beyond bash, awk and linode-cli itself.

LINGATE_T0=$(date +%s)
payload=$(cat)

# Fast path: nothing of interest, get out before doing any real work. Every Bash
# call in the session pays for this script's startup. `lin` is a real alias of
# linode-cli, so a whole-word match for it is checked too.
case "$payload" in
  *linode*) ;;
  *lin*) printf '%s' "$payload" | grep -Eq '(^|[^A-Za-z0-9_.-])lin([^A-Za-z0-9_.-]|$)' || exit 0 ;;
  *) exit 0 ;;
esac

emit() {
  # $1 = allow|deny|ask, $2 = reason.
  #
  # The reason interpolates tags, labels and command fragments that come from the
  # API and from the command line, so it can contain a quote or a backslash. This
  # JSON is hand-built, and invalid output is treated as no decision at all —
  # which means the write proceeds. Stripping here is what keeps a resource named
  # `web "prod"` from switching the guard off.
  local reason
  reason=$(printf '%s' "$2" | tr -d '\000-\037' | tr '\\"' '  ')
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"%s","permissionDecisionReason":"%s"}}\n' "$1" "$reason"
}

# From here on the payload mentions Linode, so falling over silently would mean
# letting a write through. Anything that reaches EXIT without a decision refuses.
guard_done=0
trap '[[ $guard_done -eq 1 ]] || emit deny "lingate: the hook hit an internal error and could not verify which project/env this command touches. This refusal is deliberate (fail closed). Run: bash plugins/linode/scripts/test-guard.sh to see what broke."' EXIT

# `ask` is remembered, not issued: a later segment on the same line may still
# deserve a refusal, and a refusal outranks a prompt. Only deny exits early.
pending_ask=""
decide() {
  if [[ "$1" == ask ]]; then
    [[ -n "$pending_ask" ]] || pending_ask="$2"
    return 0
  fi
  guard_done=1; emit "$1" "$2"; exit 0
}

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)
for f in "$here/lib/common.sh" "$here/lib/linode.sh"; do
  [[ -r "$f" ]] || decide deny \
    "lingate: $f is missing, so the guard cannot run. Reinstall the plugin or run 'claude plugin validate ./plugins/linode'."
done
# shellcheck source=lib/common.sh
. "$here/lib/common.sh" 2>/dev/null
# shellcheck source=lib/linode.sh
. "$here/lib/linode.sh" 2>/dev/null
# A library that failed to parse leaves these undefined; without this check the
# script would fall through to "nothing to guard" and let the write go.
type lin_split_all >/dev/null 2>&1 && type json_str_file >/dev/null 2>&1 || decide deny \
  "lingate: scripts/lib/*.sh failed to load (syntax error?). Run: bash -n plugins/linode/scripts/lib/common.sh plugins/linode/scripts/lib/linode.sh"

if [[ "$LINGATE_GUARD" == off ]]; then guard_done=1; exit 0; fi

# bash 3.2 backs every here-string with a temp file. If that cannot be created
# (TMPDIR gone, disk full) the parsing loops below silently never run, and an
# empty set of segments would read as "nothing to guard". Prove it works first.
_probe=""
read -r _probe <<< "probe" 2>/dev/null
[[ "$_probe" == probe ]] || decide deny \
  "lingate: cannot create the temp file a here-string needs (TMPDIR=${TMPDIR:-/tmp} is full or not writable), so the command cannot be parsed. Free up TMPDIR and retry."

command_line=$(hook_command "$payload")
if [[ -z "$command_line" ]]; then
  case "$payload" in
    *'"command"'*) decide deny "lingate: the payload has a command field but its contents could not be read, so the command cannot be verified. Check jq/awk on this machine." ;;
  esac
  guard_done=1; exit 0
fi

# Where the command runs. The Bash tool reports its cwd in the payload; that is
# the directory whose .linode/project.json applies, not the one Claude Code was
# launched from. A `cd` inside the command moves it again.
eff_cwd=$(payload_str "$payload" '.cwd' 'cwd')
[[ -n "$eff_cwd" ]] || eff_cwd="${CLAUDE_PROJECT_DIR:-$PWD}"

# --- split the command line into real invocations ---------------------------
lin_split_all "$command_line"
# A non-empty command always lexes to at least one token plus the trailing
# newline, i.e. two segments. Fewer means the lexer or its read loop failed.
(( ${#segs[@]} >= 2 )) || decide deny \
  "lingate: could not split the command line into commands (awk or here-string failed), so nothing could be verified."

# Project identity, resolved when a write needs it, per working directory.
proj_root=""; proj_tag=""; proj_envs=""; proj_default_env=""; proj_protected=""
proj_shared=""; proj_for_cwd=""
need_project() {
  [[ -n "$proj_tag" && "$proj_for_cwd" == "$eff_cwd" ]] && return 0
  proj_for_cwd="$eff_cwd"
  proj_root=$(find_project_root "$eff_cwd") || decide deny \
    "No .linode/project.json found from $eff_cwd upward, so there is no way to tell which project the target resource belongs to. Run 'lingate init <tag>' at the repo root first (e.g. lingate init cme), then retry. See: skills/linode/references/project-setup.md"
  proj_tag=$(json_str_file "$proj_root/$LINGATE_CONFIG" tag)
  [[ -n "$proj_tag" ]] || decide deny \
    "$proj_root/$LINGATE_CONFIG has no 'tag' field. Fix it or run 'lingate init <tag>' to recreate it."
  proj_envs=$(json_arr_file "$proj_root/$LINGATE_CONFIG" envs | tr '\n' ' ')
  proj_envs=${proj_envs% }
  proj_protected=$(json_arr_file "$proj_root/$LINGATE_CONFIG" protectedEnvs | tr '\n' ' ')
  proj_protected=${proj_protected% }
  proj_default_env=$(json_str_file "$proj_root/$LINGATE_CONFIG" defaultEnv)
  proj_shared=$(json_bool_file "$proj_root/$LINGATE_CONFIG" allowSharedEnvs)
}

cur_env=""
lookup_fresh=0

# One resource, one environment — that is the target state, and the guard says so
# by default. A project may declare `allowSharedEnvs` when one box deliberately
# serves two environments to save money; then the write is permitted, but never
# silently: if any of the OTHER environments it serves is protected, a human
# confirms every time. Sharing dev with staging costs nothing and prompts nothing;
# sharing anything with prod prompts always.
# env_verdict <subject> <env>...
env_verdict() {
  local subject="$1" e other=""
  shift
  local -a renv=("$@")

  if (( ${#renv[@]} == 0 )); then
    decide deny \
      "$subject carries none of the env tags [$proj_envs], so its environment is unknown - and a write that is blind to environment is the classic way to change prod by mistake. Assign an env first: lingate adopt <group> <id> --env <env> --yes"
  fi
  tags_contain "$cur_env" "${renv[@]}" || decide deny \
    "CROSS-ENV: $subject lives in env '${renv[*]}' but this command runs in env '$cur_env'. lingate never guesses intent between two environments. If you really mean '${renv[0]}', say so on the command line: LINODE_ENV=${renv[0]} linode-cli $LIN_GROUP $LIN_ACTION ... - and ask the user first if that env is protected."

  (( ${#renv[@]} > 1 )) || return 0

  for e in "${renv[@]}"; do
    [[ "$e" == "$cur_env" ]] && continue
    other="$other $e"
  done
  other=${other# }

  if [[ "$proj_shared" != true ]]; then
    decide deny \
      "$subject carries several env tags at once: ${renv[*]}. A resource belongs to one environment. If this is deliberate - one box serving both envs to save cost - declare it in .linode/project.json: allowSharedEnvs = true; lingate will then allow it but still ask before every write when the other env is protected."
  fi

  for e in $other; do
    case " $proj_protected " in
      *" $e "*)
        decide ask \
          "$subject is shared between environments: ${renv[*]}. This command runs in '$cur_env', but the same resource also serves the protected env '$e' - any change here reaches $e immediately. Command: 'linode-cli $LIN_GROUP $LIN_ACTION ${LIN_IDS[*]-}'. The user confirms."
        ;;
    esac
  done
  return 0
}

# A resource must be in the project AND in the environment this command is aimed
# at. Crossing either line is a refusal, not a prompt.
check_owner() {
  # $1 = group, $2 = id, $3 = extra wording for the message
  local g="$1" rid="$2" what="$3" tags_out t e src="" og="$g" oid="$rid" hdr
  tags_out=$(resolve_tags "$g" "$rid" "$lookup_fresh") || decide deny \
    "Could not read the tags of $g $rid within the $LINGATE_BUDGET s budget (linode-cli failed, the id does not exist, the network is slow, or earlier lookups used up the time). When ownership is uncertain lingate refuses rather than guesses. Check with: linode-cli $g $(view_action_for "$g") $rid --json"

  # First line names the resource whose tags were actually read: for an untagged
  # LKE worker that is its cluster, and the message should point there.
  hdr=${tags_out%%$'\n'*}
  case "$hdr" in
    @*) tags_out=${tags_out#*$'\n'}; [[ "$tags_out" == "$hdr" ]] && tags_out=""
        og=${hdr#@}; oid=${og#*/}; og=${og%%/*} ;;
  esac
  if [[ "$og $oid" != "$g $rid" ]]; then
    src=" (it is a worker node of $og $oid and carries no tags of its own, so ownership follows the cluster)"
  fi

  local -a tags=()
  while IFS= read -r t; do [[ -n "$t" ]] && tags[${#tags[@]}]="$t"; done <<< "$tags_out"

  if (( ${#tags[@]} == 0 )); then
    decide deny \
      "$what $g $rid carries no tags$src, so it belongs to no project and lingate will not write to it. If it is an older resource of project '$proj_tag', adopt it: lingate adopt $og $oid --env $cur_env --yes (ask the user first). All untagged resources: lingate orphans"
  fi
  tags_contain "$proj_tag" "${tags[@]}" || decide deny \
    "$what $g $rid carries tags '${tags[*]}'$src, not '$proj_tag' - it belongs to another project. This is the hard boundary of this plugin: no writes to another project's resources, no exceptions. This project's resources: linode-cli $g list --tags $proj_tag"

  [[ -n "$proj_envs" ]] || return 0

  local -a renv=()
  while IFS= read -r e; do [[ -n "$e" ]] && renv[${#renv[@]}]="$e"; done \
    <<< "$(env_of_tags "$proj_envs" "${tags[@]}")"
  env_verdict "$what $g $rid$src" ${renv[@]+"${renv[@]}"}
}

# A ledger-backed resource: the repo's own record says who owns it.
check_ledger() {
  # $1 = group, $2 = id, $3 = extra wording
  local g="$1" rid="$2" what="$3"
  ledger_is_ours "$proj_root" "$proj_tag" || decide deny \
    "$proj_root/$LINGATE_LEDGER declares project '$(json_str_file "$proj_root/$LINGATE_LEDGER" tag)', not '$proj_tag'. A ledger only speaks for its own project. Run 'lingate init $proj_tag' - it sets the old ledger aside and creates a new one."
  ledger_has "$proj_root" "$proj_tag" "$g" "$rid" || decide deny \
    "$what $g $rid is not in the ownership ledger .linode/owned.json of project '$proj_tag'. If it really belongs to the project, record it with 'lingate own $g $rid --env $cur_env' and retry. If not, leave it alone."
  [[ -n "$proj_envs" ]] || return 0
  local -a lenv=()
  local e
  while IFS= read -r e; do [[ -n "$e" ]] && lenv[${#lenv[@]}]="$e"; done \
    <<< "$(ledger_envs_of "$proj_root" "$proj_tag" "$g" "$rid")"
  env_verdict "$what $g $rid (per the ledger)" ${lenv[@]+"${lenv[@]}"}
}

# Whichever source of truth applies to the group.
check_target() {
  case "$(group_scope "$1")" in
    taggable) check_owner "$1" "$2" "$3" ;;
    ledger)   check_ledger "$1" "$2" "$3" ;;
    *)        decide deny "No way to verify ownership of $1 $2." ;;
  esac
}

# Every extra resource the command names — the Linode a volume attaches to, a
# firewall device, the VPC an interface joins — is being written to as well.
check_refs() {
  local i=0
  if (( ${#LIN_BAD_REFS[@]} > 0 )); then
    decide deny \
      "This command points at another resource through a value lingate cannot read: '${LIN_BAD_REFS[0]}' (a shell variable or a JSON list). Unreadable means unverifiable. Write the id literally on the command line."
  fi
  while (( i < ${#LIN_REF_GROUPS[@]} )); do
    check_target "${LIN_REF_GROUPS[i]}" "${LIN_REF_IDS[i]}" "Target resource"
    i=$((i + 1))
  done
}

# Everything above has said yes. In a protected environment that is still not
# enough: a human confirms.
protected_gate() {
  case " $proj_protected " in
    *" $cur_env "*)
      decide ask \
        "Env '$cur_env' is marked protected in .linode/project.json. Write: 'linode-cli $LIN_GROUP $LIN_ACTION ${LIN_IDS[*]-}'. Every project and env check has passed - only the user's confirmation that this is what they want on $cur_env remains."
      ;;
  esac
}

# Does this segment's standard output end up somewhere other than the
# transcript? Follow the pipeline to its last stage: a file redirect there, or a
# stage that is `opgate` (put), counts; anything else — including a pipe into a
# command that itself prints — does not.
stdout_is_kept_private() {
  local j="$1"
  while (( j < ${#segs[@]} )) && [[ "${seg_piped[j]}" == 1 ]]; do j=$((j + 1)); done
  (( j < ${#segs[@]} )) || return 1
  [[ "${seg_stdout[j]}" == 1 ]] && return 0
  lin_words "${segs[j]}"
  lin_head && [[ "$LIN_HEAD" == opgate ]]
}

# How many linode invocations does this one Bash call contain? A ledger create
# must be alone: the PostToolUse hook reads the id out of the call's stdout, and
# any other invocation's output in the same stream makes that id ambiguous.
inv_count=0
for _s in "${segs[@]}"; do
  parse_linode_cmd "$_s" || continue
  [[ -n "$LIN_GROUP" ]] && inv_count=$((inv_count + 1))
done

idx=-1
for segment in "${segs[@]}"; do
  idx=$((idx + 1))
  parse_linode_cmd "$segment"
  rc=$?
  case $rc in
    1)
      # Not an invocation. A `cd` still matters: it moves later segments.
      lin_head || continue
      case "$LIN_HEAD" in
        cd|pushd)
          case "$LIN_HEAD_ARG" in
            ''|-*|*'$'*) ;;
            '~'|'~/'*) eff_cwd="${HOME:-/}${LIN_HEAD_ARG#\~}" ;;
            /*) eff_cwd="$LIN_HEAD_ARG" ;;
            *) eff_cwd="$eff_cwd/$LIN_HEAD_ARG" ;;
          esac ;;
      esac
      continue ;;
    2) continue ;;   # a nested script; its segments were appended and are checked in turn
    3)
      decide ask \
        "'$LIN_HEAD_UNKNOWN' precedes linode-cli on this line, and lingate does not know whether it executes what follows - if it does, the guard is being bypassed. If '$LIN_HEAD_UNKNOWN' only reads that text as data, confirm; if it really runs linode-cli, run linode-cli directly so lingate can check it."
      continue ;;
  esac

  # `--help` prints local text and never reaches the API. It is also what every
  # refusal message tells the developer to run next.
  (( LIN_HELP == 1 )) && continue
  [[ -n "$LIN_GROUP" ]] || continue

  scope=$(group_scope "$LIN_GROUP")
  [[ "$scope" == help ]] && continue

  kind=$(action_kind "$LIN_GROUP" "$LIN_ACTION")

  if [[ "$scope" == unknown ]]; then
    [[ "$kind" == read ]] && continue
    decide deny \
      "lingate does not know the command group '$LIN_GROUP', so it cannot verify this command stays inside the project. If this is a new linode-cli group, update plugins/linode/scripts/lib/linode.sh. If you only need to read, use a list/view action."
  fi

  # --- reads ----------------------------------------------------------------
  if [[ "$kind" == read ]]; then
    if [[ "$LIN_ACTION" =~ $LINGATE_SECRET_READ_RE ]] && ! stdout_is_kept_private "$idx"; then
      decide ask \
        "This command prints a credential to stdout, i.e. into the conversation transcript and up to the model provider - once leaked it must be rotated. Send it straight to where it is needed instead: '... --json | jq -r <field> > <git-ignored file>', or into 1Password with '... | opgate put <item> <FIELD>'. Redirecting stderr, or piping into another command that still prints, does not count. See: skills/linode/references/secrets.md"
    fi
    continue
  fi

  # --- everything below writes ----------------------------------------------
  need_project

  # Which environment is this command aimed at? The hook runs in its own process
  # and never inherits a `LINODE_ENV=prod linode-cli ...` prefix, so the prefix is
  # read out of the command text itself.
  cur_env="$LIN_ENV"
  [[ -n "$cur_env" ]] || cur_env="${LINODE_ENV:-}"
  [[ -n "$cur_env" ]] || cur_env="$proj_default_env"
  if [[ -n "$proj_envs" ]]; then
    case " $proj_envs " in
      *" $cur_env "*) ;;
      *) decide deny \
           "Env '$cur_env' is not one of the envs of project '$proj_tag' ([$proj_envs]). State the env on the command line: LINODE_ENV=<env> linode-cli $LIN_GROUP $LIN_ACTION ..." ;;
    esac
  fi

  # A cached answer is a bet that nothing changed in the last minute. For a
  # delete or a rebuild that bet is not worth taking.
  lookup_fresh=0
  [[ "$LIN_ACTION" =~ $LINGATE_DESTRUCTIVE_RE ]] && lookup_fresh=1

  if [[ "$scope" == cli ]]; then
    decide ask \
      "This command changes linode-cli's credentials or identity, not a resource of project '$proj_tag'. The user decides."
    continue
  fi

  if [[ "$scope" == unscoped ]]; then
    # The `tags` group edits the boundary itself, so it gets its own rules rather
    # than a label check. Attaching a tag rewrites the tags of the resources named
    # on the line, and deleting one strips it from every object on the account.
    if [[ "$LIN_GROUP" == tags ]]; then
      label="${LIN_LABEL:-${LIN_IDS[0]:-}}"
      if (( LIN_TAG_ATTACH == 1 )); then
        decide deny \
          "This command attaches a tag directly to the resources listed on the line, bypassing every ownership check - they may belong to another project. To bring a resource into the project use: lingate adopt <group> <id> --env <env> --yes"
      fi
      case " $proj_tag $proj_envs " in
        *" $label "*) ;;
        *) decide deny \
             "Tag '$label' is neither this project's tag ('$proj_tag') nor one of its envs ([$proj_envs]). Tags are the boundary between projects - creating or deleting another project's tag is the fastest way to push their resources outside every guard." ;;
      esac
      case "$LIN_ACTION" in
        delete|rm)
          decide ask \
            "Deleting tag '$label' strips it from EVERY resource on the account that carries it, and since it is a project or env tag of '$proj_tag' the boundary disappears with it. The user decides."
          ;;
      esac
      protected_gate
      continue
    fi
    decide deny \
      "'$LIN_GROUP $LIN_ACTION' writes account-level state that belongs to no project, '$proj_tag' included, so lingate will not run it. If it is really needed, let the user run it themselves."
  fi

  if [[ "$kind" == unknown ]]; then
    decide deny \
      "lingate cannot classify action '$LIN_GROUP $LIN_ACTION' as a read or a write, so it refuses by default. Run 'linode-cli $LIN_GROUP $LIN_ACTION --help' to see what it does; if it only reads, add it to LINGATE_READ_RE in plugins/linode/scripts/lib/linode.sh."
  fi

  # A password on the command line lands in the transcript, in the shell history
  # and in the process table at once.
  if [[ -n "$LIN_ROOTPASS" && "$LIN_ROOTPASS" != \$* ]]; then
    decide deny \
      "--root_pass is given a literal value on the command line; it lands in the transcript and must be rotated at once. Take it from 1Password instead: opgate exec ROOT_PASS=op://Dev/$proj_tag/LINODE_ROOT_PASS -- linode-cli $LIN_GROUP $LIN_ACTION ... --root_pass \$ROOT_PASS. See: skills/linode/references/secrets.md"
  fi

  # `update --tags` is a PUT that replaces the whole array, so a --tags list that
  # drops the project tag or the env tag is how a resource silently leaves the
  # fence without anyone deleting anything.
  if (( ${#LIN_TAGS[@]} > 0 )); then
    for _t in "${LIN_TAGS[@]}"; do
      case "$_t" in *'$'*) decide deny \
        "--tags is given '$_t', a shell variable lingate cannot read, so the tags the resource will carry cannot be verified. Write them literally: --tags $proj_tag --tags $cur_env" ;; esac
    done
    tags_contain "$proj_tag" "${LIN_TAGS[@]}" || decide deny \
      "--tags here replaces the resource's whole tag set with '${LIN_TAGS[*]}', dropping '$proj_tag' - the resource would leave the project and no guard would cover it. Add '--tags $proj_tag' to the list."
    if [[ -n "$proj_envs" ]]; then
      tags_contain "$cur_env" "${LIN_TAGS[@]}" || decide deny \
        "--tags here replaces the whole tag set with '${LIN_TAGS[*]}', dropping the env tag '$cur_env' - the resource would belong to no environment and every later write would be refused. Add '--tags $cur_env'."
      # The env tags this command is about to write get the same judgement as the
      # ones a resource already carries.
      _tenv=()
      while IFS= read -r _e; do [[ -n "$_e" ]] && _tenv[${#_tenv[@]}]="$_e"; done \
        <<< "$(env_of_tags "$proj_envs" "${LIN_TAGS[@]}")"
      env_verdict "The tag set this command is about to write" ${_tenv[@]+"${_tenv[@]}"}
    fi
  fi

  is_create=0
  case "$LIN_ACTION" in create|*-create) is_create=1 ;; esac

  # A create with no positional id makes a new top-level resource; a create WITH
  # one (records-create, pool-create, node-create) hangs a child off a resource
  # that already exists, so ownership comes from the parent.
  if (( is_create == 1 )) && (( ${#LIN_IDS[@]} == 0 )); then
    if [[ "$scope" == taggable ]]; then
      (( ${#LIN_TAGS[@]} > 0 )) || decide deny \
        "Missing --tags: the new resource would belong to no project, and from then on no command would be allowed to touch it. Add the project tag and the env tag: linode-cli $LIN_GROUP $LIN_ACTION --tags $proj_tag --tags $cur_env ..."
      check_refs
      protected_gate
      continue
    fi
    # One ledger create mints a credential in the same breath as the id, and the
    # only safe place for that credential is a pipe into opgate. Demanding the id
    # reach stdout would demand the secret reach the transcript, so this one is
    # exempt and its id is recorded by hand; see references/secrets.md.
    case "$LIN_GROUP $LIN_ACTION" in
      'object-storage keys-create') check_refs; protected_gate; continue ;;
    esac
    # Ledger groups have no tags field, so the id must be captured at creation
    # time or ownership is lost the moment the command finishes. All three checks
    # below are about that one id actually reaching the PostToolUse hook.
    (( LIN_HAS_JSON == 1 )) || decide deny \
      "'$LIN_GROUP' has no tags field on the API, so ownership is recorded in .linode/owned.json. Add '--json' so lingate can read the new id and record it automatically. See: skills/linode/references/guard-rules.md"
    (( inv_count <= 1 )) || decide deny \
      "This Bash call invokes linode-cli $inv_count times, one of them creating a resource that cannot carry tags. The ledger hook reads the id from the whole call's stdout, so the other invocations' output would make it record the wrong id. Run the create alone with '--json' first, then use that id in the next step."
    if [[ "${seg_stdout[idx]}" == 1 || "${seg_piped[idx]}" == 1 ]]; then
      decide deny \
        "This create's stdout goes to a file or a pipe, so the PostToolUse hook cannot read the id and ownership would be lost. Run the create alone with '--json' (redirecting stderr is fine), then use the id in the next step."
    fi
    check_refs
    protected_gate
    continue
  fi

  owner_id=$(lin_owner_id)
  [[ -n "$owner_id" ]] || decide deny \
    "'$LIN_GROUP $LIN_ACTION' is a write but names no resource id on the command line, so there is no way to tell whose resource it touches. Syntax: linode-cli $LIN_GROUP $LIN_ACTION --help"

  check_target "$LIN_GROUP" "$owner_id" ""
  check_refs
  protected_gate
done

if [[ -n "$pending_ask" ]]; then
  guard_done=1; emit ask "$pending_ask"; exit 0
fi
guard_done=1
exit 0
