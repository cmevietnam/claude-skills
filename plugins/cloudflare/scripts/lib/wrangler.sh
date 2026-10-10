#!/usr/bin/env bash
# Reading a wrangler command line. Sourced by scripts/guard-cloudflare.sh.
#
# The command table was generated from `wrangler <path> --help` on wrangler
# 4.61.0 (all 244 command paths) and classified by hand. When wrangler and this
# file disagree, wrangler is right: an unknown path is refused, and the refusal
# says to update this table.

# --- command table ------------------------------------------------------------
# path|kind|target
#
# kind:   read    reaches the API but changes nothing
#         local   never reaches the API (dev servers, scaffolding, codegen)
#         cli     changes wrangler's own login, not a resource
#         secret  prints a credential to stdout
#         write   changes a resource
#         rlocal  writes, but to local state unless --remote is given
#         ask     a write the guard cannot attribute to a project (account-level
#                 objects, id-addressed objects); a human confirms
# target: what the boundary check reads, see wr_targets
WR_TABLE='docs|local|-
complete|local|-
init|local|-
dev|local|-
types|local|-
setup|ask|-
login|cli|-
logout|cli|-
whoami|read|-
auth token|secret|-
deploy|write|worker
delete|write|worker
rollback|write|worker
tail|read|-
deployments list|read|-
deployments status|read|-
versions list|read|-
versions view|read|-
versions upload|write|worker
versions deploy|write|worker
versions secret put|write|worker
versions secret bulk|write|worker
versions secret delete|write|worker
versions secret list|read|-
secret put|write|worker
secret bulk|write|worker
secret delete|write|worker
secret list|read|-
triggers deploy|write|worker
r2 bucket create|write|pos
r2 bucket delete|write|pos
r2 bucket list|read|-
r2 bucket info|read|-
r2 bucket update storage-class|write|pos
r2 bucket catalog enable|write|pos
r2 bucket catalog disable|write|pos
r2 bucket catalog get|read|-
r2 bucket catalog compaction|write|pos
r2 bucket catalog snapshot-expiration|write|pos
r2 bucket cors set|write|pos
r2 bucket cors delete|write|pos
r2 bucket cors list|read|-
r2 bucket dev-url enable|write|pos
r2 bucket dev-url disable|write|pos
r2 bucket dev-url get|read|-
r2 bucket domain add|write|domain
r2 bucket domain remove|write|domain
r2 bucket domain update|write|domain
r2 bucket domain get|read|-
r2 bucket domain list|read|-
r2 bucket lifecycle add|write|pos
r2 bucket lifecycle remove|write|pos
r2 bucket lifecycle set|write|pos
r2 bucket lifecycle list|read|-
r2 bucket lock add|write|pos
r2 bucket lock remove|write|pos
r2 bucket lock set|write|pos
r2 bucket lock list|read|-
r2 bucket notification create|write|pos
r2 bucket notification delete|write|pos
r2 bucket notification get|read|-
r2 bucket notification list|read|-
r2 bucket sippy enable|write|pos
r2 bucket sippy disable|write|pos
r2 bucket sippy get|read|-
r2 object get|read|-
r2 object put|rlocal|bucket
r2 object delete|rlocal|bucket
r2 sql query|read|-
kv namespace create|write|pos
kv namespace delete|write|kv
kv namespace rename|write|kv
kv namespace list|read|-
kv key put|rlocal|kv
kv key delete|rlocal|kv
kv key get|read|-
kv key list|read|-
kv bulk put|rlocal|kv
kv bulk delete|rlocal|kv
kv bulk get|read|-
d1 create|write|pos
d1 delete|write|d1
d1 execute|rlocal|d1
d1 export|read|-
d1 info|read|-
d1 list|read|-
d1 insights|read|-
d1 migrations create|local|-
d1 migrations list|read|-
d1 migrations apply|rlocal|d1
d1 time-travel info|read|-
d1 time-travel restore|write|d1
queues create|write|pos
queues delete|write|pos
queues update|write|pos
queues purge|write|pos
queues pause-delivery|write|pos
queues resume-delivery|write|pos
queues info|read|-
queues list|read|-
queues consumer add|write|pos2
queues consumer remove|write|pos2
queues consumer worker add|write|pos2
queues consumer worker remove|write|pos2
queues consumer http add|write|pos
queues consumer http remove|write|pos
queues subscription create|write|pos
queues subscription delete|write|pos
queues subscription update|write|pos
queues subscription get|read|-
queues subscription list|read|-
pages deploy|write|pages
pages deployment create|write|pages
pages deployment list|read|-
pages deployment tail|read|-
pages project create|write|pos
pages project delete|write|pos
pages project list|read|-
pages secret put|write|pages
pages secret bulk|write|pages
pages secret delete|write|pages
pages secret list|read|-
pages dev|local|-
pages functions build|local|-
pages download config|read|-
hyperdrive create|write|pos
hyperdrive delete|ask|id
hyperdrive update|ask|id
hyperdrive get|read|-
hyperdrive list|read|-
vectorize create|write|pos
vectorize delete|write|pos
vectorize insert|write|pos
vectorize upsert|write|pos
vectorize delete-vectors|write|pos
vectorize create-metadata-index|write|pos
vectorize delete-metadata-index|write|pos
vectorize get|read|-
vectorize info|read|-
vectorize list|read|-
vectorize query|read|-
vectorize get-vectors|read|-
vectorize list-vectors|read|-
vectorize list-metadata-index|read|-
workflows delete|write|pos
workflows trigger|write|pos
workflows describe|read|-
workflows list|read|-
workflows instances describe|read|-
workflows instances list|read|-
workflows instances pause|write|pos
workflows instances resume|write|pos
workflows instances restart|write|pos
workflows instances terminate|write|pos
workflows instances send-event|write|pos
containers build|local|-
containers push|ask|account
containers delete|ask|id
containers images delete|ask|account
containers images list|read|-
containers info|read|-
containers list|read|-
dispatch-namespace create|write|pos
dispatch-namespace delete|write|pos
dispatch-namespace rename|write|pos
dispatch-namespace get|read|-
dispatch-namespace list|read|-
pipelines create|write|pos
pipelines delete|write|pos
pipelines update|write|pos
pipelines setup|ask|account
pipelines get|read|-
pipelines list|read|-
pipelines sinks create|write|pos
pipelines sinks delete|write|pos
pipelines sinks get|read|-
pipelines sinks list|read|-
pipelines streams create|write|pos
pipelines streams delete|write|pos
pipelines streams get|read|-
pipelines streams list|read|-
pubsub broker create|write|pos
pubsub broker delete|write|pos
pubsub broker update|write|pos
pubsub broker issue|write|pos
pubsub broker revoke|write|pos
pubsub broker unrevoke|write|pos
pubsub broker describe|read|-
pubsub broker list|read|-
pubsub broker public-keys|read|-
pubsub broker show-revocations|read|-
pubsub namespace create|write|pos
pubsub namespace delete|write|pos
pubsub namespace describe|read|-
pubsub namespace list|read|-
secrets-store store create|write|pos
secrets-store store delete|ask|id
secrets-store store list|read|-
secrets-store secret create|ask|id
secrets-store secret update|ask|id
secrets-store secret delete|ask|id
secrets-store secret duplicate|ask|id
secrets-store secret get|read|-
secrets-store secret list|read|-
vpc service create|write|pos
vpc service delete|ask|id
vpc service update|ask|id
vpc service get|read|-
vpc service list|read|-
ai models|read|-
ai finetune list|read|-
ai finetune create|ask|account
cert upload mtls-certificate|ask|account
cert upload certificate-authority|ask|account
cert delete|ask|account
cert list|read|-
mtls-certificate upload|ask|account
mtls-certificate delete|ask|account
mtls-certificate list|read|-'

# Options that take a value, so the word after them is not a positional. Taken
# from the same --help sweep: every option typed [string], [number], [array] or
# [choices], plus the option groups the sweep's parser skipped (hyperdrive's
# origin fields). An option missing here is read as boolean, which can only
# shift a value into the positionals - and a stray positional fails the name
# check, so the error is a refusal, never a pass.
WR_VALFLAGS=" -c -e -J -s -f -b -k -m -n -o -t --config --cwd --env --env-file \
--abort-multipart-days --access-key-id --account --ai --alias --assets --batch-size \
--batch-timeout --binding --bookmark --branch --bucket --build-metadata-path \
--build-output-directory --ca-cert --ca-certificate-id --ca-certificate-uuid \
--cache-control --callback-host --callback-port --catalog-token --cc --cd --ce --cert \
--cl --client-email --client-id --command --comment --commit-hash --commit-message \
--compatibility-date --compatibility-flag --compatibility-flags --compression \
--containers-rollout --content-disposition --content-encoding --content-language \
--content-type --cors-origin --count --ct --cursor --d1 --dead-letter-queue --define \
--delivery-delay-secs --description --dimensions --dispatch-namespace --do --domain \
--domains --env-interface --environment --event-type --event-types --events --exp \
--expiration --expire-date --expire-days --expires --external --fallback-service --file \
--filter --format --header --host --https-cert-path --https-key-path \
--ia-transition-date --ia-transition-days --id --ids --inspector-ip --inspector-port \
--ip --jsx-factory --jsx-fragment --jti --jurisdiction --key --kv --limit \
--local-protocol --local-upstream --location --log-level --max-concurrency --message \
--message-retention-period-secs --message-retries --metadata --metafile --method \
--metric --min-tls --model-name --mtls-certificate-id --mtls-certificate-uuid --name \
--namespace --namespace-id --new-name --ns --number --old-asset-ttl --on-publish-url \
--origin-connection-limit --outdir --outfile --output --output-config-path \
--output-routes-path --page --partitioning --path --path-to-docker --payload \
--per-page --percentage --persist-to --pipeline-id --port --prefix --preset \
--preview-alias --private-key --production-branch --project --project-directory \
--project-name --propertyName --provider --proxy --queue --r2 --r2-access-key-id \
--r2-secret-access-key --region --retention-date --retention-days --retry-delay-secs \
--return-metadata --roll-interval --roll-size --route --routes --rule --sampling-rate \
--schedule --schedules --schema-file --scopes --script-path --search --secret-access-key \
--secret-id --service --service-account-key-file --sort-by --sort-direction --sort-type \
--source --sql --sql-file --sslmode --status --storage-class --suffix --table --tag \
--target-row-group-size --time-period --timestamp --top-k --triggers \
--truncate-output-limit --tsconfig --ttl --type --upstream-protocol --value --var \
--vector --vector-id --version-id --version-metadata --visibility-timeout-secs \
--worker-name --workflow-name --zone-id --connection-string --origin-password \
--password --origin-host --origin-port --origin-scheme --origin-user --user \
--database --access-client-id --access-client-secret --max-age --swr "

# Options whose value is a credential. Written literally, the value lands in the
# transcript, the shell history and the process table at once.
WR_SECRETFLAGS=" --value --connection-string --origin-password --password \
--access-client-secret --secret-access-key --r2-secret-access-key --catalog-token \
--private-key "

# wr_lookup <path> — prints "kind|target" for an exact path, or fails.
wr_lookup() {
  local line
  while IFS= read -r line; do
    [[ "${line%%|*}" == "$1" ]] && { printf '%s' "${line#*|}"; return 0; }
  done <<< "$WR_TABLE"
  return 1
}

# --- parsing ------------------------------------------------------------------

# Booleans the guard acts on, read the way yargs reads them: `--x`, `--x=false`,
# `--x false` (a following literal true/false is consumed), `--no-x`, and the
# LAST occurrence wins. Reading `--dry-run false` as a dry run once let a real
# deploy of another project's Worker through unchecked.
WR_BOOLS=" help version dry-run remote local "

# parse_wrangler — reads SH_WORDS from SH_START + 1. Sets:
#   W_CMD W_KIND W_TARGET   the command path and its table entry ("" if unknown)
#   W_ARGS[]                positionals after the command path
#   W_CONFIG W_CWD W_ENV    -c, --cwd, -e (or CLOUDFLARE_ENV=)
#   W_ENVFILES[]            --env-file values
#   W_NAME W_NAMES          --name (W_NAMES counts distinct values given)
#   W_PROJECT W_BINDING W_NSID W_ZONEID W_DISPATCH   name-bearing options
#   W_ROUTES[] W_DOMAINS[]  every --route/--routes and --domain/--domains value
#   W_REMOTE W_LOCAL W_DRYRUN W_HELP                  final boolean values (0/1)
#   W_SECRET_LIT            the first credential option given a literal value
#   W_FIRSTPOS              the first positional, even when no path matched
parse_wrangler() {
  W_CMD=""; W_KIND=""; W_TARGET=""; W_ARGS=(); W_CONFIG=""; W_CWD=""; W_ENV=""
  W_ENVFILES=(); W_NAME=""; W_NAMES=0; W_PROJECT=""; W_BINDING=""; W_NSID=""
  W_ZONEID=""; W_DISPATCH=""; W_ROUTES=(); W_DOMAINS=(); W_REMOTE=0; W_LOCAL=0
  W_DRYRUN=0; W_HELP=0; W_SECRET_LIT=""; W_FIRSTPOS=""
  local n=${#SH_WORDS[@]} j=$((SH_START + 1)) t f val a b bv
  local -a pos=()
  for a in ${SH_ASSIGNS[@]+"${SH_ASSIGNS[@]}"}; do
    case "$a" in CLOUDFLARE_ENV=*) W_ENV=${a#CLOUDFLARE_ENV=} ;; esac
  done
  while (( j < n )); do
    t=${SH_WORDS[j]}
    if [[ "$t" == -- ]]; then
      j=$((j + 1))
      while (( j < n )); do pos[${#pos[@]}]="${SH_WORDS[j]}"; j=$((j + 1)); done
      break
    fi
    if [[ "$t" == -?* ]]; then
      f=${t%%=*}; val=""
      # --- booleans ---
      b=""; bv=1
      case "$f" in
        -h) b=help ;; -v) b=version ;;
        --no-*) b=${f#--no-}; bv=0 ;;
        --*) b=${f#--} ;;
      esac
      if [[ -n "$b" && "$WR_BOOLS" == *" $b "* ]]; then
        if [[ "$t" == *=* ]]; then
          [[ "${t#*=}" == false ]] && bv=0
        elif [[ "$f" != --no-* ]] && [[ "${SH_WORDS[j+1]:-}" == true || "${SH_WORDS[j+1]:-}" == false ]]; then
          [[ "${SH_WORDS[j+1]}" == false ]] && bv=0
          j=$((j + 1))
        fi
        case "$b" in
          help|version) W_HELP=$bv ;;
          dry-run)      W_DRYRUN=$bv ;;
          remote)       W_REMOTE=$bv ;;
          local)        W_LOCAL=$bv ;;
        esac
        j=$((j + 1)); continue
      fi
      # --- options with values ---
      if [[ "$t" == *=* ]]; then
        val=${t#*=}
      elif [[ "$WR_VALFLAGS" == *" $f "* ]]; then
        val="${SH_WORDS[j+1]:-}"; j=$((j + 1))
      fi
      case "$f" in
        -c|--config)       W_CONFIG="$val" ;;
        --cwd)             W_CWD="$val" ;;
        -e|--env)          W_ENV="$val" ;;
        --env-file)        W_ENVFILES[${#W_ENVFILES[@]}]="$val" ;;
        --name)            [[ "$val" == "$W_NAME" ]] || W_NAMES=$((W_NAMES + 1)); W_NAME="$val" ;;
        --project-name)    W_PROJECT="$val" ;;
        --binding)         W_BINDING="$val" ;;
        --namespace-id)    W_NSID="$val" ;;
        --domain|--domains) W_DOMAINS[${#W_DOMAINS[@]}]="$val" ;;
        --route|--routes)  W_ROUTES[${#W_ROUTES[@]}]="$val" ;;
        --zone-id)         W_ZONEID="$val" ;;
        --dispatch-namespace) W_DISPATCH="$val" ;;
      esac
      if [[ "$WR_SECRETFLAGS" == *" $f "* ]] && is_literal "$val" && [[ -z "$W_SECRET_LIT" ]]; then
        W_SECRET_LIT="$f"
      fi
      j=$((j + 1)); continue
    fi
    pos[${#pos[@]}]="$t"
    j=$((j + 1))
  done

  W_FIRSTPOS="${pos[0]:-}"
  # The longest prefix of the positionals that names a command.
  local k=${#pos[@]} p i entry
  (( k > 4 )) && k=4
  while (( k > 0 )); do
    p="${pos[0]}"; i=1
    while (( i < k )); do p="$p ${pos[i]}"; i=$((i + 1)); done
    if entry=$(wr_lookup "$p"); then
      W_CMD="$p"; W_KIND=${entry%%|*}; W_TARGET=${entry#*|}
      i=$k
      while (( i < ${#pos[@]} )); do W_ARGS[${#W_ARGS[@]}]="${pos[i]}"; i=$((i + 1)); done
      return 0
    fi
    k=$((k - 1))
  done
  return 0
}

# --- the config file wrangler will read -----------------------------------------

# The directory wrangler runs in: --cwd, resolved against the Bash cwd.
wr_basedir() {
  local cwd="$1"
  if [[ -z "$W_CWD" ]]; then printf '%s' "$cwd"
  elif [[ "$W_CWD" == /* ]]; then printf '%s' "$W_CWD"
  else printf '%s/%s' "$cwd" "$W_CWD"; fi
}

# _wr_findup <dir> <relative path> — the nearest <dir>/<path> walking up.
_wr_findup() {
  local dir="$1"
  while :; do
    [[ -f "$dir/$2" ]] && { printf '%s' "$dir/$2"; return 0; }
    [[ "$dir" == / || -z "$dir" ]] && return 1
    dir=${dir%/*}; [[ -z "$dir" ]] && dir=/
  done
}

# wr_find_config <basedir> — sets WR_CFG (path or empty) and WR_CFG_WHY (why it
# could not be determined). Mirrors wrangler 4.61 (cli.js, findWranglerConfig):
#   - -c wins;
#   - else ONE upward walk PER FILE NAME, in order wrangler.json, then
#     wrangler.jsonc, then wrangler.toml: a wrangler.json in any parent beats a
#     wrangler.toml right here;
#   - a `.wrangler/deploy/config.json` redirect (written by framework builds),
#     found by its own upward walk, replaces that result with its configPath.
# For `deploy` and `versions upload` an entry script given as a positional moves
# the search to the script's directory (observed on 4.61: `wrangler deploy
# ../other/src/x.js` deployed other/'s Worker).
wr_find_config() {
  local base="$1" dir f redirect target
  WR_CFG=""; WR_CFG_WHY=""
  if [[ -n "$W_CONFIG" ]]; then
    if ! is_literal "$W_CONFIG"; then WR_CFG_WHY="the -c value '$W_CONFIG' comes from the shell"; return 1; fi
    if [[ "$W_CONFIG" == /* ]]; then f="$W_CONFIG"; else f="$base/$W_CONFIG"; fi
    [[ -f "$f" ]] || { WR_CFG_WHY="the config file $f does not exist"; return 1; }
    WR_CFG="$f"; return 0
  fi
  case "$W_CMD" in
    deploy|'versions upload')
      if [[ -n "${W_ARGS[0]:-}" ]]; then
        is_literal "${W_ARGS[0]}" || { WR_CFG_WHY="the entry script '${W_ARGS[0]}' comes from the shell, and wrangler looks for its config next to it"; return 1; }
        if [[ "${W_ARGS[0]}" == /* ]]; then base=$(dirname -- "${W_ARGS[0]}")
        else base=$(dirname -- "$base/${W_ARGS[0]}"); fi
      fi ;;
  esac
  dir=$(cd -- "$base" 2>/dev/null && pwd -P) || { WR_CFG_WHY="the directory $base does not exist"; return 1; }
  if redirect=$(_wr_findup "$dir" .wrangler/deploy/config.json); then
    target=$(flatten_config "$redirect" json | flat_get configPath | head -1)
    [[ -n "$target" ]] || { WR_CFG_WHY="$redirect redirects wrangler but names no configPath"; return 1; }
    [[ "$target" == /* ]] || target="$(dirname -- "$redirect")/$target"
    [[ -f "$target" ]] || { WR_CFG_WHY="$redirect redirects wrangler to $target, which does not exist (build first, or pass -c)"; return 1; }
    WR_CFG="$target"; return 0
  fi
  for f in wrangler.json wrangler.jsonc wrangler.toml; do
    WR_CFG=$(_wr_findup "$dir" "$f") && return 0
  done
  WR_CFG=""
  return 0
}

# The Worker a command acts on: --name, else the config's name for the chosen
# environment. Wrangler names an environment's Worker "<name>-<env>" unless the
# environment sets its own name.
wr_worker_name() {
  local flat="$1" n
  if [[ -n "$W_NAME" ]]; then printf '%s' "$W_NAME"; return 0; fi
  [[ -n "$flat" ]] || return 1
  if [[ -n "$W_ENV" ]]; then
    n=$(printf '%s\n' "$flat" | flat_get "env/$W_ENV/name" | head -1)
    if [[ -n "$n" ]]; then printf '%s' "$n"; return 0; fi
    n=$(printf '%s\n' "$flat" | flat_get name | head -1)
    [[ -n "$n" ]] && { printf '%s-%s' "$n" "$W_ENV"; return 0; }
    return 1
  fi
  n=$(printf '%s\n' "$flat" | flat_get name | head -1)
  [[ -n "$n" ]] && { printf '%s' "$n"; return 0; }
  return 1
}

# CLOUDFLARE_ACCOUNT_ID lines from the .env files wrangler loads for itself:
# .env, .env.local, .env.<env> and .env.<env>.local, unless --env-file replaces
# that list. Both the run directory and the config's directory are read: being
# strict about a file wrangler might not load costs a refusal, never a leak.
# wr_envfile_accounts <dir>... — prints "file<TAB>value".
wr_envfile_accounts() {
  local d f v
  local -a files=()
  if (( ${#W_ENVFILES[@]} > 0 )); then
    for f in "${W_ENVFILES[@]}"; do
      [[ "$f" == /* ]] || f="$1/$f"
      files[${#files[@]}]="$f"
    done
  else
    for d in "$@"; do
      [[ -n "$d" ]] || continue
      files[${#files[@]}]="$d/.env"; files[${#files[@]}]="$d/.env.local"
      if [[ -n "$W_ENV" ]]; then
        files[${#files[@]}]="$d/.env.$W_ENV"; files[${#files[@]}]="$d/.env.$W_ENV.local"
      fi
    done
  fi
  for f in "${files[@]}"; do
    [[ -r "$f" ]] || continue
    while IFS= read -r v; do
      v=${v#*=}; v=${v%%#*}; v=${v//[[:space:]]/}; v=${v//\"/}; v=${v//\'/}
      printf '%s\t%s\n' "$f" "$v"
    done < <(grep -E '^[[:space:]]*(export[[:space:]]+)?CLOUDFLARE_ACCOUNT_ID[[:space:]]*=' "$f" 2>/dev/null)
  done
}
