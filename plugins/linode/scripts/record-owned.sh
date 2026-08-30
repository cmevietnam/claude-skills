#!/usr/bin/env bash
# PostToolUse(Bash) hook.
#
# Databases, VPCs, Object Storage buckets, placement groups, StackScripts and SSH
# keys have no tags field on the API, so the only moment their ownership can be
# recorded is right after they are created — the id exists nowhere else yet. This
# reads it out of the command's own output and writes .linode/owned.json.
#
# Unlike the guard this is not a boundary: when it cannot record the id it says
# so and asks for `lingate own`, rather than staying quiet about it.

payload=$(cat)

case "$payload" in
  *linode*) ;;
  *lin*) printf '%s' "$payload" | grep -Eq '(^|[^A-Za-z0-9_.-])lin([^A-Za-z0-9_.-]|$)' || exit 0 ;;
  *) exit 0 ;;
esac

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)
[[ -r "$here/lib/common.sh" && -r "$here/lib/linode.sh" ]] || exit 0
# shellcheck source=lib/common.sh
. "$here/lib/common.sh"
# shellcheck source=lib/linode.sh
. "$here/lib/linode.sh"

[[ "$LINGATE_GUARD" == off ]] && exit 0

command_line=$(hook_command "$payload")
[[ -n "$command_line" ]] || exit 0

note() {
  # Same reason as the guard's emit(): this text carries labels and ids from the
  # API, and invalid JSON here is silently dropped.
  local msg
  msg=$(printf '%s' "$1" | tr -d '\000-\037' | tr '\\"' '  ')
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$msg"
  exit 0
}

# Same splitter as the guard, so the two agree on what a command is.
lin_split_all "$command_line"

group=""; action=""; env=""; inv=0
for segment in "${segs[@]}"; do
  parse_linode_cmd "$segment" || continue
  [[ -n "$LIN_GROUP" ]] || continue
  inv=$((inv + 1))
  (( LIN_HELP == 1 )) && continue          # --help creates nothing
  [[ -n "$LIN_ACTION" ]] || continue
  [[ "$(group_scope "$LIN_GROUP")" == ledger ]] || continue
  case "$LIN_ACTION" in create|*-create) ;; *) continue ;; esac
  (( ${#LIN_IDS[@]} == 0 )) || continue     # a child create; the parent already owns it
  [[ "$LIN_GROUP $LIN_ACTION" == 'object-storage keys-create' ]] && continue  # recorded by hand, see secrets.md
  group="$LIN_GROUP"; action="$LIN_ACTION"; env="$LIN_ENV"
done

[[ -n "$group" ]] || exit 0

# The guard refuses a ledger create that shares its Bash call with another
# invocation; if one got here anyway, do not guess which id is which.
(( inv <= 1 )) || note "Lenh Bash nay goi linode-cli $inv lan, nen lingate khong biet id nao trong output la cua resource '$group' vua tao. Ghi so tay: lingate own $group <id> --env <env>"

cwd=$(payload_str "$payload" '.cwd' 'cwd')
[[ -n "$cwd" ]] || cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
root=$(find_project_root "$cwd") || exit 0
tag=$(json_str_file "$root/$LINGATE_CONFIG" tag)

# The created resource's id, from the command's own stdout. hook_response falls
# back to a pure-awk scan when jq is absent, so a machine without jq still
# records ownership instead of silently skipping it.
output=$(hook_response "$payload")
label=$(json_str "$output" label)
if [[ "$group $action" == 'object-storage bucket-create' ]]; then
  # Buckets have no numeric id; the API addresses them as <region>/<label>.
  region=$(json_str "$output" region)
  [[ -n "$region" ]] || region=$(json_str "$output" cluster)
  id=""
  [[ -n "$region" && -n "$label" ]] && id="$region/$label"
else
  id=$(json_first_id "$output")
fi
if [[ -z "$id" ]]; then
  note "Vua tao mot resource '$group' - loai nay khong co truong tags tren API nen quyen so huu phai ghi vao .linode/owned.json, nhung lingate khong doc duoc id tu output. Chay ngay: lingate own $group <id> --env <env>"
fi

ledger_has "$root" "$tag" "$group" "$id" && exit 0

[[ -n "$env" ]] || env="${LINODE_ENV:-}"
[[ -n "$env" ]] || env=$(json_str_file "$root/$LINGATE_CONFIG" defaultEnv)

if [[ -f "$root/$LINGATE_LEDGER" ]] && ! ledger_is_ours "$root" "$tag"; then
  note "lingate: KHONG ghi duoc $group $id - $root/$LINGATE_LEDGER khai bao no thuoc project '$(json_str_file "$root/$LINGATE_LEDGER" tag)' chu khong phai '$tag'. Chay 'lingate init $tag' de tao so moi (so cu duoc cat sang mot ben), roi: lingate own $group $id --env $env"
fi

if { ledger_entries "$root" "$tag"
     printf '{"type": "%s", "id": "%s", "env": "%s", "label": "%s", "at": "%s"}\n' \
       "$group" "$id" "$env" "$(json_escape "$label")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
   } | ledger_save "$root" "$tag" && ledger_has "$root" "$tag" "$group" "$id"; then
  note "lingate: da ghi $group $id (env '$env') vao .linode/owned.json cua project '$tag'. Nho commit file nay."
fi

note "lingate: KHONG ghi duoc $group $id vao $root/$LINGATE_LEDGER (loi ghi file). Resource da duoc tao roi nhung chua co chu - chay ngay: lingate own $group $id --env $env"
