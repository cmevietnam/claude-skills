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
  *linode*|*'"lin '*|*' lin '*|*'/lin '*) ;;
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

group=""; env=""
for segment in "${segs[@]}"; do
  parse_linode_cmd "$segment" || continue
  [[ -n "$LIN_GROUP" && -n "$LIN_ACTION" ]] || continue
  [[ "$(group_scope "$LIN_GROUP")" == ledger ]] || continue
  case "$LIN_ACTION" in create|*-create) ;; *) continue ;; esac
  (( ${#LIN_IDS[@]} == 0 )) || continue   # a child create; the parent already owns it
  group="$LIN_GROUP"; env="$LIN_ENV"
  break
done

[[ -n "$group" ]] || exit 0

root=$(find_project_root) || exit 0

# The created resource's id, from the command's own stdout. hook_response falls
# back to a pure-awk scan when jq is absent, so a machine without jq still
# records ownership instead of silently skipping it.
output=$(hook_response "$payload")
id=$(json_first_id "$output")
if [[ -z "$id" ]]; then
  note "Vua tao mot resource '$group' - loai nay khong co truong tags tren API nen quyen so huu phai ghi vao .linode/owned.json, nhung lingate khong doc duoc id tu output. Chay ngay: lingate own $group <id> --env <env>"
fi

label=$(json_str "$output" label)
tag=$(json_str_file "$root/$LINGATE_CONFIG" tag)
ledger_has "$root" "$tag" "$group" "$id" && exit 0

[[ -n "$env" ]] || env="${LINODE_ENV:-}"
[[ -n "$env" ]] || env=$(json_str_file "$root/$LINGATE_CONFIG" defaultEnv)

if { ledger_entries "$root"
     printf '{"type": "%s", "id": "%s", "env": "%s", "label": "%s", "at": "%s"}\n' \
       "$group" "$id" "$env" "$(json_escape "$label")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
   } | ledger_save "$root" "$tag" && ledger_has "$root" "$tag" "$group" "$id"; then
  note "lingate: da ghi $group $id (env '$env') vao .linode/owned.json cua project '$tag'. Nho commit file nay."
fi

note "lingate: KHONG ghi duoc $group $id vao $root/$LINGATE_LEDGER (loi ghi file). Resource da duoc tao roi nhung chua co chu - chay ngay: lingate own $group $id --env $env"
