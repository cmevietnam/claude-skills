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
trap '[[ $guard_done -eq 1 ]] || emit deny "lingate: hook gap loi giua chung nen khong xac minh duoc lenh nay thuoc project/env nao. Day la tu choi co chu dich (fail closed). Chay: bash plugins/linode/scripts/test-guard.sh de xem hong o dau."' EXIT

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
    "lingate: thieu file $f nen hang rao khong chay duoc. Cai lai plugin hoac chay 'claude plugin validate ./plugins/linode'."
done
# shellcheck source=lib/common.sh
. "$here/lib/common.sh" 2>/dev/null
# shellcheck source=lib/linode.sh
. "$here/lib/linode.sh" 2>/dev/null
# A library that failed to parse leaves these undefined; without this check the
# script would fall through to "nothing to guard" and let the write go.
type lin_split_all >/dev/null 2>&1 && type json_str_file >/dev/null 2>&1 || decide deny \
  "lingate: scripts/lib/*.sh khong nap duoc (loi cu phap?). Chay: bash -n plugins/linode/scripts/lib/common.sh plugins/linode/scripts/lib/linode.sh"

if [[ "$LINGATE_GUARD" == off ]]; then guard_done=1; exit 0; fi

command_line=$(hook_command "$payload")
if [[ -z "$command_line" ]]; then
  case "$payload" in
    *'"command"'*) decide deny "lingate: payload co truong command nhung khong doc duoc noi dung, nen khong xac minh duoc lenh. Kiem tra jq/awk tren may." ;;
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

# Project identity, resolved when a write needs it, per working directory.
proj_root=""; proj_tag=""; proj_envs=""; proj_default_env=""; proj_protected=""
proj_shared=""; proj_for_cwd=""
need_project() {
  [[ -n "$proj_tag" && "$proj_for_cwd" == "$eff_cwd" ]] && return 0
  proj_for_cwd="$eff_cwd"
  proj_root=$(find_project_root "$eff_cwd") || decide deny \
    "Khong tim thay .linode/project.json tinh tu $eff_cwd tro len, nen khong biet resource sap dung den thuoc project nao. Chay 'lingate init <tag>' o goc repo truoc (vi du: lingate init cme), roi chay lai lenh. Doc: skills/linode/references/project-setup.md"
  proj_tag=$(json_str_file "$proj_root/$LINGATE_CONFIG" tag)
  [[ -n "$proj_tag" ]] || decide deny \
    "File $proj_root/$LINGATE_CONFIG khong co truong 'tag'. Sua lai hoac chay 'lingate init <tag>' de tao lai."
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
      "$subject khong mang env tag nao trong [$proj_envs], nen khong biet no la moi truong nao - va mot lenh ghi mu moi truong la cach kinh dien de sua nham prod. Gan env truoc: lingate adopt <group> <id> --env <env> --yes"
  fi
  tags_contain "$cur_env" "${renv[@]}" || decide deny \
    "CROSS-ENV: $subject nam o env '${renv[*]}' nhung lenh nay dang chay o env '$cur_env'. Lingate khong bao gio tu suy dien y dinh giua hai moi truong. Neu that su muon thao tac tren '${renv[0]}', hay noi ro ngay tren dong lenh: LINODE_ENV=${renv[0]} linode-cli $LIN_GROUP $LIN_ACTION ... - va hoi nguoi dung truoc neu do la env duoc bao ve."

  (( ${#renv[@]} > 1 )) || return 0

  for e in "${renv[@]}"; do
    [[ "$e" == "$cur_env" ]] && continue
    other="$other $e"
  done
  other=${other# }

  if [[ "$proj_shared" != true ]]; then
    decide deny \
      "$subject mang nhieu env tag cung luc: ${renv[*]}. Mot resource chi duoc thuoc mot moi truong. Neu day la co y - mot may phuc vu ca hai env de tiet kiem - hay khai bao ro trong .linode/project.json: allowSharedEnvs = true, roi lingate se cho phep nhung van hoi truoc moi lan ghi neu env con lai duoc bao ve."
  fi

  for e in $other; do
    case " $proj_protected " in
      *" $e "*)
        decide ask \
          "$subject dung chung cho nhieu moi truong: ${renv[*]}. Lenh nay chay o '$cur_env', nhung cung chinh resource do dang phuc vu env duoc bao ve '$e' - moi thay doi o day se cham vao $e ngay lap tuc. Lenh: 'linode-cli $LIN_GROUP $LIN_ACTION ${LIN_IDS[*]-}'. Nguoi dung xac nhan."
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
    "Khong tra duoc tag cua $g $rid trong ngan sach $LINGATE_BUDGET giay (linode-cli loi, id khong ton tai, mang cham, hoac da het thoi gian cho cac lookup truoc). Khi chua biet chac resource thuoc ve ai thi lingate tu choi chu khong doan. Kiem tra bang: linode-cli $g $(view_action_for "$g") $rid --json"

  # First line names the resource whose tags were actually read: for an untagged
  # LKE worker that is its cluster, and the message should point there.
  hdr=${tags_out%%$'\n'*}
  case "$hdr" in
    @*) tags_out=${tags_out#*$'\n'}; [[ "$tags_out" == "$hdr" ]] && tags_out=""
        og=${hdr#@}; oid=${og#*/}; og=${og%%/*} ;;
  esac
  if [[ "$og $oid" != "$g $rid" ]]; then
    src=" (no la node cua $og $oid va khong mang tag rieng, nen quyen so huu lay theo cluster)"
  fi

  local -a tags=()
  while IFS= read -r t; do [[ -n "$t" ]] && tags[${#tags[@]}]="$t"; done <<< "$tags_out"

  if (( ${#tags[@]} == 0 )); then
    decide deny \
      "$what $g $rid chua mang tag nao$src, nen no khong thuoc project nao ca va lingate khong ghi len no. Neu day la resource cu cua project '$proj_tag', nhan no ve bang: lingate adopt $og $oid --env $cur_env --yes (hoi nguoi dung truoc). Xem tat ca resource chua tag: lingate orphans"
  fi
  tags_contain "$proj_tag" "${tags[@]}" || decide deny \
    "$what $g $rid mang tag '${tags[*]}'$src, khong phai '$proj_tag' - no thuoc project khac. Day la ranh gioi cung cua plugin nay: khong ghi len resource cua project khac, khong ngoai le. Resource cua project nay: linode-cli $g list --tags $proj_tag"

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
    "$proj_root/$LINGATE_LEDGER khai bao no thuoc project '$(json_str_file "$proj_root/$LINGATE_LEDGER" tag)' chu khong phai '$proj_tag'. Mot so so huu chi noi thay cho dung project cua no. Chay 'lingate init $proj_tag' - no se cat so cu sang mot ben va tao so moi."
  ledger_has "$proj_root" "$proj_tag" "$g" "$rid" || decide deny \
    "$what $g $rid khong co trong so so huu .linode/owned.json cua project '$proj_tag'. Neu no dung la cua project, ghi so bang 'lingate own $g $rid --env $cur_env' roi chay lai. Neu khong phai, dung dung den no."
  [[ -n "$proj_envs" ]] || return 0
  local -a lenv=()
  local e
  while IFS= read -r e; do [[ -n "$e" ]] && lenv[${#lenv[@]}]="$e"; done \
    <<< "$(ledger_envs_of "$proj_root" "$proj_tag" "$g" "$rid")"
  env_verdict "$what $g $rid (theo so so huu)" ${lenv[@]+"${lenv[@]}"}
}

# Whichever source of truth applies to the group.
check_target() {
  case "$(group_scope "$1")" in
    taggable) check_owner "$1" "$2" "$3" ;;
    ledger)   check_ledger "$1" "$2" "$3" ;;
    *)        decide deny "Khong biet cach xac minh quyen so huu cua $1 $2." ;;
  esac
}

# Every extra resource the command names — the Linode a volume attaches to, a
# firewall device, the VPC an interface joins — is being written to as well.
check_refs() {
  local i=0
  if (( ${#LIN_BAD_REFS[@]} > 0 )); then
    decide deny \
      "Lenh nay tro toi mot resource khac qua gia tri lingate khong doc duoc: '${LIN_BAD_REFS[0]}' (bien shell hoac danh sach JSON). Khong doc duoc thi khong xac minh duoc chu so huu. Viet id ro rang tren dong lenh."
  fi
  while (( i < ${#LIN_REF_GROUPS[@]} )); do
    check_target "${LIN_REF_GROUPS[i]}" "${LIN_REF_IDS[i]}" "Resource dich"
    i=$((i + 1))
  done
}

# Everything above has said yes. In a protected environment that is still not
# enough: a human confirms.
protected_gate() {
  case " $proj_protected " in
    *" $cur_env "*)
      decide ask \
        "Env '$cur_env' duoc danh dau la bao ve trong .linode/project.json. Lenh ghi: 'linode-cli $LIN_GROUP $LIN_ACTION ${LIN_IDS[*]-}'. Moi rang buoc ve project va env deu da thoa - chi con nguoi dung xac nhan day dung la thu ho muon chay tren $cur_env."
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
        "'$LIN_HEAD_UNKNOWN' dung truoc linode-cli tren dong lenh nay, va lingate khong biet no co chay lenh phia sau hay khong - neu co thi hang rao dang bi bo qua. Neu '$LIN_HEAD_UNKNOWN' chi doc chuoi do nhu du lieu thi cu xac nhan; neu no thuc su chay linode-cli, hay chay linode-cli truc tiep de lingate kiem tra duoc."
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
      "lingate chua biet command group '$LIN_GROUP', nen khong the xac minh lenh nay nam trong pham vi project. Neu day la group moi cua linode-cli, cap nhat plugins/linode/scripts/lib/linode.sh. Neu chi can doc, dung mot action list/view."
  fi

  # --- reads ----------------------------------------------------------------
  if [[ "$kind" == read ]]; then
    if [[ "$LIN_ACTION" =~ $LINGATE_SECRET_READ_RE ]] && ! stdout_is_kept_private "$idx"; then
      decide ask \
        "Lenh nay in credential ra stdout, tuc la vao transcript cua cuoc hoi thoai va len model provider - lo roi thi phai rotate. Muon giu kin thi cho no di thang toi noi can den: '... --json | jq -r <field> > <file da git-ignore>', hoac cat vao 1Password bang '... | opgate put <item> <FIELD>'. Chuyen huong stderr hay pipe vao mot lenh khac van in ra man hinh thi khong tinh. Doc: skills/linode/references/secrets.md"
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
           "Env '$cur_env' khong nam trong danh sach env cua project '$proj_tag' ([$proj_envs]). Noi ro env ngay tren dong lenh: LINODE_ENV=<env> linode-cli $LIN_GROUP $LIN_ACTION ..." ;;
    esac
  fi

  # A cached answer is a bet that nothing changed in the last minute. For a
  # delete or a rebuild that bet is not worth taking.
  lookup_fresh=0
  [[ "$LIN_ACTION" =~ $LINGATE_DESTRUCTIVE_RE ]] && lookup_fresh=1

  if [[ "$scope" == cli ]]; then
    decide ask \
      "Lenh nay doi credential hoac identity cua linode-cli chu khong phai mot resource cua project '$proj_tag'. Nguoi dung tu quyet dinh."
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
          "Lenh nay gan tag thang vao resource duoc liet ke tren dong lenh, di vong qua toan bo kiem tra quyen so huu - resource do co the thuoc project khac. Muon dua mot resource vao project thi dung: lingate adopt <group> <id> --env <env> --yes"
      fi
      case " $proj_tag $proj_envs " in
        *" $label "*) ;;
        *) decide deny \
             "Tag '$label' khong phai tag cua project nay ('$proj_tag') cung khong phai env cua no ([$proj_envs]). Tag la ranh gioi giua cac project - tao hay xoa tag cua project khac la cach nhanh nhat de resource cua ho roi ra ngoai moi hang rao." ;;
      esac
      case "$LIN_ACTION" in
        delete|rm)
          decide ask \
            "Xoa tag '$label' se go no khoi MOI resource dang mang tag do tren toan account, va vi day la tag project hoac tag env cua '$proj_tag' nen hang rao bien mat cung voi no. Nguoi dung tu quyet dinh."
          ;;
      esac
      continue
    fi
    decide deny \
      "'$LIN_GROUP $LIN_ACTION' ghi len tai nguyen cap account, khong thuoc project '$proj_tag' nao ca, nen lingate khong chay ho. Neu that su can, hay de nguoi dung tu chay."
  fi

  if [[ "$kind" == unknown ]]; then
    decide deny \
      "lingate khong phan loai duoc action '$LIN_GROUP $LIN_ACTION' la doc hay ghi, nen mac dinh tu choi. Chay 'linode-cli $LIN_GROUP $LIN_ACTION --help' de xem no lam gi; neu la lenh doc, bo sung vao LINGATE_READ_RE trong plugins/linode/scripts/lib/linode.sh."
  fi

  # A password on the command line lands in the transcript, in the shell history
  # and in the process table at once.
  if [[ -n "$LIN_ROOTPASS" && "$LIN_ROOTPASS" != \$* ]]; then
    decide deny \
      "--root_pass dang nhan gia tri viet thang tren dong lenh, no se vao transcript va phai rotate ngay. Lay tu 1Password thay vi vay: opgate exec ROOT_PASS=op://Dev/$proj_tag/LINODE_ROOT_PASS -- linode-cli $LIN_GROUP $LIN_ACTION ... --root_pass \$ROOT_PASS. Doc: skills/linode/references/secrets.md"
  fi

  # `update --tags` is a PUT that replaces the whole array, so a --tags list that
  # drops the project tag or the env tag is how a resource silently leaves the
  # fence without anyone deleting anything.
  if (( ${#LIN_TAGS[@]} > 0 )); then
    for _t in "${LIN_TAGS[@]}"; do
      case "$_t" in *'$'*) decide deny \
        "--tags nhan gia tri '$_t' la bien shell, lingate khong doc duoc nen khong xac minh duoc resource se mang tag gi. Viet tag ro rang: --tags $proj_tag --tags $cur_env" ;; esac
    done
    tags_contain "$proj_tag" "${LIN_TAGS[@]}" || decide deny \
      "--tags o day dat lai toan bo tag cua resource thanh '${LIN_TAGS[*]}', khong con '$proj_tag' - resource se roi khoi project va khong con hang rao nao bao ve. Them '--tags $proj_tag' vao danh sach."
    if [[ -n "$proj_envs" ]]; then
      tags_contain "$cur_env" "${LIN_TAGS[@]}" || decide deny \
        "--tags o day dat lai toan bo tag thanh '${LIN_TAGS[*]}', khong con env tag '$cur_env' - resource se thanh khong thuoc moi truong nao va moi lenh ghi sau do se bi tu choi. Them '--tags $cur_env'."
      # The env tags this command is about to write get the same judgement as the
      # ones a resource already carries.
      _tenv=()
      while IFS= read -r _e; do [[ -n "$_e" ]] && _tenv[${#_tenv[@]}]="$_e"; done \
        <<< "$(env_of_tags "$proj_envs" "${LIN_TAGS[@]}")"
      env_verdict "Bo tag lenh nay sap dat" ${_tenv[@]+"${_tenv[@]}"}
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
        "Thieu --tags: resource tao ra se khong thuoc project nao, va tu do khong con lenh nao duoc phep dung den no. Them tag project va tag env: linode-cli $LIN_GROUP $LIN_ACTION --tags $proj_tag --tags $cur_env ..."
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
      "'$LIN_GROUP' khong co truong tags tren API, nen quyen so huu duoc ghi vao .linode/owned.json. Them '--json' de lingate doc duoc id vua tao va ghi so tu dong. Doc: skills/linode/references/guard-rules.md"
    (( inv_count <= 1 )) || decide deny \
      "Lenh Bash nay goi linode-cli $inv_count lan, trong do co mot lenh tao resource khong gan tag duoc. Hook ghi so doc id tu stdout cua ca lenh, nen output cua cac lenh kia lam no ghi sai id. Chay lenh tao mot minh voi '--json' truoc, roi dung id do o buoc sau."
    if [[ "${seg_stdout[idx]}" == 1 || "${seg_piped[idx]}" == 1 ]]; then
      decide deny \
        "Stdout cua lenh tao nay bi chuyen huong vao file hoac dua qua pipe, nen hook PostToolUse khong doc duoc id va quyen so huu se mat. Chay lenh tao mot minh voi '--json' (chuyen huong stderr thi khong sao), roi dung id do o buoc sau."
    fi
    check_refs
    protected_gate
    continue
  fi

  owner_id=$(lin_owner_id)
  [[ -n "$owner_id" ]] || decide deny \
    "'$LIN_GROUP $LIN_ACTION' la lenh ghi nhung khong co id resource nao tren dong lenh, nen khong xac minh duoc no cham vao cai gi cua ai. Xem cu phap: linode-cli $LIN_GROUP $LIN_ACTION --help"

  check_target "$LIN_GROUP" "$owner_id" ""
  check_refs
  protected_gate
done

if [[ -n "$pending_ask" ]]; then
  guard_done=1; emit ask "$pending_ask"; exit 0
fi
guard_done=1
exit 0
