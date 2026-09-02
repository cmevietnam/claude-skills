#!/usr/bin/env bash
# Tests for the klocal libraries and CLI. No cluster, no network, no container
# engine — kubectl, docker and nerdctl are all stubbed on PATH.
#
#   bash plugins/k8s-local/scripts/test-klocal.sh
#
# Every assertion demands a specific string that only appears when the code under
# test actually ran. An assertion phrased as an absence cannot tell a passing run
# from a run that never happened, so `want_absent` additionally requires a marker
# proving execution reached the point being tested, and empty output is always a
# hard failure.
#
# --self-check deliberately breaks three assertions and requires each to go red.
# A harness that cannot fail is not evidence.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
plugin=$(dirname "$here")
KLOCAL="$plugin/bin/klocal"

pass=0
fail=0

ok() { printf '  ok   %-52s %s\n' "$1" "${2:-}"; pass=$((pass + 1)); }
bad() {
  printf '  FAIL %-52s %s\n' "$1" "$2"
  fail=$((fail + 1))
}

# Output must contain <want>. Empty output fails first and explicitly, so a
# command that never ran can never be read as agreement.
want() { # <label> <want> <got>
  if [ -z "$3" ]; then
    bad "$1" "EMPTY OUTPUT — the command produced nothing; it likely never ran"
    return
  fi
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "want substring [$2] got [$(printf '%s' "$3" | tr '\n' '/' | cut -c1-90)]" ;;
  esac
}

# Output must NOT contain <unwanted>, but must contain <proof> — the marker that
# shows execution reached the code under test. Without the proof, silence from an
# unrelated upstream crash would score as a pass.
want_absent() { # <label> <unwanted> <proof> <got>
  if [ -z "$4" ]; then
    bad "$1" "EMPTY OUTPUT — nothing ran, so absence proves nothing"
    return
  fi
  case "$4" in
    *"$3"*) : ;;
    *)
      bad "$1" "missing execution marker [$3] — cannot trust the absence check"
      return
      ;;
  esac
  case "$4" in
    *"$2"*) bad "$1" "unwanted substring [$2] present" ;;
    *) ok "$1" ;;
  esac
}

want_status() { # <label> <want-code> <got-code>
  if [ "$2" = "$3" ]; then ok "$1" "exit=$3"; else bad "$1" "want exit $2 got $3"; fi
}

# --- sandbox ---------------------------------------------------------------
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export HOME="$work/home" # never touch the real ~
mkdir -p "$HOME" "$work/stub"
export PATH="$work/stub:$PATH"

# Stub kubectl. Behaviour is driven by files in $work so each test can shape it.
cat >"$work/stub/kubectl" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "config current-context") cat "$KL_TEST_CTX_FILE" 2>/dev/null; exit 0 ;;
  "cluster-info "*|"cluster-info") exit "${KL_TEST_CLUSTER_RC:-0}" ;;
esac
case "$*" in
  "get ingressclass"*) exit "${KL_TEST_INGRESSCLASS_RC:-0}" ;;
  "get secret"*)
    [ -n "${KL_TEST_SECRET_VALUE:-}" ] || exit 1
    printf '%s' "$KL_TEST_SECRET_VALUE" | base64
    exit 0 ;;
  "get deploy"*) printf '%s' "${KL_TEST_LIVE_ENV:-}"; exit 0 ;;
  "get ingress"*) printf '%s' "${KL_TEST_INGRESS_HOSTS:-}"; exit 0 ;;
  "get namespace"*) exit "${KL_TEST_NS_RC:-0}" ;;
esac
exit 0
STUB
chmod 755 "$work/stub/kubectl"

export KL_TEST_CTX_FILE="$work/ctx"
printf 'rancher-desktop\n' >"$KL_TEST_CTX_FILE"

# shellcheck source=lib/common.sh
. "$plugin/scripts/lib/common.sh"
# shellcheck source=lib/cluster.sh
. "$plugin/scripts/lib/cluster.sh"

SELF_CHECK=0
[ "${1:-}" = "--self-check" ] && SELF_CHECK=1

# ===========================================================================
printf '\ncontext guard\n'
# ===========================================================================
for ctx in rancher-desktop docker-desktop minikube colima kind-dev k3d-mycluster; do
  if kl_context_is_local "$ctx"; then ok "local context accepted: $ctx"; else
    bad "local context accepted: $ctx" "was refused"
  fi
done

# The whole point of the guard. A cloud context must never be treated as local,
# and neither must a production name that merely contains the word "local".
for ctx in gke_proj_us-central1_prod arn:aws:eks:us-east-1:1:cluster/prod \
  cme-cluster localstack-prod do-sfo3-k8s "" ; do
  if kl_context_is_local "$ctx"; then
    bad "remote context refused: ${ctx:-<empty>}" "was ACCEPTED — this would deploy to it"
  else ok "remote context refused: ${ctx:-<empty>}"; fi
done

# End to end through the CLI: a remote context must abort before anything else.
printf 'gke_proj_us-central1_prod\n' >"$KL_TEST_CTX_FILE"
mkdir -p "$work/proj/.k8s-local"
cat >"$work/proj/.k8s-local/project.json" <<'JSON'
{ "project": "demo", "namespace": "demo-local", "manifests": "deploy/k8s-local",
  "image": { "name": "demo-api:local", "context": "api" },
  "workloads": { "app": "demo-api", "db": "demo-postgres", "cache": "demo-redis" } }
JSON
out=$(cd "$work/proj" && "$KLOCAL" up 2>&1)
rc=$?
want "up refuses a remote context" "REFUSING" "$out"
want "refusal names the offending context" "gke_proj_us-central1_prod" "$out"
want_status "up exits non-zero on a remote context" 1 "$rc"
# It must refuse BEFORE building, or it has already run a Dockerfile against the
# wrong cluster's engine by the time it complains.
want_absent "refusal happens before any build" "==> build" "REFUSING" "$out"

printf 'rancher-desktop\n' >"$KL_TEST_CTX_FILE"

# ===========================================================================
printf '\ningress class\n'
# ===========================================================================
# These must be exported, not merely assigned: the stub reads them from its
# environment, and `VAR=x out=$(...)` sets a shell variable the stub never sees.
export KL_TEST_INGRESSCLASS_RC=0
out=$(kl_check_ingressclass traefik 2>&1)
want "present ingressclass is reported" "ingressclass: traefik" "$out"

export KL_TEST_INGRESSCLASS_RC=1
out=$(kl_check_ingressclass traefik 2>&1)
rc=$?
want "missing ingressclass warns" "WARNING: no IngressClass 'traefik'" "$out"
want "warning explains the consequence" "no hostname will route" "$out"
# A warning, never a failure: the stack still runs and port-forward still works.
want_status "missing ingressclass does not abort" 0 "$rc"
unset KL_TEST_INGRESSCLASS_RC

# ===========================================================================
printf '\nengine probe (socket, not binary)\n'
# ===========================================================================
mk_engine() { # <name> <exit-code-for-info>
  cat >"$work/stub/$1" <<STUB
#!/usr/bin/env bash
case "\$*" in *info*) exit $2 ;; esac
echo "$1 build ran: \$*"
exit 0
STUB
  chmod 755 "$work/stub/$1"
}

# The exact Rancher-Desktop-on-moby trap: nerdctl is installed and on PATH, but
# its socket check fails. Probing for the binary alone would pick nerdctl here
# and every build would go to an image store k3s never reads.
mk_engine nerdctl 1
mk_engine docker 0
want "nerdctl present but socket dead -> docker" "docker" "$(kl_detect_engine)"
out=$(kl_build_image demo:local "$work" 2>&1)
want "build actually invoked docker" "docker build ran:" "$out"
want "build tagged the configured image" "-t demo:local" "$out"

mk_engine nerdctl 0
want "nerdctl socket alive -> nerdctl" "nerdctl" "$(kl_detect_engine)"
out=$(kl_build_image demo:local "$work" 2>&1)
want "nerdctl build targets the k8s.io namespace" "--namespace k8s.io" "$out"

rm -f "$work/stub/nerdctl" "$work/stub/docker"
want "no engine at all -> empty" "" "$(kl_detect_engine)x" # x proves it ran
out=$(kl_build_image demo:local "$work" 2>&1)
rc=$?
want "no engine is a clear failure" "no working container engine" "$out"
want_status "no engine exits non-zero" 1 "$rc"
mk_engine docker 0

# ===========================================================================
printf '\nsecret reuse\n'
# ===========================================================================
gen() { printf 'FRESHLY-GENERATED'; }

export KL_TEST_SECRET_VALUE="existing-redis-password"
out=$(kl_keep_or_generate demo-local demo-api-secrets REDIS_PASSWORD gen)
want "existing secret value is reused" "existing-redis-password" "$out"
# Regenerating would rotate the password out from under a running Redis, which
# keeps the one it booted with; the app then crash-loops on WRONGPASS.
want_absent "existing value is not regenerated" "FRESHLY-GENERATED" \
  "existing-redis-password" "$out"

unset KL_TEST_SECRET_VALUE
out=$(kl_keep_or_generate demo-local demo-api-secrets REDIS_PASSWORD gen)
want "absent secret falls back to the generator" "FRESHLY-GENERATED" "$out"

# ===========================================================================
printf '\nduplicate env detection\n'
# ===========================================================================
cat >"$work/dup.yaml" <<'YAML'
        - name: APP_ENV
          value: "dev"
        - name: PUBLIC_BASE_URL
          value: "http://localhost:3000"
        - name: ROOT_DOMAIN
          value: "lvh.me"
        - name: PUBLIC_BASE_URL
          value: "https://www.lvh.me:8443"
YAML
out=$(kl_duplicate_env_vars "$work/dup.yaml")
want "duplicate env var is found" "PUBLIC_BASE_URL 2" "$out"
want_absent "unique env vars are not reported" "ROOT_DOMAIN" "PUBLIC_BASE_URL" "$out"

cat >"$work/clean.yaml" <<'YAML'
        - name: APP_ENV
          value: "dev"
        - name: ROOT_DOMAIN
          value: "lvh.me"
YAML
out=$(kl_duplicate_env_vars "$work/clean.yaml")
if [ -z "$out" ]; then ok "clean manifest reports nothing"; else
  bad "clean manifest reports nothing" "got [$out]"
fi

# ===========================================================================
printf '\nlive drift reporting\n'
# ===========================================================================
# The two ways a duplicate reaches the cluster fail in OPPOSITE directions, both
# reproduced against a real cluster on 2026-09-02. Reporting one as the other
# sends the reader looking at the wrong value.
mkdir -p "$work/drift/.k8s-local" "$work/drift/deploy/k8s-local"
cat >"$work/drift/.k8s-local/project.json" <<'JSON'
{ "project": "demo", "namespace": "demo-local", "manifests": "deploy/k8s-local",
  "workloads": { "app": "demo-api" } }
JSON
cp "$work/dup.yaml" "$work/drift/deploy/k8s-local/patch.yaml"

# Case 1 — kustomize patch: the strategic merge collapses the duplicate to ONE
# entry and keeps the FIRST. Nothing warns; the other value never reached the
# cluster at all.
export KL_TEST_LIVE_ENV="http://localhost:3000"
out=$(cd "$work/drift" && "$KLOCAL" status 2>&1)
want "collapsed duplicate is named as collapsed" "collapsed to one before apply" "$out"
want "collapsed duplicate reports the surviving value" "http://localhost:3000" "$out"
want "collapsed duplicate says the other was dropped" "dropped silently" "$out"

# Case 2 — plain manifest: BOTH entries survive into the live spec and the
# kubelet builds env in order, so the LAST is what the container sees.
export KL_TEST_LIVE_ENV="first-value
second-value"
out=$(cd "$work/drift" && "$KLOCAL" status 2>&1)
want "surviving duplicates are counted" "live spec holds 2 copies" "$out"
want "effective value is the last, not the first" "the container sees the last: second-value" "$out"
want_absent "the shadowed first value is not reported as effective" \
  "sees the last: first-value" "live spec holds 2 copies" "$out"
unset KL_TEST_LIVE_ENV

# Hostnames come off the live Ingress, never from an assumed api.<domain>.
export KL_TEST_INGRESS_HOSTS="scratch.lvh.me
admin.lvh.me"
out=$(kl_ingress_hosts demo-local)
want "ingress hosts are read from the cluster" "scratch.lvh.me" "$out"
want "every ingress host is listed" "admin.lvh.me" "$out"
unset KL_TEST_INGRESS_HOSTS

# ===========================================================================
printf '\nconfig loading\n'
# ===========================================================================
out=$(cd "$work/proj" && "$KLOCAL" status 2>&1)
want "status reads the project config" "demo-local" "$out"

mkdir -p "$work/proj/api/deep/nested"
out=$(cd "$work/proj/api/deep/nested" && "$KLOCAL" status 2>&1)
want "config is found from a subdirectory" "demo-local" "$out"

out=$(cd "$work" && "$KLOCAL" status 2>&1)
rc=$?
want "missing config is a clear error" "no .k8s-local/project.json" "$out"
want_status "missing config exits non-zero" 1 "$rc"

# ===========================================================================
printf '\nscaffold\n'
# ===========================================================================
mkdir -p "$work/fresh"
out=$("$KLOCAL" scaffold "$work/fresh" 2>&1)
want "scaffold reports what it wrote" "scaffolded" "$out"

for f in .k8s-local/project.json deploy/k8s-local/namespace.yaml \
  deploy/k8s-local/kustomization.yaml deploy/k8s-local/postgres.yaml \
  deploy/k8s-local/redis.yaml deploy/k8s-local/ingress.yaml \
  deploy/k8s-local/app-deployment-patch.yaml deploy/local/https-proxy.mjs; do
  if [ -f "$work/fresh/$f" ]; then ok "scaffold wrote $f"; else
    bad "scaffold wrote $f" "missing"
  fi
done

python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
  "$work/fresh/.k8s-local/project.json" 2>/dev/null &&
  ok "scaffolded project.json is valid JSON" ||
  bad "scaffolded project.json is valid JSON" "json.load failed"

# The templates must not ship a duplicate env var, given that duplicates are the
# very defect klocal status exists to report.
out=$(kl_duplicate_env_vars "$work/fresh/deploy/k8s-local/app-deployment-patch.yaml")
if [ -z "$out" ]; then ok "shipped template has no duplicate env vars"; else
  bad "shipped template has no duplicate env vars" "got [$out]"
fi

# Re-running must not clobber edits.
printf 'EDITED BY THE USER\n' >"$work/fresh/deploy/k8s-local/ingress.yaml"
out=$("$KLOCAL" scaffold "$work/fresh" 2>&1)
want "re-scaffold skips existing files" "skip (exists)" "$out"
want "re-scaffold preserved user edits" "EDITED BY THE USER" \
  "$(cat "$work/fresh/deploy/k8s-local/ingress.yaml")"

# ===========================================================================
printf '\nCLI surface\n'
# ===========================================================================
out=$("$KLOCAL" help 2>&1)
want "help lists up" "klocal up" "$out"
want "help lists scaffold" "klocal scaffold" "$out"

out=$("$KLOCAL" bogus-subcommand 2>&1)
rc=$?
want "unknown subcommand is rejected" "unknown command bogus-subcommand" "$out"
want_status "unknown subcommand exits non-zero" 1 "$rc"

# ===========================================================================
# Self-check: prove the harness can actually fail.
# ===========================================================================
if [ "$SELF_CHECK" = 1 ]; then
  printf '\nself-check (these three MUST fail)\n'
  before=$fail
  want "deliberate: substring that cannot match" "IMPOSSIBLE-XYZZY" "hello world"
  want "deliberate: empty output must not pass" "anything" ""
  want_absent "deliberate: missing execution marker" "nope" "MARKER-NEVER-EMITTED" "hello"
  broke=$((fail - before))
  printf '\n'
  if [ "$broke" = 3 ]; then
    printf 'self-check: 3/3 deliberate failures detected — the harness can fail.\n'
    fail=$before
    pass=$((pass + 3))
  else
    printf 'self-check: BROKEN — only %s of 3 deliberate failures were caught.\n' "$broke"
    printf 'The suite cannot be trusted; a green run would prove nothing.\n'
    exit 1
  fi
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
[ "$pass" -gt 0 ] || {
  printf 'no assertions ran at all — treating that as failure\n'
  exit 1
}
