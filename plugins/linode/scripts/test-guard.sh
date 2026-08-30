#!/usr/bin/env bash
# Input/output checks on the guard. No Linode account, no network, no token — a
# stub linode-cli at the front of PATH answers every ownership lookup from a
# fixed table, so the same run means the same thing on any machine.
#
#   bash scripts/test-guard.sh
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
guard="$here/guard-linode.sh"

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

# --- stub world -------------------------------------------------------------
# 95747451 cme/prod · 94162441 an LKE node of cluster 580172 · 580172 cme/prod
# 77000001 cme/staging · 66000001 urgentc · 55000001 untagged · 44000001 two envs
mkdir -p "$work/bin"
cat > "$work/bin/linode-cli" <<'STUB'
#!/usr/bin/env bash
group="$1"; action="$2"; id="${3:-}"
emit() { printf '[{"id": %s, "label": "%s", "tags": [%s]}]\n' "$1" "$2" "$3"; }
case "$group $action $id" in
  "linodes view 95747451")     emit 95747451 cme-postgres '"cme", "prod"' ;;
  "linodes view 94162441")     emit 94162441 lke580172-848275-0163129a0000 '' ;;
  "linodes view 94162442")     emit 94162442 lke580172-848275-0163129a0001 '"cme", "staging"' ;;
  "lke cluster-view 580172")   emit 580172 cme-cluster '"cme", "prod"' ;;
  "linodes view 77000001")     emit 77000001 cme-web-stg '"cme", "staging"' ;;
  "linodes view 66000001")     emit 66000001 urgentc-api '"urgentc", "prod"' ;;
  "linodes view 55000001")     emit 55000001 legacy-box '' ;;
  "linodes view 44000001")     emit 44000001 cme-muddle '"cme", "prod", "staging"' ;;
  "linodes view 33000001")     emit 33000001 cme-notag-env '"cme"' ;;
  "domains view 22000001")     emit 22000001 example.com '"cme", "prod"' ;;
  "linodes view 22000002")     emit 22000002 cme-oddtag '"cme,staging"' ;;
  "volumes view 555")          emit 555 urgentc-data '"urgentc", "prod"' ;;
  "volumes view 556")          emit 556 cme-data '"cme", "staging"' ;;
  "linodes view 11111111")     sleep 30; emit 11111111 slow '"cme", "staging"' ;;
  "linodes view 11111112")     sleep 2; emit 11111112 slow2 '"cme", "staging"' ;;
  "volumes view 557")          sleep 2; emit 557 slow-vol '"cme", "staging"' ;;
  "domains view 22000006")     emit 22000006 stg.example '"cme", "staging"' ;;
  "linodes view 22000003")     emit 22000003 cme-shared '"cme", "prod", "staging"' ;;
  "linodes view 22000004")     emit 22000004 cme-lowshare '"cme", "dev", "staging"' ;;
  "linodes view 22000005")     emit 22000005 cme-prodonly '"cme", "prod"' ;;
  "linodes view 44000009")     printf '[{"id": 44000009, "label": "web \\"prod\\"", "tags": ["urgentc \\\\ x"]}]\n' ;;
  "linodes view 33000009")
    # Retagged out from under us between the two calls: a cached answer would
    # still say "ours". Destructive actions must not take that bet.
    if [ -f "$LINGATE_STUB_SEEN" ]; then emit 33000009 moved '"urgentc", "prod"'
    else : > "$LINGATE_STUB_SEEN"; emit 33000009 moved '"cme", "staging"'; fi ;;
  *) exit 1 ;;   # unknown id: the guard must fail closed, not fall open
esac
STUB
chmod 755 "$work/bin/linode-cli"
PATH="$work/bin:$PATH"
export LINGATE_STUB_SEEN="$work/stub-seen"

# --- a project to stand in --------------------------------------------------
proj="$work/repo"
mkdir -p "$proj/.linode"
cat > "$proj/.linode/project.json" <<'CFG'
{
  "tag": "cme",
  "labelPrefix": "cme-",
  "envs": ["staging", "prod"],
  "defaultEnv": "staging",
  "protectedEnvs": ["prod"]
}
CFG
cat > "$proj/.linode/owned.json" <<'LEDGER'
{
  "tag": "cme",
  "owned": [
    {"type": "vpcs", "id": "900001", "env": "staging", "label": "cme-vpc", "at": "2026-08-30T00:00:00Z"},
    {"type": "vpcs", "id": "900002", "env": "prod", "label": "cme-vpc-prod", "at": "2026-08-30T00:00:00Z"},
    {"type": "object-storage", "id": "sg-sin-1/cme-bucket", "env": "staging", "label": "cme-bucket", "at": "2026-08-30T00:00:00Z"},
    {"type": "placement", "id": "8801", "env": "staging", "label": "cme-pg", "at": "2026-08-30T00:00:00Z"}
  ]
}
LEDGER

shared="$work/shared"
mkdir -p "$shared/.linode"
cat > "$shared/.linode/project.json" <<'CFG'
{
  "tag": "cme",
  "envs": ["dev", "staging", "prod"],
  "defaultEnv": "staging",
  "protectedEnvs": ["prod"],
  "allowSharedEnvs": true
}
CFG
printf '{"tag": "cme", "owned": []}\n' > "$shared/.linode/owned.json"

# A ledger that speaks for a different project must not be believed.
foreign="$work/foreign"
mkdir -p "$foreign/.linode"
cp "$proj/.linode/project.json" "$foreign/.linode/project.json"
cat > "$foreign/.linode/owned.json" <<'LEDGER'
{
  "tag": "urgentc",
  "owned": [
    {"type": "vpcs", "id": "900001", "env": "staging", "label": "not-ours", "at": "2026-08-30T00:00:00Z"}
  ]
}
LEDGER

nowhere="$work/nowhere"
mkdir -p "$nowhere"

# Ownership lookups must not be answered from a previous run's cache.
export XDG_CACHE_HOME="$work/cache"
export LINGATE_DEADLINE=2
export CLAUDE_PROJECT_DIR="$proj"
unset LINODE_ENV

# --- harness ----------------------------------------------------------------
# CHECK_ENV="VAR=x -u VAR2" is handed to env(1) in front of the guard.
decision() { printf '%s' "$2" | env ${CHECK_ENV:-} bash "$1" | sed -n 's/.*"permissionDecision":"\([a-z]*\)".*/\1/p'; }
json() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' "$1"; }
json_cwd() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' "$1" "$2"; }

pass=0; fail=0
check() {  # check <command> <expected>
  local got shown="${1//$'\n'/⏎}"
  got=$(decision "$guard" "$(json "$1")")
  got=${got:-pass}
  if [[ "$got" == "$2" ]]; then
    pass=$((pass + 1))
    printf '  ok   %-72s %s\n' "$shown" "$got"
  else
    fail=$((fail + 1))
    printf '  FAIL %-72s got=%s want=%s\n' "$shown" "$got" "$2"
  fi
}

check_cwd() {  # check_cwd <cwd in payload> <command> <expected>; CLAUDE_PROJECT_DIR is withheld
  local got
  got=$(CHECK_ENV="-u CLAUDE_PROJECT_DIR" decision "$guard" "$(json_cwd "$2" "$1")")
  got=${got:-pass}
  if [[ "$got" == "$3" ]]; then
    pass=$((pass + 1)); printf '  ok   %-72s %s\n' "cwd=${1##*/}: $2" "$got"
  else
    fail=$((fail + 1)); printf '  FAIL %-72s got=%s want=%s\n' "cwd=${1##*/}: $2" "$got" "$3"
  fi
}

verdict() {  # verdict <label> <exit status>
  if [[ "$2" == 0 ]]; then pass=$((pass + 1)); printf '  ok   %-72s\n' "$1"
  else fail=$((fail + 1)); printf '  FAIL %-72s\n' "$1"; fi
}

check_in() {  # check_in <project dir> <command> <expected>
  local got
  got=$(CLAUDE_PROJECT_DIR="$1" decision "$guard" "$(json "$2")")
  got=${got:-pass}
  if [[ "$got" == "$3" ]]; then
    pass=$((pass + 1)); printf '  ok   %-72s %s\n' "$2" "$got"
  else
    fail=$((fail + 1)); printf '  FAIL %-72s got=%s want=%s\n' "$2" "$got" "$3"
  fi
}

echo "reads are never blocked"
check "linode-cli linodes list" pass
check "linode-cli linodes list --tags cme" pass
check "linode-cli linodes view 66000001" pass
check "linode-cli regions list --json" pass
check "linode-cli lke pools-list 580172" pass
check "linode-cli account view" pass

echo
echo "create: the project tag and the env tag are mandatory"
check "linode-cli linodes create --region sg-sin-2 --type g6-standard-1" deny
check "linode-cli linodes create --tags cme --label cme-web" deny
check "linode-cli linodes create --tags cme --tags staging --label cme-web" pass
check "linode-cli volumes create --tags cme --tags staging --label cme-data" pass
check "linode-cli lke cluster-create --tags cme --tags staging --label cme-k8s" pass

echo
echo "writes to existing resources: must be the right project"
check "linode-cli linodes reboot 77000001" pass
check "linode-cli linodes reboot 66000001" deny
check "linode-cli linodes reboot 55000001" deny
check "linode-cli linodes delete 99999999" deny
check "linode-cli linodes reboot 33000001" deny

echo
echo "cross-env: hard refusal in both directions"
check "linode-cli linodes reboot 95747451" deny
check "LINODE_ENV=prod linode-cli linodes reboot 95747451" ask
check "LINODE_ENV=prod linode-cli linodes reboot 77000001" deny
check "LINODE_ENV=qa linode-cli linodes reboot 77000001" deny
check "linode-cli linodes reboot 44000001" deny
check "LINODE_ENV=prod linode-cli domains records-update 22000001 5 --target 1.2.3.4" ask

echo
echo "LKE workers inherit ownership from the cluster — only when untagged themselves"
check "linode-cli linodes reboot 94162441" deny
check "LINODE_ENV=prod linode-cli linodes reboot 94162441" ask
check "linode-cli linodes reboot 94162442" pass
check "LINODE_ENV=prod linode-cli linodes reboot 94162442" deny

echo
echo "--tags on update is a PUT: tags must not be dropped"
check "linode-cli linodes update 77000001 --tags foo" deny
check "linode-cli linodes update 77000001 --tags cme" deny
check "linode-cli linodes update 77000001 --tags cme --tags staging --label x" pass

echo
echo "untaggable types: the ownership ledger"
check "linode-cli vpcs create --label cme-vpc" deny
check "linode-cli vpcs create --label cme-vpc --json" pass
check "linode-cli vpcs update 900001 --description x" pass
check "linode-cli vpcs update 900002 --description x" deny
check "LINODE_ENV=prod linode-cli vpcs update 900002 --description x" ask
check "linode-cli vpcs delete 900777" deny

echo
echo "secrets must not reach stdout"
check "linode-cli linodes create --tags cme --tags staging --root_pass hunter2" deny
check "linode-cli linodes create --tags cme --tags staging --root_pass \$ROOT_PASS" pass
check "linode-cli lke kubeconfig-view 580172" ask
check "linode-cli lke kubeconfig-view 580172 --json > /tmp/kc" pass
check "linode-cli databases mysql-creds-view 1" ask
check "linode-cli object-storage keys-list" ask

echo
echo "outside the project scope"
check "linode-cli account update --company x" deny
check "linode-cli users delete bob" deny
check "linode-cli tags create --label cme" pass
check "linode-cli tags delete urgentc" deny
check "linode-cli configure" ask

echo
echo "no .linode/project.json, no writes"
( export CLAUDE_PROJECT_DIR="$nowhere"
  got=$(decision "$guard" "$(json 'linode-cli linodes create --tags cme --tags staging')")
  [[ "${got:-pass}" == deny ]] && printf '  ok   %-72s %s\n' "outside any project" deny \
                               || printf '  FAIL %-72s got=%s want=deny\n' "outside any project" "${got:-pass}" )

echo
echo "tricky cases"
check 'bash -c "linode-cli linodes delete 66000001"' deny
check "echo linode-cli linodes delete 66000001" pass
check "lingate adopt linodes 55000001 --yes" pass
check "linode-cli linodes list && linode-cli linodes reboot 66000001" deny
check "grep linode README.md" pass
check "lin linodes reboot 66000001" deny
check "linode-cli linodes ips-list 66000001" pass


echo
echo "abbreviated flags: argparse accepts --tag for --tags"
check "linode-cli linodes update 77000001 --tag urgentc" deny
check "linode-cli linodes update 77000001 --ta cme --ta staging" pass
check "linode-cli linodes create --tags cme --tags staging --root_pas hunter2" deny
check "linode-cli volumes attach 556 --linode_i 66000001" deny

echo
echo "flags before ids, and flag values are not ids"
check "linode-cli linodes reboot --suppress-warnings 77000001" pass
check "linode-cli linodes reboot --suppress-warnings 66000001" deny
check "linode-cli volumes --format nodebalancers delete 555" deny
check "linode-cli --format linodes volumes delete 555" deny
check "linode-cli volumes --format nodebalancers delete 556" pass
check "linode-cli vpcs subnet-create --json 900001 --ipv4 10.0.0.0/24" pass
check "linode-cli vpcs subnet-create --json 900002 --ipv4 10.0.0.0/24" deny

echo
echo "invocations hidden in loops, subshells, background jobs, absolute paths"
check "for id in 10 11; do linode-cli linodes reboot 66000001; done" deny
check "result=\$(linode-cli linodes delete 66000001)" deny
check "( linode-cli linodes delete 66000001 )" deny
check "linode-cli linodes list & linode-cli linodes delete 66000001" deny
check "sudo -u root linode-cli linodes reboot 66000001" deny
check "/opt/homebrew/bin/linode-cli linodes reboot 66000001" deny
check "xargs -I{} linode-cli linodes delete 66000001" deny

echo
echo "quotes preserve argument boundaries"
check "linode-cli linodes update 77000001 --tags='cme --tags staging'" deny
check "linode-cli linodes create --tags cme --tags staging --label 'web && api'" pass

echo
echo "the tags group edits the boundary itself"
check "linode-cli tags create --label cme --linodes 66000001" deny
check "linode-cli tags create --label cme" pass
check "linode-cli tags rm prod" ask
check "linode-cli tags delete urgentc" deny

echo
echo "--help and local help topics never reach the API"
check "linode-cli linodes delete --help" pass
check "linode-cli linodes unfamiliar-action --help" pass
check "linode-cli commands" pass
check "linode-cli linodes --help" pass

echo
echo "one resource, one environment"
check "linode-cli linodes create --tags cme --tags staging --tags prod" deny
check "linode-cli linodes reboot 22000002" deny

echo
echo "ledger creates: the id must reach the recording hook"
check "linode-cli vpcs create --label cme-vpc --json" pass
check "linode-cli vpcs create --label cme-vpc --json > vpc.json" deny
check "linode-cli vpcs create --label a --json && linode-cli databases mysql-create --label b --json" deny

echo
echo "a timed-out lookup refuses, never stays silent"
check "linode-cli linodes reboot 11111111" deny

echo
echo "a broken hook refuses"
broken="$work/broken"; mkdir -p "$broken"
cp "$guard" "$broken/guard-linode.sh"
got=$(decision "$broken/guard-linode.sh" "$(json 'linode-cli linodes delete 66000001')")
if [[ "${got:-pass}" == deny ]]; then
  pass=$((pass + 1)); printf '  ok   %-72s %s\n' "scripts/lib/ missing → deny" deny
else
  fail=$((fail + 1)); printf '  FAIL %-72s got=%s want=deny\n' "scripts/lib/ missing" "${got:-pass}"
fi


echo
echo "shared envs: refused by default; once declared, allowed but always asks when prod is involved"
check "linode-cli linodes reboot 22000003" deny
check_in "$shared" "linode-cli linodes reboot 22000003" ask
check_in "$shared" "linode-cli linodes reboot 22000004" pass
check_in "$shared" "LINODE_ENV=dev linode-cli linodes reboot 22000005" deny
check_in "$shared" "linode-cli linodes create --tags cme --tags staging --tags prod" ask
check_in "$shared" "linode-cli linodes create --tags cme --tags dev --tags staging" pass

echo
echo "the second resource on the line is checked too"
check "linode-cli volumes attach 556 --linode_id 66000001" deny
check "linode-cli volumes attach 556 --linode_id 77000001" pass
check "linode-cli firewalls device-create 999 --id 66000001 --type linode" deny
check "linode-cli linodes create --tags cme --tags staging --firewall_id 66000001" deny

echo
echo "a ledger only speaks for its own project"
check_in "$foreign" "linode-cli vpcs update 900001 --description x" deny

echo
echo "destructive actions do not trust the cache"
check "linode-cli linodes reboot 33000009" pass
check "linode-cli linodes delete 33000009" deny


echo "hook output must always be valid JSON, even with quotes in tags/labels"
check "linode-cli linodes delete 44000009" deny
raw=$(printf '%s' "$(json 'linode-cli linodes delete 44000009')" | bash "$guard")
if printf '%s' "$raw" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  pass=$((pass + 1)); printf '  ok   %-72s %s\n' "valid JSON with a quoted label" valid
else
  fail=$((fail + 1)); printf '  FAIL %-72s %s\n' "valid JSON with a quoted label" invalid
fi


echo
echo "a newline is a command boundary"
check $'linode-cli linodes list\nlinode-cli linodes delete 66000001' deny
check $'linode-cli linodes list\nlinode-cli linodes reboot 77000001' pass

echo
echo "wrappers with arguments — including the plugin's own opgate exec pattern"
check "timeout 10 linode-cli linodes delete 66000001" deny
check 'bash -lc "linode-cli linodes delete 66000001"' deny
check 'eval "linode-cli linodes delete 66000001"' deny
check "opgate exec ROOT_PASS=op://Dev/cme/LINODE_ROOT_PASS -- linode-cli linodes rebuild 66000001 --root_pass hunter2" deny
check "opgate exec ROOT_PASS=op://Dev/cme/LINODE_ROOT_PASS -- linode-cli linodes rebuild 77000001 --root_pass \$ROOT_PASS" pass
check "env -- linode-cli linodes delete 66000001" deny
check "sudo -u root -- linode-cli linodes delete 66000001" deny
check "nice -n 5 linode-cli linodes delete 66000001" deny
check "mystery-wrapper linode-cli linodes delete 66000001" ask
check "cat linode-cli-notes.txt" pass
check "command -v linode-cli" pass

echo
echo "\$( ) and backticks inside double quotes"
check 'result="$(linode-cli linodes delete 66000001)"' deny
check 'echo "$(linode-cli linodes delete 66000001)"' deny
check 'echo "`linode-cli linodes delete 66000001`"' deny

echo
echo "ask must not stop later segments from being checked — deny always wins"
check "LINODE_ENV=prod linode-cli linodes reboot 95747451 && linode-cli linodes reboot 66000001" deny
check "linode-cli lke kubeconfig-view 580172; linode-cli linodes delete 66000001" deny
check "linode-cli lke kubeconfig-view 580172; linode-cli linodes reboot 77000001" ask

echo
echo "dotted flags that point at another resource"
check "linode-cli firewalls create --tags cme --tags staging --label fw --rules.inbound_policy DROP --devices.linodes 66000001" deny
check "linode-cli firewalls create --tags cme --tags staging --label fw --devices.linodes 77000001" pass
check "linode-cli linodes create --tags cme --tags staging --interfaces.purpose vpc --interfaces.vpc_id 900002 --interfaces.subnet_id 1" deny
check "linode-cli linodes create --tags cme --tags staging --interfaces.purpose vpc --interfaces.vpc_id 900001" pass

echo
echo "a target id in a variable is never guessed"
check 'ID=66000001; linode-cli volumes attach 556 --linode_id $ID' deny
check 'linode-cli firewalls device-create 999 --id $ID --type linode' deny
check 'linode-cli linodes create --tags cme --tags staging --firewall_id $FW' deny
check 'linode-cli linodes update 77000001 --tags $TAGS' deny

echo
echo "the time budget covers all lookups, not each one"
rm -rf "$XDG_CACHE_HOME"
CHECK_ENV="LINGATE_DEADLINE=3 LINGATE_BUDGET=3" check "linode-cli volumes attach 557 --linode_id 11111112" deny
rm -rf "$XDG_CACHE_HOME"
CHECK_ENV="LINGATE_DEADLINE=3 LINGATE_BUDGET=20" check "linode-cli volumes attach 557 --linode_id 11111112" pass

echo
echo "sinks are per segment, and only stdout counts"
check "linode-cli lke kubeconfig-view 580172 2>/dev/null" ask
check "linode-cli lke kubeconfig-view 580172 < /dev/null" ask
check "linode-cli lke kubeconfig-view 580172 --text | base64 -d" ask
check "echo x > /dev/null; linode-cli object-storage keys-list" ask
check "linode-cli lke kubeconfig-view 580172 --json | jq -r '.[0].kubeconfig' | base64 -d > ~/.kube/cme.yaml" pass
check "linode-cli object-storage keys-create --label cme --json | jq -r .secret_key | opgate put cme LINODE_OBJ_SECRET" pass
check "linode-cli vpcs create --label x --json 2>/dev/null" pass

echo
echo "--domain is a real field of domains create, not an abbreviation of --domains"
check "linode-cli domains create --tags cme --tags staging --domain cme.example --type master --soa_email a@b.c" pass
check "linode-cli domains update 22000006 --domain x.example" pass

echo
echo "a library that fails to load refuses, never lets through"
broken2="$work/broken2"; mkdir -p "$broken2/lib"
cp "$guard" "$broken2/"; cp "$here/lib/linode.sh" "$broken2/lib/"
printf 'this is not bash (\n' > "$broken2/lib/common.sh"
got=$(decision "$broken2/guard-linode.sh" "$(json 'linode-cli linodes delete 66000001')")
[[ "${got:-pass}" == deny ]]; verdict "lib with a syntax error → deny" $?

echo
echo "fast path, cwd, buckets, line continuation, redirects"
check "x=1;lin linodes delete 66000001" deny
check "(lin linodes delete 66000001)" deny
check_cwd "$nowhere" "linode-cli linodes create --tags cme --tags staging" deny
check_cwd "$proj" "linode-cli linodes create --tags cme --tags staging" pass
check "cd $nowhere && linode-cli linodes create --tags cme --tags staging" deny
check "linode-cli object-storage bucket-delete sg-sin-1 cme-bucket" pass
check "linode-cli object-storage bucket-delete sg-sin-1 other-bucket" deny
check $'linode-cli linodes create --tags cme \\\n  --tags staging --label x' pass
check "linode-cli linodes list > out.txt; linode-cli linodes create --tags cme --tags staging > out2.txt" pass
check "linode-cli linodes reboot 66000001 > out.txt" deny
check "linode-cli vpcs list --json && linode-cli vpcs create --label x --json" deny
raw=$(printf '%s' "$(json 'linode-cli linodes reboot 94162441')" | bash "$guard")
printf '%s' "$raw" | grep -q 'worker node of lke 580172'; verdict "the message names the LKE worker's cluster" $?

echo
echo "record-owned: --help is not a create, foreign ledgers are not taken over, buckets, nested ids"
rec="$here/record-owned.sh"
post() { python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"tool_response":{"stdout":sys.argv[2]},"cwd":sys.argv[3]}))' "$1" "$2" "$3"; }
rp="$work/recproj"; mkdir -p "$rp/.linode"; cp "$proj/.linode/project.json" "$rp/.linode/"
printf '{"tag": "cme", "owned": []}\n' > "$rp/.linode/owned.json"
post 'linode-cli vpcs create --help' '[{"id": 123}]' "$rp" | bash "$rec" >/dev/null
! grep -q '"123"' "$rp/.linode/owned.json"; verdict "--help records nothing" $?
post 'linode-cli object-storage bucket-create --label cme-b --region sg-sin-1 --json' '[{"label": "cme-b", "region": "sg-sin-1"}]' "$rp" | bash "$rec" >/dev/null
grep -q 'sg-sin-1/cme-b' "$rp/.linode/owned.json"; verdict "a bucket is recorded as region/label" $?
post 'linode-cli vpcs create --label v --json' '[{"id": 900123, "subnets": [{"id": 900001}]}]' "$rp" | bash "$rec" >/dev/null
grep -q '"900123"' "$rp/.linode/owned.json" && ! grep -q '"900001"' "$rp/.linode/owned.json"; verdict "the parent id, not the child subnet id" $?
out=$(post 'linode-cli vpcs create --label v --json' '[{"id": 700}]' "$foreign" | bash "$rec")
grep -q '"tag": "urgentc"' "$foreign/.linode/owned.json" && ! grep -q '"700"' "$foreign/.linode/owned.json" && printf '%s' "$out" | grep -q 'could NOT record'
verdict "another project's ledger is not overwritten" $?

echo
echo "lingate: ls survives an API failure, disown after reformatting, init sets a foreign ledger aside"
LG="$here/../bin/lingate"
lp="$work/lgproj"; mkdir -p "$lp"; ( cd "$lp" && git init -q . )
( cd "$lp" && CLAUDE_PROJECT_DIR="$lp" "$LG" init cme --envs staging,prod >/dev/null 2>&1 )
( cd "$lp" && CLAUDE_PROJECT_DIR="$lp" "$LG" ls >/dev/null 2>&1 ); verdict "lingate ls exits 0 even when linode-cli fails" $?
( cd "$lp" && CLAUDE_PROJECT_DIR="$lp" "$LG" own vpcs 1 --env staging >/dev/null 2>&1 )
python3 -c 'import json,sys; f=sys.argv[1]; d=json.load(open(f)); json.dump(d, open(f,"w"), indent=4)' "$lp/.linode/owned.json"
( cd "$lp" && CLAUDE_PROJECT_DIR="$lp" "$LG" disown vpcs 1 >/dev/null 2>&1 )
! grep -q '"1"' "$lp/.linode/owned.json"; verdict "disown still removes after the file is reformatted" $?
printf '{"tag": "urgentc", "owned": [{"type": "vpcs", "id": "5", "env": "prod", "label": "x", "at": "t"}]}\n' > "$lp/.linode/owned.json"
( cd "$lp" && CLAUDE_PROJECT_DIR="$lp" "$LG" own vpcs 6 --env staging >/dev/null 2>&1 ); [[ $? -ne 0 ]]; verdict "own refuses to write into another project's ledger" $?
( cd "$lp" && CLAUDE_PROJECT_DIR="$lp" "$LG" init cme --envs staging,prod >/dev/null 2>&1 )
grep -q '"tag": "cme"' "$lp/.linode/owned.json" && [[ -f "$lp/.linode/owned.json.urgentc.bak" ]] && ! grep -q '"5"' "$lp/.linode/owned.json"
verdict "init moves a foreign ledger to .bak and creates a new one" $?


echo
echo "Codex low: the -rm alias, tags in a protected env, a broken lexer, empty HOME"
check "linode-cli placement group-rm 8801" pass
check "linode-cli placement group-rm 8809" deny
check "linode-cli placement group-delete 8801" pass
check "LINODE_ENV=prod linode-cli tags create --label prod" ask
# The lexer is awk; when it produces nothing the guard must refuse, not conclude
# there was nothing to guard. (bash 3.2 quietly falls back when TMPDIR is bad,
# so a broken here-string cannot be simulated — a broken lexer can.)
noawk="$work/noawk"; mkdir -p "$noawk"; printf '#!/bin/sh\nexit 1\n' > "$noawk/awk"; chmod 755 "$noawk/awk"
# A minimal PATH: the real one may contain spaces, which the unquoted CHECK_ENV
# expansion in decision() would split. Without jq on it the payload falls back
# to awk too, which is an equally valid fail-closed path.
CHECK_ENV="PATH=$noawk:/usr/bin:/bin" check "linode-cli linodes reboot 77000001" deny
raw=$(printf '%s' "$(json 'linode-cli linodes reboot 77000001')" | env PATH="$noawk:/usr/bin:/bin" bash "$guard")
printf '%s' "$raw" | grep -Eq 'could not split the command line|could not be read'; verdict "a broken lexer → refused for the right reason" $?
( cd "$lp" && env -u HOME -u XDG_CACHE_HOME CLAUDE_PROJECT_DIR="$lp" "$LG" whoami >/dev/null 2>&1 ); verdict "lingate runs with HOME and XDG_CACHE_HOME unset" $?
# init must not leave a half-declared project when the ledger cannot be written
lq="$work/lqproj"; mkdir -p "$lq/.linode"; ( cd "$lq" && git init -q . )
printf '{"tag": "urgentc", "owned": []}\n' > "$lq/.linode/owned.json"; chmod 555 "$lq/.linode"
( cd "$lq" && CLAUDE_PROJECT_DIR="$lq" "$LG" init cme --envs staging,prod >/dev/null 2>&1 ); rc=$?
chmod 755 "$lq/.linode"
[[ $rc -ne 0 && ! -f "$lq/.linode/project.json" ]]; verdict "a failed init leaves no half-written project.json" $?

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
