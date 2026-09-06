#!/usr/bin/env bash
# Tests for the klocal libraries and CLI. No cluster, no network, no container
# engine — kubectl, docker, nerdctl and the cluster loaders are all stubbed on
# PATH, and they are created BEFORE the first test that could reach one, so a
# regression in the context guard cannot fall through to a real engine.
#
#   bash plugins/k8s-local/scripts/test-klocal.sh
#   bash plugins/k8s-local/scripts/test-klocal.sh --self-check
#
# Assertion discipline, because a suite that cannot fail is not evidence:
#   - `want` demands a specific string. An EMPTY expectation is itself a failure,
#     since every string contains the empty string and such a check can never go
#     red.
#   - Empty output is always a hard failure, never agreement.
#   - `want_absent` additionally requires a marker proving execution reached the
#     code under test; otherwise silence from an unrelated crash scores as a pass.
#   - `want_empty` requires a positive control — the same function producing
#     output on a known input — so "no output" cannot pass when the function is
#     missing or broken.
#   - --self-check breaks four assertions on purpose and fails the run unless all
#     four go red.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
plugin=$(dirname "$here")
KLOCAL="$plugin/bin/klocal"

pass=0
fail=0
skip=0

ok() {
  printf '  ok   %-52s %s\n' "$1" "${2:-}"
  pass=$((pass + 1))
}
bad() {
  printf '  FAIL %-52s %s\n' "$1" "$2"
  fail=$((fail + 1))
}
skipped() {
  printf '  skip %-52s %s\n' "$1" "$2"
  skip=$((skip + 1))
}

want() { # <label> <want> <got>
  if [ -z "$2" ]; then
    bad "$1" "EMPTY EXPECTATION — every string contains it; this check can never fail"
    return
  fi
  if [ -z "$3" ]; then
    bad "$1" "EMPTY OUTPUT — the command produced nothing; it likely never ran"
    return
  fi
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "want substring [$2] got [$(printf '%s' "$3" | tr '\n' '/' | cut -c1-90)]" ;;
  esac
}

want_absent() { # <label> <unwanted> <proof> <got>
  if [ -z "$2" ] || [ -z "$3" ]; then
    bad "$1" "EMPTY unwanted/proof argument — check cannot fail"
    return
  fi
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

# Assert no output, but only once a control input has proved the function works.
want_empty() { # <label> <got> <control-output>
  if [ -z "$3" ]; then
    bad "$1" "CONTROL PRODUCED NOTHING — the function is missing or broken, so an empty result proves nothing"
    return
  fi
  if [ -n "$2" ]; then
    bad "$1" "expected no output, got [$(printf '%s' "$2" | tr '\n' '/' | cut -c1-90)]"
    return
  fi
  ok "$1"
}

want_status() { # <label> <want-code> <got-code>
  if [ "$2" = "$3" ]; then ok "$1" "exit=$3"; else bad "$1" "want exit $2 got $3"; fi
}

# --- sandbox ---------------------------------------------------------------
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
export HOME="$work/home"
mkdir -p "$HOME" "$work/stub"
export PATH="$work/stub:$PATH"

# Engine and loader stubs FIRST. Previously these were created further down, so
# the end-to-end "refuses a remote context" test ran with the real docker on
# PATH: had the guard regressed, that safety test would have invoked a real
# build. Stubbing up front makes the suite offline by construction.
mk_stub() { # <name> <exit-code-for-info>
  cat >"$work/stub/$1" <<STUB
#!/usr/bin/env bash
case "\$*" in *info*) exit $2 ;; esac
echo "$1 ran: \$*"
exit 0
STUB
  chmod 755 "$work/stub/$1"
}
mk_stub docker 0
mk_stub nerdctl 1 # installed, socket unreachable: the Rancher-Desktop-on-moby case
mk_stub kind 0
mk_stub k3d 0
mk_stub minikube 0

# kubectl stub. Strips a leading `--context <v>` (kl_kubectl always passes one)
# and records it, so tests can assert the verified context is actually pinned.
cat >"$work/stub/kubectl" <<'STUB'
#!/usr/bin/env bash
ctx=""
if [ "${1:-}" = "--context" ]; then ctx=$2; shift 2; fi
printf '%s|%s\n' "$ctx" "$*" >>"$KL_TEST_CTX_LOG"
# One argument per line, so an assertion can see argument boundaries. Printing
# only "$*" erased them, which meant the psql tests could not have caught a
# quoting or split-argument bug at all.
for a in "$@"; do printf 'ARG[%s]\n' "$a" >>"$KL_TEST_ARGV_LOG"; done
printf -- '--\n' >>"$KL_TEST_ARGV_LOG"
case "$1 $2" in
  "config current-context") cat "$KL_TEST_CTX_FILE" 2>/dev/null; exit 0 ;;
esac
case "$*" in
  "config view"*)
    # --minify form: the context arrives as a flag value, never inside jsonpath.
    case "$*" in
      *proxy-url*) printf '%s' "${KL_TEST_PROXY_URL:-}" ;;
      *tls-server-name*) printf '%s' "${KL_TEST_TLS_SERVER_NAME:-}" ;;
      *server*) printf '%s' "${KL_TEST_SERVER-https://127.0.0.1:6443}" ;;
    esac
    exit 0 ;;
  "cluster-info"*) exit "${KL_TEST_CLUSTER_RC:-0}" ;;
  "get ingressclass"*) exit "${KL_TEST_INGRESSCLASS_RC:-0}" ;;
  "get secret"*)
    # Three distinguishable worlds, which the old stub could not express:
    #   FORBIDDEN=1  every read fails (RBAC), even though the namespace is readable
    #   EXISTS=0     the Secret is there; KL_TEST_SECRET_KEYS lists its keys
    #   EXISTS=1     the Secret is absent
    [ "${KL_TEST_SECRET_FORBIDDEN:-0}" = "1" ] && exit 1
    case "$*" in
      *--ignore-not-found*)
        [ "${KL_TEST_SECRET_EXISTS_RC:-1}" = "0" ] && printf 'secret/thesecret\n'
        exit 0 ;;
      *'range $k'*)
        printf '%s\n' "${KL_TEST_SECRET_KEYS:-}"; exit 0 ;;
      *index*)
        [ -n "${KL_TEST_SECRET_VALUE:-}" ] || exit 0
        printf '%s' "$KL_TEST_SECRET_VALUE" | base64 ; exit 0 ;;
      *) exit "${KL_TEST_SECRET_EXISTS_RC:-1}" ;;
    esac ;;
  "get deploy"*) printf '%s' "${KL_TEST_LIVE_JSON:-}"; exit 0 ;;
  "get ingress"*) printf '%s' "${KL_TEST_INGRESS_HOSTS:-}"; exit 0 ;;
  "get namespace"*) exit "${KL_TEST_NS_RC:-0}" ;;
  "exec"*) printf 'kubectl exec ran: %s\n' "$*"; exit 0 ;;
esac
exit 0
STUB
chmod 755 "$work/stub/kubectl"
export KL_TEST_ARGV_LOG="$work/argvlog"
: >"$KL_TEST_ARGV_LOG"

export KL_TEST_CTX_FILE="$work/ctx"
export KL_TEST_CTX_LOG="$work/ctxlog"
: >"$KL_TEST_CTX_LOG"
printf 'rancher-desktop\n' >"$KL_TEST_CTX_FILE"

# shellcheck source=lib/common.sh
. "$plugin/scripts/lib/common.sh"
# shellcheck source=lib/cluster.sh
. "$plugin/scripts/lib/cluster.sh"

mkproj() { # <dir> <json>
  mkdir -p "$1/.k8s-local"
  printf '%s\n' "$2" >"$1/.k8s-local/project.json"
}

SELF_CHECK=0
[ "${1:-}" = "--self-check" ] && SELF_CHECK=1

# ===========================================================================
printf '\ncontext guard: name\n'
# ===========================================================================
for ctx in rancher-desktop docker-desktop minikube colima kind-dev k3d-mycluster; do
  if kl_context_name_is_local "$ctx"; then ok "local name accepted: $ctx"; else
    bad "local name accepted: $ctx" "was refused"
  fi
done

for ctx in gke_proj_us-central1_prod arn:aws:eks:us-east-1:1:cluster/prod \
  cme-cluster localstack-prod do-sfo3-k8s ""; do
  if kl_context_name_is_local "$ctx"; then
    bad "remote name refused: ${ctx:-<empty>}" "was ACCEPTED — this would deploy to it"
  else ok "remote name refused: ${ctx:-<empty>}"; fi
done

# ===========================================================================
printf '\ncontext guard: API server address\n'
# ===========================================================================
# The name is chosen by whoever made the cluster, so a remote cluster can be
# called kind-prod. The address is the part that cannot be faked by naming.
for h in 127.0.0.1 localhost ::1 10.1.2.3 192.168.64.5 172.16.0.1 172.31.255.1 \
  169.254.1.1 host.docker.internal rd.local; do
  if kl_host_is_local "$h"; then ok "local address accepted: $h"; else
    bad "local address accepted: $h" "was refused"
  fi
done

for h in 34.120.1.1 8.8.8.8 172.32.0.1 172.15.0.1 api.eks.amazonaws.com 2600:1f18::1; do
  if kl_host_is_local "$h"; then
    bad "public address refused: $h" "was ACCEPTED"
  else ok "public address refused: $h"; fi
done

# A private range must be matched as an ADDRESS, never as a text prefix: a glob
# like 10.* also matches the hostname 10.prod.example.com, and that would walk a
# remote cluster straight through the one check naming cannot fake.
for h in 10.prod.example.com 192.168.evil.com 127.attacker.net \
  172.16.example.org 10.0.0.1.evil.com 169.254.evil.com; do
  if kl_host_is_local "$h"; then
    bad "hostname merely starting with a private range: $h" "was ACCEPTED — guard bypassed"
  else ok "hostname merely starting with a private range: $h"; fi
done

# Malformed literals are not addresses either.
for h in 10 10.1 10.1.2 1.2.3.4.5 "" " " 10.1.2.3.4; do
  if kl_host_is_local "$h"; then
    bad "malformed literal refused: ${h:-<empty>}" "was ACCEPTED"
  else ok "malformed literal refused: ${h:-<empty>}"; fi
done

export KL_TEST_SERVER="https://[::1]:6443"
want "IPv6 server host is parsed without brackets" "::1" "$(kl_context_server_host x)"
export KL_TEST_SERVER="https://10.0.0.5:6443/some/path"
want "server host strips port and path" "10.0.0.5" "$(kl_context_server_host x)"
export KL_TEST_SERVER="https://127.0.0.1:6443"

# The context name must never be interpolated into a JSONPath expression. A name
# containing  ')]...{...}{...[?(@.name=='  closed the expression and appended two
# more, so the host check could be pointed at a loopback decoy while every real
# call used the exact remote context. --minify passes it as a flag VALUE instead.
: >"$KL_TEST_ARGV_LOG"
evil="kind-x')].context.cluster}{.contexts[0].context.cluster}{.contexts[?(@.name=='x"
printf '%s\n' "$evil" >"$KL_TEST_CTX_FILE"
kl_context_server_host "$evil" >/dev/null 2>&1 || true
# The name appearing as a --context VALUE is correct and expected; what must
# never happen is the name landing inside the jsonpath expression itself.
jsonpath_args=$(grep '^ARG\[jsonpath=' "$KL_TEST_ARGV_LOG" | grep -F 'contexts[' || true)
# The control must prove the call HAPPENED, so it is the jsonpath argument
# itself. `grep -c` was used here and prints "0" when nothing matched — a
# non-empty string, so want_empty's "control produced nothing" guard could
# never fire and a run that never called kubectl scored a pass.
want_empty "the context name never reaches a jsonpath expression" "$jsonpath_args" \
  "$(grep '^ARG\[jsonpath=' "$KL_TEST_ARGV_LOG" | head -1 || true)"
passed_as_value=$(grep -Fc "ARG[$evil]" "$KL_TEST_ARGV_LOG" || true)
if [ "${passed_as_value:-0}" -gt 0 ]; then
  ok "the context is passed as a flag value instead" "$passed_as_value"
else
  bad "the context is passed as a flag value instead" "never seen as its own argument"
fi
minify=$(grep -Fc 'ARG[--minify]' "$KL_TEST_ARGV_LOG" || true)
if [ "${minify:-0}" -gt 0 ]; then ok "the cluster field is read via --minify" "$minify calls"; else
  bad "the cluster field is read via --minify" "no --minify call recorded"
fi
printf 'rancher-desktop\n' >"$KL_TEST_CTX_FILE"

# A loopback server proves nothing when requests are tunnelled elsewhere.
export KL_TEST_PROXY_URL="socks5://evil.example:1080"
if kl_context_is_local rancher-desktop; then
  bad "proxy-url makes a context non-local" "was ACCEPTED"
else ok "proxy-url makes a context non-local"; fi
mkproj "$work/pproxy" '{"project":"demo","namespace":"demo-local","workloads":{"app":"demo-api"}}'
out=$(cd "$work/pproxy" && "$KLOCAL" up --no-build 2>&1)
rc=$?
want "up refuses a context with proxy-url" "proxy-url or tls-server-name" "$out"
want_status "  and exits non-zero" 1 "$rc"
unset KL_TEST_PROXY_URL
export KL_TEST_TLS_SERVER_NAME="prod.internal"
if kl_context_is_local rancher-desktop; then
  bad "tls-server-name makes a context non-local" "was ACCEPTED"
else ok "tls-server-name makes a context non-local"; fi
unset KL_TEST_TLS_SERVER_NAME

# The combined check, used by read-only commands that report rather than refuse.
printf 'rancher-desktop\n' >"$KL_TEST_CTX_FILE"
export KL_TEST_SERVER="https://127.0.0.1:6443"
if kl_context_is_local rancher-desktop; then ok "combined check accepts a real local context"; else
  bad "combined check accepts a real local context" "was refused"
fi
export KL_TEST_SERVER="https://prod.eks.amazonaws.com"
if kl_context_is_local kind-prod; then
  bad "combined check rejects local name + remote server" "was ACCEPTED"
else ok "combined check rejects local name + remote server"; fi
export KL_TEST_SERVER="https://127.0.0.1:6443"
if kl_context_is_local gke_proj_prod; then
  bad "combined check rejects a remote name" "was ACCEPTED"
else ok "combined check rejects a remote name"; fi

# status only reads, but reading still queries someone's cluster, so it must
# apply both checks rather than the name alone.
printf 'kind-prod\n' >"$KL_TEST_CTX_FILE"
export KL_TEST_SERVER="https://prod.eks.amazonaws.com"
mkproj "$work/pstat" '{"project":"demo","namespace":"demo-local","workloads":{"app":"demo-api"}}'
out=$(cd "$work/pstat" && "$KLOCAL" status 2>&1)
want "status refuses a local name on a remote server" "not verifiably local" "$out"
want_absent "status does not query that cluster" "no PVC" "not verifiably local" "$out"
export KL_TEST_SERVER="https://127.0.0.1:6443"

# The finding this closes: a locally-named context pointing at a remote cluster.
printf 'kind-prod\n' >"$KL_TEST_CTX_FILE"
export KL_TEST_SERVER="https://prod.eks.amazonaws.com"
mkproj "$work/p1" '{"project":"demo","namespace":"demo-local","workloads":{"app":"demo-api"}}'
out=$(cd "$work/p1" && "$KLOCAL" up 2>&1)
rc=$?
want "local-looking name on a remote server is refused" "API server is at prod.eks.amazonaws.com" "$out"
want_status "that refusal exits non-zero" 1 "$rc"
want_absent "no build happens on that refusal" "docker ran:" "REFUSING" "$out"
export KL_TEST_SERVER="https://127.0.0.1:6443"

printf 'gke_proj_us-central1_prod\n' >"$KL_TEST_CTX_FILE"
out=$(cd "$work/p1" && "$KLOCAL" up 2>&1)
rc=$?
want "up refuses a remote context" "REFUSING" "$out"
want "refusal names the offending context" "gke_proj_us-central1_prod" "$out"
want_status "up exits non-zero on a remote context" 1 "$rc"
want_absent "refusal happens before any build" "docker ran:" "REFUSING" "$out"

# logs and psql reach into pods and previously skipped the guard entirely.
out=$(cd "$work/p1" && "$KLOCAL" logs 2>&1)
rc=$?
want "logs refuses a remote context" "REFUSING" "$out"
want_status "logs exits non-zero on a remote context" 1 "$rc"

mkproj "$work/pdb" '{"project":"demo","namespace":"demo-local","workloads":{"app":"demo-api","db":"demo-postgres"},"database":{"name":"demo_dev","superuser":"demo","appRole":"demo_app"}}'
out=$(cd "$work/pdb" && "$KLOCAL" psql 2>&1)
rc=$?
want "psql refuses a remote context" "REFUSING" "$out"
want_status "psql exits non-zero on a remote context" 1 "$rc"

printf 'rancher-desktop\n' >"$KL_TEST_CTX_FILE"

# ===========================================================================
printf '\ncontext pinning\n'
# ===========================================================================
# Checking current-context and then relying on it later is a race: a build takes
# minutes and another terminal can switch the shared kubeconfig meanwhile.
: >"$KL_TEST_CTX_LOG"
(cd "$work/p1" && "$KLOCAL" status >/dev/null 2>&1)
# Every recorded context must be rancher-desktop. Matching a substring of the
# whole `sort -u` list passed as long as ONE line was right, so a call leaking to
# a different context was invisible. Assert the list has exactly one entry AND
# that it is the expected one.
ctxs=$(cut -d'|' -f1 "$KL_TEST_CTX_LOG" | grep . | sort -u)
nctx=$(printf '%s\n' "$ctxs" | grep -c . || true)
want "cluster calls pass an explicit --context" "rancher-desktop" "$ctxs"
want_status "  and no call used any other context" 1 "$nctx"

# Only context DISCOVERY may be unpinned (`config current-context`, `config
# view`); everything that reads or writes cluster state must carry --context, or
# a kubeconfig switch mid-run silently redirects it. Listing the offenders by
# name is what makes this fail loudly when a bare kubectl creeps back in.
unpinned=$(grep '^|' "$KL_TEST_CTX_LOG" | cut -d'|' -f2 | grep -v '^config ' || true)
total=$(grep -c . "$KL_TEST_CTX_LOG" || true)
if [ "${total:-0}" -lt 3 ]; then
  bad "kubectl was actually exercised" "only ${total:-0} calls recorded; the test proves nothing"
elif [ -z "$unpinned" ]; then
  ok "every state-touching call is pinned" "$total calls"
else
  bad "every state-touching call is pinned" "unpinned: $(printf '%s' "$unpinned" | tr '\n' ';')"
fi

# A context name with whitespace would split the kind/k3d loader command.
printf 'kind-a b\n' >"$KL_TEST_CTX_FILE"
out=$(cd "$work/p1" && "$KLOCAL" status 2>&1)
want "a whitespace context name is not treated as local" "not verifiably local" "$out"
out=$(cd "$work/p1" && "$KLOCAL" up --no-build 2>&1)
want "up refuses a whitespace context name" "whitespace" "$out"
printf 'rancher-desktop\n' >"$KL_TEST_CTX_FILE"

# ===========================================================================
printf '\nconfig validation (option injection)\n'
# ===========================================================================
# Quoting stops word-splitting but not option interpretation: a namespace of
# "--all" turns `kubectl delete namespace $NS` into `--all`, deleting every
# namespace on the cluster.
for badns in "--all" "-n" "UPPER" "has space" "ends-" "-starts" \
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; do
  mkproj "$work/bad" "{\"project\":\"demo\",\"namespace\":\"$badns\",\"workloads\":{\"app\":\"demo-api\"}}"
  : >"$KL_TEST_CTX_LOG"
  out=$(cd "$work/bad" && "$KLOCAL" down --yes 2>&1)
  rc=$?
  want "namespace rejected: $badns" "must be a lowercase DNS label" "$out"
  want_status "  and exits non-zero" 1 "$rc"
  # Assert against the LOG, not stdout. The kubectl stub has no branch for
  # `delete namespace` and exits silently, so searching stdout for that string
  # could never have found it whether kubectl ran or not — the check named the
  # right danger and observed a place it could never appear.
  want_empty "  and never reaches kubectl" \
    "$(grep -F 'delete namespace' "$KL_TEST_CTX_LOG" || true)" \
    "$(cd "$work/p1" && "$KLOCAL" status >/dev/null 2>&1; grep -c . "$KL_TEST_CTX_LOG" | grep -v '^0$' || echo control-failed)"
done

for goodns in demo-local a demo123 my-app-local; do
  if kl_is_dns_label "$goodns"; then ok "valid namespace accepted: $goodns"; else
    bad "valid namespace accepted: $goodns" "was rejected"
  fi
done

mkproj "$work/badimg" '{"project":"demo","image":{"name":"--privileged"},"workloads":{"app":"demo-api"}}'
out=$(cd "$work/badimg" && "$KLOCAL" status 2>&1)
want "image name beginning with dash is rejected" "must not be empty or begin with" "$out"

# kubectl lets a LATER --context win, so an unvalidated ingressClass reaching the
# command line as a positional argument overrides the pin entirely.
mkproj "$work/badic" '{"project":"demo","namespace":"demo-local","ingressClass":"--context=prod","workloads":{"app":"demo-api"}}'
: >"$KL_TEST_CTX_LOG"
out=$(cd "$work/badic" && "$KLOCAL" up --no-build 2>&1)
want "ingressClass that looks like a flag is rejected" "must be a lowercase DNS label" "$out"
# Same correction: the stub records `get ingressclass` in the log and prints
# nothing, so stdout was the wrong place to look.
want_empty "  and never reaches kubectl" \
  "$(grep -F 'get ingressclass' "$KL_TEST_CTX_LOG" || true)" \
  "$(cd "$work/p1" && "$KLOCAL" status >/dev/null 2>&1; grep -c . "$KL_TEST_CTX_LOG" | grep -v '^0$' || echo control-failed)"

# grep -q succeeds when ANY line matches, so an anchored pattern accepted a
# multiline value whose second line was a flag.
if kl_is_dns_label "$(printf 'valid\n--context=prod')"; then
  bad "a multiline value is not a DNS label" "was ACCEPTED"
else ok "a multiline value is not a DNS label"; fi

# psql -d takes a full connection URI, which redirects the session AND overrides
# -U, so a "database name" could reach production as postgres despite --app.
for badv in "postgresql://postgres@prod-db.internal/production" "postgres://x@y/z" \
  "db name" "db-with-dash" "1starts-with-digit"; do
  mkproj "$work/baddb" "{\"project\":\"demo\",\"workloads\":{\"app\":\"demo-api\",\"db\":\"demo-postgres\"},\"database\":{\"name\":\"$badv\"}}"
  out=$(cd "$work/baddb" && "$KLOCAL" status 2>&1)
  want "database.name rejected: $badv" "must be a bare identifier" "$out"
done
for goodv in demo_dev postgres app_db_2; do
  if kl_is_pg_ident "$goodv"; then ok "valid database identifier: $goodv"; else
    bad "valid database identifier: $goodv" "was rejected"
  fi
done

# ===========================================================================
printf '\nJSON backend parity (jq vs python3)\n'
# ===========================================================================
# Python's str(False) is "False", which is not a legal Kubernetes name; jq's
# tostring is "false", which is. Whichever backend is installed must not change
# what the tool operates on.
printf '{"a":false,"b":3,"c":"x","d":[1,true,"z"]}\n' >"$work/types.json"
nojq="$work/nojq"
mkdir -p "$nojq"
py=$(command -v python3 || true)
[ -n "$py" ] && ln -sf "$py" "$nojq/python3"
if ! command -v jq >/dev/null 2>&1; then
  # Without jq the "jq side" would silently be Python too, so the comparison
  # would report parity while exercising one backend twice.
  skipped "jq/python parity" "jq is not installed; the comparison would be python vs python"
elif PATH="/usr/bin:/bin" command -v jq >/dev/null 2>&1; then
  skipped "jq/python parity" "jq is in /usr/bin or /bin; cannot isolate the python path"
elif [ -z "$py" ]; then
  skipped "jq/python parity" "no python3 available"
else
  # Prove the isolated PATH really has no jq, or the whole section is vacuous.
  if PATH="$nojq:/usr/bin:/bin" command -v jq >/dev/null 2>&1; then
    bad "the python-only PATH excludes jq" "jq is still reachable; parity check is meaningless"
  else
    ok "the python-only PATH excludes jq"
  fi
  for key in a b c d; do
    with_jq=$(kl_json_get "$work/types.json" "$key")
    with_py=$(PATH="$nojq:/usr/bin:/bin" bash -c ". '$plugin/scripts/lib/common.sh'; kl_json_get '$work/types.json' '$key'")
    if [ -z "$with_jq$with_py" ]; then
      bad "backends agree on '$key'" "both produced nothing"
    elif [ "$with_jq" = "$with_py" ]; then
      ok "backends agree on '$key'" "= $with_jq"
    else
      bad "backends agree on '$key'" "jq=[$with_jq] python=[$with_py]"
    fi
  done
  want "boolean renders JSON-style, not Python-style" "false" "$(kl_json_get "$work/types.json" a)"
  want_absent "boolean is not Python's True/False" "False" "false" \
    "$(PATH="$nojq:/usr/bin:/bin" bash -c ". '$plugin/scripts/lib/common.sh'; kl_json_get '$work/types.json' a")"
fi

# ===========================================================================
printf '\ningress class\n'
# ===========================================================================
export KL_CONTEXT=rancher-desktop
export KL_TEST_INGRESSCLASS_RC=0
out=$(kl_check_ingressclass traefik 2>&1)
want "present ingressclass is reported" "ingressclass: traefik" "$out"

export KL_TEST_INGRESSCLASS_RC=1
out=$(kl_check_ingressclass traefik 2>&1)
rc=$?
want "missing ingressclass warns" "WARNING: no IngressClass 'traefik'" "$out"
want "warning explains the consequence" "no hostname will route" "$out"
want_status "missing ingressclass does not abort" 0 "$rc"
unset KL_TEST_INGRESSCLASS_RC

# ===========================================================================
printf '\nengine probe and cluster image load\n'
# ===========================================================================
want "nerdctl present but socket dead -> docker" "docker" "$(kl_detect_engine)"
out=$(kl_build_image demo:local "$work" 2>&1)
want "build invoked docker" "docker ran: build" "$out"
want "build tagged the configured image" "-t demo:local" "$out"

mk_stub nerdctl 0
want "nerdctl socket alive -> nerdctl" "nerdctl" "$(kl_detect_engine)"
out=$(kl_build_image demo:local "$work" 2>&1)
want "nerdctl build targets the k8s.io namespace" "--namespace k8s.io" "$out"
mk_stub nerdctl 1

# The engines whose node has its own image store need an explicit import, or the
# pod keeps running the previous image with no error anywhere.
want "kind needs an import" "kind load docker-image demo:local --name dev" "$(kl_image_load_cmd kind-dev demo:local)"
want "k3d needs an import" "k3d image import demo:local -c mycluster" "$(kl_image_load_cmd k3d-mycluster demo:local)"
want "minikube needs an import" "minikube image load demo:local" "$(kl_image_load_cmd minikube demo:local)"
ctl_control=$(kl_image_load_cmd kind-dev demo:local)
want_empty "rancher-desktop shares the store, no import" "$(kl_image_load_cmd rancher-desktop demo:local)" "$ctl_control"
want_empty "docker-desktop shares the store, no import" "$(kl_image_load_cmd docker-desktop demo:local)" "$ctl_control"

KL_CONTEXT=kind-dev out=$(kl_build_image demo:local "$work" 2>&1)
want "kind build actually runs the import" "kind ran: load docker-image demo:local" "$out"
KL_CONTEXT=k3d-c1 out=$(kl_build_image demo:local "$work" 2>&1)
want "k3d build actually runs the import" "k3d ran: image import demo:local" "$out"
KL_CONTEXT=rancher-desktop out=$(kl_build_image demo:local "$work" 2>&1)
want_absent "rancher-desktop build runs no import" "kind ran:" "docker ran: build" "$out"

# The loader runs with an explicit argument list. Splitting the printed command
# string exposed the cluster name to word-splitting AND globbing, so a context
# named `kind-*` would have expanded against the working directory.
: >"$KL_TEST_ARGV_LOG"
mkdir -p "$work/globbait"
(cd "$work/globbait" && touch a.yaml b.yaml &&
  KL_CONTEXT="kind-*" kl_build_image demo:local "$work" >/dev/null 2>&1) || true
globbed=$(cd "$work/globbait" && KL_CONTEXT="kind-*" kl_build_image demo:local "$work" 2>&1 | grep -F 'kind ran:' || true)
want "the loader receives the literal cluster name" "--name *" "$globbed"
want_absent "the cluster name is not glob-expanded against the cwd" "a.yaml" \
  "kind ran:" "$globbed"

# Only a single --name may reach the loader.
names=$(KL_CONTEXT="kind-dev" kl_build_image demo:local "$work" 2>&1 | grep -F 'kind ran:' |
  tr ' ' '\n' | grep -cx -- '--name' || true)
if [ "${names:-0}" = "1" ]; then ok "exactly one --name is passed" ; else
  bad "exactly one --name is passed" "counted ${names:-0}"
fi

# When the cluster imports from the Docker store, building into nerdctl's
# containerd namespace leaves the loader unable to find the tag.
mk_stub nerdctl 0 # socket alive: without the preference this would win
out=$(KL_CONTEXT=kind-dev kl_build_image demo:local "$work" 2>&1)
want "a loader-based context prefers docker over nerdctl" "using docker, not nerdctl" "$out"
want "  and the build really used docker" "docker ran: build" "$out"
want_absent "  and did not build into containerd" "nerdctl ran: build" "docker ran: build" "$out"
want "  and still runs the import" "kind ran: load docker-image" "$out"
mk_stub nerdctl 1

# "This binary is absent" must mean absent, not "absent from the stub dir".
# Deleting a stub used to fall through to the real /usr/local/bin/docker, so
# whether these cases passed depended on whether a docker daemon happened to be
# reachable — the suite was green here only because HOME had been redirected and
# Docker's context config lives under $HOME. PATH is narrowed to the stub
# directory alone, so nothing outside it can be reached by accident.
# /usr/bin:/bin is kept because the stubs' `#!/usr/bin/env bash` needs to find
# bash; it is NOT where a real docker lives (/usr/local/bin or Homebrew), and the
# assertion below proves that on whatever machine this runs.
absent_path="$work/stub:/usr/bin:/bin"

# A missing loader must be fatal: skipping the import silently is the bug.
mv "$work/stub/kind" "$work/kind.hidden"
out=$(PATH="$absent_path" KL_CONTEXT=kind-dev kl_build_image demo:local "$work" 2>&1)
rc=$?
want "missing kind binary is fatal, not skipped" "needs it to see the image" "$out"
want_status "  and exits non-zero" 1 "$rc"
mv "$work/kind.hidden" "$work/stub/kind"
export KL_CONTEXT=rancher-desktop

# Prove the narrowed PATH really hides the engines, or the two checks below are
# assertions about an environment rather than about the code.
rm -f "$work/stub/nerdctl" "$work/stub/docker"
if PATH="$absent_path" command -v docker >/dev/null 2>&1 ||
  PATH="$absent_path" command -v nerdctl >/dev/null 2>&1; then
  bad "the no-engine PATH really has no engine" "a real docker/nerdctl is still reachable"
else
  ok "the no-engine PATH really has no engine"
fi
engine_out=$(PATH="$absent_path" kl_detect_engine)
want_empty "no engine at all yields no engine name" "$engine_out" "docker"
out=$(PATH="$absent_path" kl_build_image demo:local "$work" 2>&1)
rc=$?
want "no engine is a clear failure" "no working container engine" "$out"
want_status "no engine exits non-zero" 1 "$rc"
mk_stub docker 0
mk_stub nerdctl 1

# ===========================================================================
printf '\nsecret reuse and read failures\n'
# ===========================================================================
gen() { printf 'FRESHLY-GENERATED'; }

export KL_TEST_SECRET_EXISTS_RC=0
export KL_TEST_SECRET_KEYS="REDIS_PASSWORD"
export KL_TEST_SECRET_VALUE="existing-redis-password"
out=$(kl_keep_or_generate demo-local demo-api-secrets REDIS_PASSWORD gen)
want "existing secret value is reused" "existing-redis-password" "$out"
want_absent "existing value is not regenerated" "FRESHLY-GENERATED" \
  "existing-redis-password" "$out"

# Genuinely absent: the Secret itself is not there.
export KL_TEST_SECRET_EXISTS_RC=1
unset KL_TEST_SECRET_VALUE
out=$(kl_keep_or_generate demo-local demo-api-secrets REDIS_PASSWORD gen)
want "absent secret falls back to the generator" "FRESHLY-GENERATED" "$out"

# Present Secret, key not among its keys: also genuinely absent.
export KL_TEST_SECRET_EXISTS_RC=0
export KL_TEST_SECRET_KEYS="SOMETHING_ELSE"
out=$(kl_keep_or_generate demo-local demo-api-secrets REDIS_PASSWORD gen)
want "missing key in an existing Secret generates" "FRESHLY-GENERATED" "$out"

# RBAC forbids reading Secrets while the namespace is readable. Inferring
# "absent" from a failed read is what rotated live credentials.
export KL_TEST_SECRET_FORBIDDEN=1
export KL_TEST_NS_RC=0
out=$(kl_keep_or_generate demo-local demo-api-secrets REDIS_PASSWORD gen 2>&1)
rc=$?
want "forbidden secret read refuses to regenerate" "refusing to generate" "$out"
want_status "  and exits non-zero" 1 "$rc"
want_absent "  and does not emit a fresh value" "FRESHLY-GENERATED" "refusing to generate" "$out"
unset KL_TEST_SECRET_FORBIDDEN

# A key whose stored value is empty is PRESENT. Treating it as absent would
# replace a value someone deliberately set to empty.
export KL_TEST_SECRET_EXISTS_RC=0
export KL_TEST_SECRET_KEYS="REDIS_PASSWORD"
unset KL_TEST_SECRET_VALUE
out=$(kl_keep_or_generate demo-local demo-api-secrets REDIS_PASSWORD gen)
rc=$?
want_status "an empty stored value counts as present" 0 "$rc"
# The control is a REAL call of the same function on a known-good input, not a
# string literal. A literal can never report that the function is broken, which
# is the one thing want_empty's control argument exists to do.
kg_control=$(KL_TEST_SECRET_EXISTS_RC=1 kl_keep_or_generate demo-local demo-api-secrets CTRL gen)
want_empty "  and is returned as empty, not regenerated" "$out" "$kg_control"

# A dotted key: jsonpath {.data.tls.crt} looked up a nested path and returned
# empty, so any key with a dot read as absent.
export KL_TEST_SECRET_KEYS="tls.crt"
export KL_TEST_SECRET_VALUE="cert-bytes"
out=$(kl_keep_or_generate demo-local demo-api-secrets tls.crt gen)
want "a dotted secret key is found, not treated as absent" "cert-bytes" "$out"
unset KL_TEST_SECRET_KEYS KL_TEST_SECRET_VALUE KL_TEST_SECRET_EXISTS_RC KL_TEST_NS_RC

# ===========================================================================
printf '\nduplicate env detection (scoped)\n'
# ===========================================================================
cat >"$work/dup.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-api
spec:
  template:
    spec:
      containers:
        - name: api
          env:
            - name: APP_ENV
              value: "dev"
            - name: PUBLIC_BASE_URL
              value: "http://localhost:3000"
            - name: ROOT_DOMAIN
              value: "lvh.me"
            - name: PUBLIC_BASE_URL
              value: "https://www.lvh.me:8443"
YAML
dup_control=$(kl_duplicate_env_vars "$work/dup.yaml")
want "a real duplicate is found" "PUBLIC_BASE_URL 2" "$dup_control"
want "the duplicate is attributed to workload and container" "demo-api containers api" "$dup_control"
want_absent "unique env vars are not reported" "ROOT_DOMAIN" "PUBLIC_BASE_URL" "$dup_control"

# The false positive Codex found: two Deployments each declaring APP_ENV once.
cat >"$work/twodocs.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: one
spec:
  template:
    spec:
      containers:
        - name: api
          env:
            - name: APP_ENV
              value: "dev"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: two
spec:
  template:
    spec:
      containers:
        - name: api
          env:
            - name: APP_ENV
              value: "dev"
YAML
want_empty "two documents each declaring it once is not a duplicate" \
  "$(kl_duplicate_env_vars "$work/twodocs.yaml" 2>&1)" "$dup_control"

# Container names, port names and volume names are not env vars.
cat >"$work/names.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-api
spec:
  template:
    spec:
      containers:
        - name: api
          ports:
            - name: http
              containerPort: 80
          env:
            - name: APP_ENV
              value: "dev"
        - name: api
          ports:
            - name: http
              containerPort: 81
YAML
want_empty "container and port names are not counted as env vars" \
  "$(kl_duplicate_env_vars "$work/names.yaml")" "$dup_control"

# Two containers in one pod may each set the same variable legitimately.
cat >"$work/sidecar.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-api
spec:
  template:
    spec:
      containers:
        - name: api
          env:
            - name: LOG_LEVEL
              value: "debug"
        - name: sidecar
          env:
            - name: LOG_LEVEL
              value: "info"
YAML
want_empty "the same var in two containers is not a duplicate" \
  "$(kl_duplicate_env_vars "$work/sidecar.yaml")" "$dup_control"

# Two variables sourced from the same Secret is the most ordinary thing in a real
# manifest. Counting the bare `name:` inside valueFrom.secretKeyRef reported the
# SECRET as a duplicated env var, so status cried wolf on almost every manifest.
cat >"$work/secretref.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-api
spec:
  template:
    spec:
      containers:
        - name: api
          env:
            - name: DATABASE_URL
              valueFrom:
                secretKeyRef:
                  name: demo-api-secrets
                  key: DATABASE_URL
            - name: REDIS_URL
              valueFrom:
                secretKeyRef:
                  name: demo-api-secrets
                  key: REDIS_URL
YAML
want_empty "two vars from one Secret is not a duplicate" \
  "$(kl_duplicate_env_vars "$work/secretref.yaml")" "$dup_control"

# envFrom's secretRef name, initContainers, and volumeMounts all carry `name:`
# keys that are not env vars; the container attribution must survive them.
cat >"$work/tricky.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: tricky
spec:
  template:
    spec:
      initContainers:
        - name: migrate
          env:
            - name: SHARED
              value: "a"
      containers:
        - name: api
          envFrom:
            - secretRef:
                name: SHARED
          env:
            - name: "QUOTED_DUP"
              value: "1"
            - name: SHARED
              value: "b"
            - name: QUOTED_DUP
              value: "2"
          volumeMounts:
            - name: data
              mountPath: /data
YAML
tricky=$(kl_duplicate_env_vars "$work/tricky.yaml")
want "a duplicate is found despite envFrom and initContainers" "QUOTED_DUP 2" "$tricky"
want "quoted and unquoted spellings count as the same name" "QUOTED_DUP 2" "$tricky"
want "attribution survives an envFrom secretRef name" "tricky containers api" "$tricky"
want_absent "the envFrom secret is not mistaken for the container" "containers SHARED" \
  "QUOTED_DUP" "$tricky"
want_absent "a var in an initContainer and a container is not a duplicate" \
  "SHARED 2" "QUOTED_DUP" "$tricky"

# A trailing comment on env: / containers: must not hide the block.
cat >"$work/comment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: commented
spec:
  template:
    spec:
      containers: # the app container
        - name: api
          env: # local overrides
            - name: FOO
              value: "1"
            - name: FOO
              value: "2"
YAML
want "a trailing comment does not hide the env block" "commented containers api FOO 2" \
  "$(kl_duplicate_env_vars "$work/comment.yaml")"

# Shapes the scanner genuinely cannot read must be REPORTED, not skipped —
# silently ignoring them is a false all-clear on the file the user asked about.
cat >"$work/flow.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flowapp
spec:
  template:
    spec:
      containers:
        - name: api
          env: [{name: FOO, value: "1"}, {name: FOO, value: "2"}]
YAML
want "a flow-style env block is reported as unreadable" "UNREADABLE" \
  "$(kl_duplicate_env_vars "$work/flow.yaml")"
mkdir -p "$work/flowproj/deploy/k8s-local"
mkproj "$work/flowproj" '{"project":"demo","namespace":"demo-local","manifests":"deploy/k8s-local","workloads":{"app":"demo-api"}}'
cp "$work/flow.yaml" "$work/flowproj/deploy/k8s-local/app.yaml"
out=$(cd "$work/flowproj" && "$KLOCAL" status 2>&1)
want "status says the file was not analysed" "was NOT analysed" "$out"
want_absent "  and does not claim the file is clean" "no duplicate env declarations" \
  "was NOT analysed" "$out"

# Nested files and the .yml spelling must not be skipped.
mkdir -p "$work/mani/sub"
cp "$work/dup.yaml" "$work/mani/a.yaml"
cp "$work/dup.yaml" "$work/mani/b.yml"
cp "$work/dup.yaml" "$work/mani/sub/c.yaml"
files=$(kl_manifest_files "$work/mani")
want "manifest scan finds .yaml" "a.yaml" "$files"
want "manifest scan finds .yml" "b.yml" "$files"
want "manifest scan descends into subdirectories" "sub/c.yaml" "$files"

# ===========================================================================
printf '\nlive drift reporting\n'
# ===========================================================================
mkdir -p "$work/drift/deploy/k8s-local"
mkproj "$work/drift" '{"project":"demo","namespace":"demo-local","manifests":"deploy/k8s-local","workloads":{"app":"demo-api"}}'
cp "$work/dup.yaml" "$work/drift/deploy/k8s-local/patch.yaml"

livejson() { # <env-json-array>
  printf '{"spec":{"template":{"spec":{"containers":[{"name":"api","env":%s}]}}}}' "$1"
}

# Collapsed by a strategic merge: one entry survives, nothing warned.
export KL_TEST_LIVE_JSON=$(livejson '[{"name":"PUBLIC_BASE_URL","value":"http://localhost:3000"}]')
out=$(cd "$work/drift" && "$KLOCAL" status 2>&1)
want "collapsed duplicate is named as collapsed" "collapsed to one before apply" "$out"
want "collapsed duplicate reports the surviving value" "http://localhost:3000" "$out"
want "collapsed duplicate says the other was dropped" "dropped silently" "$out"
want "drift names the container" "container api" "$out"
want "drift names the workload the manifest defines" "demo-api/containers" "$out"

# Both survived a client-side apply: the kubelet uses the last.
export KL_TEST_LIVE_JSON=$(livejson '[{"name":"PUBLIC_BASE_URL","value":"first-value"},{"name":"PUBLIC_BASE_URL","value":"second-value"}]')
out=$(cd "$work/drift" && "$KLOCAL" status 2>&1)
want "surviving duplicates are counted" "live spec holds 2 copies" "$out"
want "effective value is the last, not the first" "the container sees the last: second-value" "$out"
want_absent "the shadowed first value is not reported as effective" \
  "sees the last: first-value" "live spec holds 2 copies" "$out"

# A multiline value is ONE entry. Emitting raw values through jsonpath made a
# single value containing newlines look like several live copies.
export KL_TEST_LIVE_JSON=$(livejson '[{"name":"PUBLIC_BASE_URL","value":"line1\nline2\nline3"}]')
out=$(cd "$work/drift" && "$KLOCAL" status 2>&1)
want "a multiline value is one entry, not three" "collapsed to one before apply" "$out"
want_absent "  and is not counted as multiple copies" "live spec holds" \
  "collapsed to one before apply" "$out"

# A surviving valueFrom is not a blank value; saying "live value: " sent the
# reader hunting for an inline value that was never there.
export KL_TEST_LIVE_JSON=$(livejson '[{"name":"PUBLIC_BASE_URL","valueFrom":{"secretKeyRef":{"name":"demo-api-secrets","key":"BASE"}}}]')
out=$(cd "$work/drift" && "$KLOCAL" status 2>&1)
want "a valueFrom source is named, not shown blank" "comes from secret:demo-api-secrets/BASE" "$out"
unset KL_TEST_LIVE_JSON

# A missing manifests directory must not read as a clean bill of health.
mkproj "$work/nomani" '{"project":"demo","namespace":"demo-local","manifests":"does/not/exist","workloads":{"app":"demo-api"}}'
out=$(cd "$work/nomani" && "$KLOCAL" status 2>&1)
want "a missing manifests dir is reported, not silently clean" "manifests directory not found" "$out"
want_absent "  and does not claim nothing is wrong" "no duplicate env declarations" \
  "manifests directory not found" "$out"

# So must an empty one.
mkdir -p "$work/emptymani/deploy/k8s-local"
mkproj "$work/emptymani" '{"project":"demo","namespace":"demo-local","manifests":"deploy/k8s-local","workloads":{"app":"demo-api"}}'
out=$(cd "$work/emptymani" && "$KLOCAL" status 2>&1)
want "an empty manifests dir says nothing was checked" "nothing was checked" "$out"

# A clean scan states how many files it actually read, so "no duplicates" can be
# told apart from "nothing was looked at".
mkdir -p "$work/cleanmani/deploy/k8s-local"
mkproj "$work/cleanmani" '{"project":"demo","namespace":"demo-local","manifests":"deploy/k8s-local","workloads":{"app":"demo-api"}}'
cp "$work/sidecar.yaml" "$work/cleanmani/deploy/k8s-local/app.yaml"
out=$(cd "$work/cleanmani" && "$KLOCAL" status 2>&1)
want "a clean scan reports how many files it read" "no duplicate env declarations in 1 file(s)" "$out"

export KL_TEST_INGRESS_HOSTS="scratch.lvh.me
admin.lvh.me"
out=$(kl_ingress_hosts demo-local)
want "ingress hosts are read from the cluster" "scratch.lvh.me" "$out"
want "every ingress host is listed" "admin.lvh.me" "$out"
unset KL_TEST_INGRESS_HOSTS

# ===========================================================================
printf '\nnamespace agreement with kustomize\n'
# ===========================================================================
# kustomize carries its own namespace and it is the one that decides where
# objects land; a mismatch applies to one namespace and deletes another.
printf 'namespace: somewhere-else\n' >"$work/drift/deploy/k8s-local/kustomization.yaml"
out=$(cd "$work/drift" && "$KLOCAL" up --no-build 2>&1)
rc=$?
want "a namespace mismatch is refused" "namespace mismatch" "$out"
want "the mismatch names both values" "somewhere-else" "$out"
want_status "  and exits non-zero" 1 "$rc"

# The quoted-key spelling kustomize also honours. Matching only ^namespace:
# missed it, so resources went one place and the delete went another.
printf '"namespace": somewhere-else\n' >"$work/drift/deploy/k8s-local/kustomization.yaml"
out=$(cd "$work/drift" && "$KLOCAL" up --no-build 2>&1)
want "a quoted namespace key is still checked" "namespace mismatch" "$out"
printf 'namespace : somewhere-else\n' >"$work/drift/deploy/k8s-local/kustomization.yaml"
out=$(cd "$work/drift" && "$KLOCAL" up --no-build 2>&1)
want "a space before the colon is still checked" "namespace mismatch" "$out"

# kustomize accepts three filenames; checking only kustomization.yaml let the
# other two through unvalidated.
rm -f "$work/drift/deploy/k8s-local/kustomization.yaml"
printf 'namespace: somewhere-else\n' >"$work/drift/deploy/k8s-local/kustomization.yml"
out=$(cd "$work/drift" && "$KLOCAL" up --no-build 2>&1)
rc=$?
want "kustomization.yml is checked too" "namespace mismatch" "$out"
want_status "  and exits non-zero" 1 "$rc"
rm -f "$work/drift/deploy/k8s-local/kustomization.yml"
printf 'namespace: somewhere-else\n' >"$work/drift/deploy/k8s-local/Kustomization"
out=$(cd "$work/drift" && "$KLOCAL" up --no-build 2>&1)
rc=$?
want "Kustomization is checked too" "namespace mismatch" "$out"
want_status "  and exits non-zero" 1 "$rc"
rm -f "$work/drift/deploy/k8s-local/Kustomization"

# Agreement must actually proceed to apply, not merely reach preflight — the old
# assertion passed for any run that got as far as printing "preflight".
printf 'namespace: demo-local\n' >"$work/drift/deploy/k8s-local/kustomization.yaml"
out=$(cd "$work/drift" && "$KLOCAL" up --no-build 2>&1)
want_absent "matching namespaces are accepted" "namespace mismatch" "preflight" "$out"
# `kl_info "apply ..."` and `kl_info "waiting for rollout"` are both printed
# BEFORE the operation they announce, so asserting on them proved only that
# klocal reached the print. Assert on the recorded kubectl calls instead.
want "  and the run proceeds to apply the overlay" "apply -k" \
  "$(cut -d'|' -f2 "$KL_TEST_CTX_LOG" | grep '^apply' || true)"
want "  and waits for the rollout" "rollout status" \
  "$(cut -d'|' -f2 "$KL_TEST_CTX_LOG" | grep '^rollout' || true)"

# ===========================================================================
printf '\nconfig loading\n'
# ===========================================================================
out=$(cd "$work/p1" && "$KLOCAL" status 2>&1)
want "status reads the project config" "demo-local" "$out"

mkdir -p "$work/p1/api/deep/nested"
out=$(cd "$work/p1/api/deep/nested" && "$KLOCAL" status 2>&1)
want "config is found from a subdirectory" "demo-local" "$out"

out=$(cd "$work" && "$KLOCAL" status 2>&1)
rc=$?
want "missing config is a clear error" "no .k8s-local/project.json" "$out"
want_status "missing config exits non-zero" 1 "$rc"

# ===========================================================================
printf '\npsql role selection\n'
# ===========================================================================
out=$(cd "$work/pdb" && "$KLOCAL" psql --app -c 'select 1' 2>&1)
want "psql --app connects as the app role" "psql -U demo_app" "$out"
out=$(cd "$work/pdb" && "$KLOCAL" psql -c 'select 1' 2>&1)
want "psql defaults to the owning role" "psql -U demo" "$out"
mkproj "$work/pnoapp" '{"project":"demo","workloads":{"app":"demo-api","db":"demo-postgres"},"database":{"superuser":"demo"}}'
out=$(cd "$work/pnoapp" && "$KLOCAL" psql --app 2>&1)
rc=$?
want "psql --app without appRole is an error" "needs" "$out"
want_status "  and exits non-zero" 1 "$rc"

# A later psql option wins, so a trailing -U or a URI would quietly undo the role
# this command just chose. Refuse rather than appear to have honoured it.
for arg in "-U postgres" "--username=postgres" "-d otherdb" "--dbname=otherdb" \
  "-h prod-db.internal" "postgresql://postgres@prod/production"; do
  # shellcheck disable=SC2086 # deliberately splitting the pair under test
  out=$(cd "$work/pdb" && "$KLOCAL" psql --app $arg 2>&1)
  rc=$?
  want "psql refuses an overriding argument: $arg" "would override the connection" "$out"
  want_status "  and exits non-zero" 1 "$rc"
done

# The argv log proves the connection actually built the way we claim, with
# argument boundaries intact — "$*" alone could not have shown that.
: >"$KL_TEST_ARGV_LOG"
(cd "$work/pdb" && "$KLOCAL" psql --app -c 'select 1' >/dev/null 2>&1)
want "the app role is passed as its own argument" "ARG[demo_app]" "$(cat "$KL_TEST_ARGV_LOG")"
want "the database is passed as its own argument" "ARG[demo_dev]" "$(cat "$KL_TEST_ARGV_LOG")"
want "a multi-word -c stays one argument" "ARG[select 1]" "$(cat "$KL_TEST_ARGV_LOG")"

# ===========================================================================
printf '\nscaffold\n'
# ===========================================================================
mkdir -p "$work/fresh"
out=$("$KLOCAL" scaffold "$work/fresh" 2>&1)
want "scaffold reports what it wrote" "scaffolded" "$out"

for f in .k8s-local/project.json deploy/k8s-local/namespace.yaml \
  deploy/k8s-local/kustomization.yaml deploy/k8s-local/app.yaml \
  deploy/k8s-local/postgres.yaml deploy/k8s-local/redis.yaml \
  deploy/k8s-local/ingress.yaml deploy/k8s-local/app-deployment-patch.yaml \
  deploy/local/https-proxy.mjs; do
  if [ -f "$work/fresh/$f" ]; then ok "scaffold wrote $f"; else
    bad "scaffold wrote $f" "missing"
  fi
done

# The patch targets Deployment/PROJECT-api; some resource must define it, or
# kustomize fails after klocal has already created an empty namespace.
# Both strings must occur in the SAME YAML document: grepping for them
# independently would pass while the patch still had no target.
if awk 'BEGIN{RS="\n---\n"} /kind: Deployment/ && /\n  name: PROJECT-api\n/ {found=1} END{exit !found}' \
  "$work/fresh/deploy/k8s-local/app.yaml"; then
  ok "scaffold defines the Deployment its patch targets"
else
  bad "scaffold defines the Deployment its patch targets" \
    "no single document is both kind:Deployment and name:PROJECT-api"
fi

want "scaffolded kustomization lists app.yaml" "- app.yaml" \
  "$(cat "$work/fresh/deploy/k8s-local/kustomization.yaml")"

python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
  "$work/fresh/.k8s-local/project.json" 2>/dev/null &&
  ok "scaffolded project.json is valid JSON" ||
  bad "scaffolded project.json is valid JSON" "json.load failed"

# An unmatched glob stays literal and kl_duplicate_env_vars returns 0 on a
# non-existent file, so a scaffold that wrote nothing scored a row of passes.
tmpl_seen=0
for t in "$work/fresh"/deploy/k8s-local/*.yaml; do
  [ -f "$t" ] || continue
  tmpl_seen=$((tmpl_seen + 1))
  want_empty "shipped template has no duplicate env: ${t##*/}" \
    "$(kl_duplicate_env_vars "$t" 2>&1)" "$dup_control"
done
if [ "$tmpl_seen" -ge 5 ]; then
  ok "the template scan actually saw files" "$tmpl_seen"
else
  bad "the template scan actually saw files" "only $tmpl_seen matched; the loop proved nothing"
fi

printf 'EDITED BY THE USER\n' >"$work/fresh/deploy/k8s-local/ingress.yaml"
out=$("$KLOCAL" scaffold "$work/fresh" 2>&1)
want "re-scaffold skips existing files" "skip (exists)" "$out"
want "re-scaffold preserved user edits" "EDITED BY THE USER" \
  "$(cat "$work/fresh/deploy/k8s-local/ingress.yaml")"

# ===========================================================================
printf '\nround-3 review: the context guard\n'
# ===========================================================================
# Every case below is an input that the previous version accepted. They exist
# because a guard that has never been shown refusing a real attack is a comment.

# URL userinfo. `https://127.0.0.1:unused@prod.example.com:6443` is a legal URL
# whose HOST is prod.example.com; trimming at the first ':' returned 127.0.0.1,
# so the address check — the one thing a context name cannot fake — passed.
for evil in \
  "https://127.0.0.1:unused@prod.example.com:6443" \
  "https://10.0.0.1@prod.example.com:6443" \
  "https://user:127.0.0.1@203.0.113.9:6443"; do
  export KL_TEST_SERVER="$evil"
  printf 'rancher-desktop\n' >"$KL_TEST_CTX_FILE"
  host=$(kl_context_server_host rancher-desktop || true)
  want_absent "userinfo does not become the host: $evil" "127.0.0.1" "$host" "$host"
  if kl_context_is_local rancher-desktop; then
    bad "  and the context is refused" "was ACCEPTED as local"
  else ok "  and the context is refused"; fi
done
export KL_TEST_SERVER="https://127.0.0.1:6443"
host=$(kl_context_server_host rancher-desktop)
want "a plain loopback server still parses" "127.0.0.1" "$host"
export KL_TEST_SERVER="https://[::1]:6443"
host=$(kl_context_server_host rancher-desktop)
want "a bracketed IPv6 server still parses" "::1" "$host"

# Glob metacharacters. KL_KUBECTL is exported as a command string and the hook
# has to expand it unquoted, so `kind-?` globbed against the project directory.
for g in "kind-?" "kind-*" "k3d-[ab]" "kind-a]b"; do
  if kl_context_name_is_local "$g"; then
    bad "glob metacharacter in a context name is refused: $g" "was ACCEPTED"
  else ok "glob metacharacter in a context name is refused: $g"; fi
done
for g in kind-dev k3d-mycluster rancher-desktop; do
  if kl_context_name_is_local "$g"; then ok "ordinary context still accepted: $g"; else
    bad "ordinary context still accepted: $g" "was refused"
  fi
done

# The re-check compares the WHOLE server URL. Two local clusters differ only by
# port, and comparing hosts let a swap between them through.
export KL_TEST_SERVER="https://127.0.0.1:6443"
printf 'rancher-desktop\n' >"$KL_TEST_CTX_FILE"
before=$(kl_context_server_url rancher-desktop)
export KL_TEST_SERVER="https://127.0.0.1:16443"
out=$(KL_CONTEXT=rancher-desktop kl_assert_context_unchanged rancher-desktop "$before" "the build" 2>&1)
rc=$?
want "a port-only cluster swap is caught" "now points at" "$out"
want_status "  and refuses" 1 "$rc"
export KL_TEST_SERVER="https://127.0.0.1:6443"
out=$(KL_CONTEXT=rancher-desktop kl_assert_context_unchanged rancher-desktop "$before" "the build" 2>&1)
rc=$?
want_status "an unchanged context passes the re-check" 0 "$rc"
want_empty "  and says nothing when nothing changed" "$out" "$before"

# rebuild and down are write paths and must re-verify, exactly as up does.
# `up` had the only call site, so a context remapped during a rebuild, or during
# the unbounded wait at `down`'s confirmation prompt, was never re-checked.
grep -q 'kl_assert_context_unchanged' "$plugin/bin/klocal" &&
  n_assert=$(grep -c 'kl_assert_context_unchanged "\$KL_CONTEXT"' "$plugin/bin/klocal") || n_assert=0
if [ "${n_assert:-0}" -ge 3 ]; then
  ok "up, rebuild and down all re-verify the context" "$n_assert call sites"
else
  bad "up, rebuild and down all re-verify the context" \
    "only ${n_assert:-0} of 3 write paths call kl_assert_context_unchanged"
fi

# ===========================================================================
printf '\nround-3 review: psql connection override\n'
# ===========================================================================
# psql accepts -U demo, -Udemo and a bare positional dbname. Only the first was
# refused, so `--app -Udemo` silently reconnected as the superuser and the RLS
# check that is the entire point of --app proved nothing.
mkproj "$work/pg" '{"project":"demo","namespace":"demo-local","workloads":{"app":"demo-api","db":"demo-postgres"},"database":{"name":"demo_dev","superuser":"demo","appRole":"demo_app"}}'
for bad_arg in "-Udemo" "-dpostgres://evil/db" "-hprod.example.com" \
  "--username=demo" "--dbname=other" "mydb" "postgresql://postgres@prod/production"; do
  : >"$KL_TEST_ARGV_LOG"
  out=$(cd "$work/pg" && "$KLOCAL" psql --app "$bad_arg" 2>&1)
  rc=$?
  want "psql refuses a connection override: $bad_arg" "refusing" "$out"
  want_status "  and exits non-zero" 1 "$rc"
  want_empty "  and never reached the pod" \
    "$(grep -F 'ARG[exec]' "$KL_TEST_ARGV_LOG" || true)" \
    "$(cd "$work/pg" && "$KLOCAL" psql --app -c 'select 1' >/dev/null 2>&1
      grep -c . "$KL_TEST_ARGV_LOG" | grep -v '^0$' || echo control-failed)"
done
# Legitimate arguments must still work, or the guard has just broken the command.
: >"$KL_TEST_ARGV_LOG"
out=$(cd "$work/pg" && "$KLOCAL" psql --app -c 'select current_user' 2>&1)
want "psql still allows -c with its value" "kubectl exec ran" "$out"
want "  and connects as the app role" "demo_app" "$(grep -F 'ARG[demo_app]' "$KL_TEST_ARGV_LOG" || true)"
out=$(cd "$work/pg" && "$KLOCAL" psql -f /tmp/x.sql 2>&1)
want "psql still allows -f with its value" "kubectl exec ran" "$out"
out=$(cd "$work/pg" && "$KLOCAL" psql -c 2>&1)
rc=$?
want "an option with no value is refused, not forwarded" "expects a value" "$out"
want_status "  and exits non-zero" 1 "$rc"

# ===========================================================================
printf '\nround-3 review: kustomization namespace spellings\n'
# ===========================================================================
mkproj "$work/ns" '{"project":"demo","namespace":"demo-local","workloads":{"app":"demo-api"}}'
mkdir -p "$work/ns/deploy/k8s-local"
ns_case() { # <label> <kustomization-content> <want-substring-in-output> <want-rc>
  printf '%s' "$2" >"$work/ns/deploy/k8s-local/kustomization.yaml"
  out=$(cd "$work/ns" && "$KLOCAL" up --no-build 2>&1)
  rc=$?
  want "$1" "$3" "$out"
  want_status "  rc" "$4" "$rc"
}
# JSON is a legal kustomization, and the line-anchored reader saw nothing at all,
# so resources went to `other` while klocal waited in — and would delete —
# demo-local.
ns_case "a JSON kustomization naming another namespace is caught" \
  '{"namespace":"other","resources":["app.yaml"]}
' "namespace mismatch" 1
ns_case "a quoted-key namespace is caught" \
  '"namespace": "other"
' "namespace mismatch" 1
# A trailing comment used to end up inside the compared name and fail a config
# that was perfectly correct.
ns_case "a trailing comment does not break a matching namespace" \
  'namespace: demo-local # the local overlay
resources:
  - app.yaml
' "apply deploy/k8s-local" 0
ns_case "a JSON kustomization that agrees is accepted" \
  '{"namespace":"demo-local","resources":["app.yaml"]}
' "apply deploy/k8s-local" 0
# A namespace key whose value cannot be extracted must REFUSE, not shrug: a
# silent pass here is what lets `down` delete the wrong namespace.
ns_case "an unreadable namespace value is refused, not assumed" \
  'namespace:
resources:
  - app.yaml
' "cannot read the namespace" 1
# No namespace at all is the ordinary case and must still run.
ns_case "no namespace key at all still runs" \
  'resources:
  - app.yaml
' "apply deploy/k8s-local" 0
# Enough matching lines to fill a pipe buffer used to kill klocal with SIGPIPE
# and no message, because head -1 exited before sed finished writing.
awk 'BEGIN{print "namespace: demo-local"; for(i=0;i<20000;i++) print "namespace: demo-local"}' \
  >"$work/ns/deploy/k8s-local/kustomization.yaml"
out=$(cd "$work/ns" && "$KLOCAL" up --no-build 2>&1)
rc=$?
want "a huge kustomization does not die of SIGPIPE" "apply deploy/k8s-local" "$out"
want_status "  and exits cleanly" 0 "$rc"
rm -rf "$work/ns/deploy"

# ===========================================================================
printf '\nround-3 review: the manifest scanner reads or says it cannot\n'
# ===========================================================================
# A trailing comment used to become part of the workload name, which then went to
# kubectl, failed, and made every variable read as absent from the cluster.
cat >"$work/cmt.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-api # the application
spec:
  template:
    spec:
      containers:
        - name: api # the only container
          env:
            - name: DUPE # first
              value: "one"
            - name: DUPE # second
              value: "two"
YAML
scan=$(kl_duplicate_env_vars "$work/cmt.yaml" 2>&1)
want "a commented workload name is read without the comment" "DUP demo-api containers api DUPE 2" "$scan"
want_absent "  and the comment text is gone" "#" "DUP demo-api" "$scan"

# `--- # comment` is an ordinary separator; missing it merged the documents and
# attributed the duplicate to the previous object.
cat >"$work/sep.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: first-thing
--- # the second document
apiVersion: apps/v1
kind: Deployment
metadata:
  name: second-api
spec:
  template:
    spec:
      containers:
        - name: api
          env:
            - name: DUPE
              value: "one"
            - name: DUPE
              value: "two"
YAML
scan=$(kl_duplicate_env_vars "$work/sep.yaml" 2>&1)
want "a commented document separator still separates" "DUP second-api" "$scan"
want_absent "  and the duplicate is not blamed on the previous document" \
  "first-thing" "DUP second-api" "$scan"

# An env entry whose first key is not `name:` is valid YAML this line-oriented
# scanner cannot pair up. Staying quiet printed "no duplicate env declarations",
# a false all-clear on the very file the user asked about.
cat >"$work/order.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-api
spec:
  template:
    spec:
      containers:
        - name: api
          env:
            - value: "1"
              name: FOO
            - value: "2"
              name: FOO
YAML
scan=$(kl_duplicate_env_vars "$work/order.yaml" 2>&1)
want "an env entry not starting with name: is reported as unreadable" \
  "UNREADABLE" "$scan"
want "  and names the reason" "env-entry-not-starting-with-name" "$scan"

# ===========================================================================
printf '\nround-3 review: a failed read is not an absence\n'
# ===========================================================================
export KL_TEST_LIVE_JSON=''
if kl_env_of demo-local demo-api containers api APP_ENV >/dev/null 2>&1; then
  bad "an unreadable Deployment is not reported as absent" "returned success"
else
  ok "an unreadable Deployment is not reported as absent" "rc=$?"
fi
export KL_TEST_LIVE_JSON='{"spec":{"template":{"spec":{"containers":[{"name":"api","env":[{"name":"APP_ENV","value":"dev"}]}]}}}}'
live=$(kl_env_of demo-local demo-api containers api APP_ENV)
want "a readable Deployment yields the live value" "dev" "$live"
want "  tagged with its source" "value" "$live"
# A TAB inside a value used to split the record, truncating the value and
# turning the source column into the rest of the value.
export KL_TEST_LIVE_JSON='{"spec":{"template":{"spec":{"containers":[{"name":"api","env":[{"name":"APP_ENV","value":"a\tb"}]}]}}}}'
live=$(kl_env_of demo-local demo-api containers api APP_ENV)
want "a TAB in a value is escaped, not left to split the record" 'a\tb' "$live"
want "  so the source column survives" "value" "$(printf '%s' "$live" | cut -f2)"
unset KL_TEST_LIVE_JSON

# ===========================================================================
printf '\nround-3 review: behaviour under the caller errexit\n'
# ===========================================================================
# bin/klocal runs `set -euo pipefail`; this suite runs `set -uo pipefail`. That
# single difference hid a broken contract: with errexit the shell exits AT the
# assignment, so `x=$(cmd); rc=$?` never reached the rc line, and a genuinely
# absent Secret killed the caller instead of running the generator.
errexit_case() { # <label> <env-assignments> <expected-output-substring> <expected-rc>
  cat >"$work/errexit.sh" <<EOF
set -euo pipefail
. "$plugin/scripts/lib/common.sh"
. "$plugin/scripts/lib/cluster.sh"
KL_CONTEXT=rancher-desktop
gen() { printf 'FRESHLY-GENERATED'; }
v=\$(kl_keep_or_generate demo-local demo-api-secrets REDIS_PASSWORD gen) && r=0 || r=\$?
printf 'OUT=[%s] RC=%s\n' "\$v" "\$r"
EOF
  out=$(env $2 bash "$work/errexit.sh" 2>&1)
  want "$1" "$3" "$out"
}
errexit_case "under set -e, an absent Secret still generates" \
  "KL_TEST_SECRET_EXISTS_RC=1" "OUT=[FRESHLY-GENERATED] RC=0"
errexit_case "under set -e, an existing value is still reused" \
  "KL_TEST_SECRET_EXISTS_RC=0 KL_TEST_SECRET_KEYS=REDIS_PASSWORD KL_TEST_SECRET_VALUE=kept" \
  "OUT=[kept] RC=0"
errexit_case "under set -e, a forbidden read still refuses out loud" \
  "KL_TEST_SECRET_FORBIDDEN=1" "refusing to generate"
# And the documented status code survives, rather than collapsing to a bare 1.
cat >"$work/rc.sh" <<EOF
set -euo pipefail
. "$plugin/scripts/lib/common.sh"
. "$plugin/scripts/lib/cluster.sh"
KL_CONTEXT=rancher-desktop
kl_secret_value demo-local demo-api-secrets REDIS_PASSWORD && r=0 || r=\$?
printf 'RC=%s\n' "\$r"
EOF
out=$(KL_TEST_SECRET_FORBIDDEN=1 bash "$work/rc.sh" 2>&1)
want "under set -e, 'cannot read' is still code 2, not 1" "RC=2" "$out"
out=$(KL_TEST_SECRET_EXISTS_RC=1 bash "$work/rc.sh" 2>&1)
want "under set -e, 'absent' is still code 1" "RC=1" "$out"

# ===========================================================================
printf '\nround-3 review: config validation and path handling\n'
# ===========================================================================
# tls.port is interpolated into the reachable URL. Unvalidated, a `|` closed the
# sed substitution and the rest became further sed commands, `w <path>` included.
for badport in "8443|w /tmp/klocal-should-not-exist" "80&81" "notaport" "0" "70000" "-1"; do
  mkproj "$work/badport" "{\"project\":\"demo\",\"namespace\":\"demo-local\",\"workloads\":{\"app\":\"demo-api\"},\"tls\":{\"port\":\"$badport\"}}"
  out=$(cd "$work/badport" && "$KLOCAL" status 2>&1)
  rc=$?
  want "tls.port rejected: $badport" "tls.port" "$out"
  want_status "  and exits non-zero" 1 "$rc"
done
if [ -e /tmp/klocal-should-not-exist ]; then
  bad "the rejected tls.port wrote no file" "/tmp/klocal-should-not-exist was created"
  rm -f /tmp/klocal-should-not-exist
else
  ok "the rejected tls.port wrote no file"
fi
mkproj "$work/goodport" '{"project":"demo","namespace":"demo-local","workloads":{"app":"demo-api"},"tls":{"port":8443}}'
out=$(cd "$work/goodport" && "$KLOCAL" status 2>&1)
want_absent "a valid tls.port is accepted" "tls.port" "context:" "$out"

# dirname is a fixed point at "." as well as "/", so a relative start looped
# forever with no exit condition.
( cd "$work" && kl_find_config "." >/dev/null 2>&1 ) &
find_pid=$!
find_done=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  kill -0 "$find_pid" 2>/dev/null || { find_done=1; break; }
  sleep 0.3
done
if [ "$find_done" = 1 ]; then
  ok "kl_find_config terminates on a relative path"
else
  kill -9 "$find_pid" 2>/dev/null
  bad "kl_find_config terminates on a relative path" "still running after 3s — infinite loop"
fi
wait "$find_pid" 2>/dev/null || true
cfg=$(cd "$work/p1" && kl_find_config "." || true)
want "  and still finds the config from a relative path" "project.json" "$cfg"

# The README tells you to symlink bin/klocal onto PATH. pwd -P resolves the
# link's DIRECTORY, not the link, so every command died before dispatching.
mkdir -p "$work/linkbin"
ln -sf "$KLOCAL" "$work/linkbin/klocal"
out=$("$work/linkbin/klocal" help 2>&1)
rc=$?
want "a symlinked klocal finds its libraries" "klocal - run this project's stack" "$out"
want_status "  and exits cleanly" 0 "$rc"
ln -sf "$work/linkbin/klocal" "$work/linkbin/klocal2"
out=$("$work/linkbin/klocal2" help 2>&1)
want "a symlink to a symlink also works" "klocal - run this project's stack" "$out"

# ===========================================================================
printf '\nround-3 review: the engine must match the cluster, not the socket\n'
# ===========================================================================
# nerdctl answering says a containerd exists somewhere, not that THIS cluster
# reads it. With both engines installed and the context on docker-desktop, the
# build used to land in a store docker-desktop never reads.
mk_stub docker 0
mk_stub nerdctl 0 # both sockets answer: Rancher on containerd + Docker Desktop
export KL_CONTEXT=docker-desktop
out=$(kl_build_image demo:local "$work" 2>&1)
want "docker-desktop builds with docker even when nerdctl answers" "docker ran: build" "$out"
# The unwanted string is "nerdctl ran:", not "nerdctl ran: build" — nerdctl is
# always invoked as `--namespace k8s.io build`, so the longer string could never
# have appeared and the check would have passed even on a containerd build.
want_absent "  and not into containerd" "nerdctl ran:" "docker ran: build" "$out"
export KL_CONTEXT=rancher-desktop
out=$(kl_build_image demo:local "$work" 2>&1)
want "rancher-desktop on containerd still uses nerdctl" "nerdctl ran: --namespace k8s.io build" "$out"
mk_stub nerdctl 1

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
if [ "$SELF_CHECK" = 1 ]; then
  printf '\nself-check (these four MUST fail)\n'
  before=$fail
  want "deliberate: substring that cannot match" "IMPOSSIBLE-XYZZY" "hello world"
  want "deliberate: empty expectation must not pass" "" "hello world"
  want "deliberate: empty output must not pass" "anything" ""
  want_empty "deliberate: empty control must not pass" "" ""
  broke=$((fail - before))
  printf '\n'
  if [ "$broke" = 4 ]; then
    printf 'self-check: 4/4 deliberate failures detected — the harness can fail.\n'
    fail=$before
    pass=$((pass + 4))
  else
    printf 'self-check: BROKEN — only %s of 4 deliberate failures were caught.\n' "$broke"
    printf 'The suite cannot be trusted; a green run would prove nothing.\n'
    exit 1
  fi
fi

printf '\n%s passed, %s failed, %s skipped\n' "$pass" "$fail" "$skip"
# A skip is not a pass. Saying so out loud is the difference between "the suite
# is green" and "the suite is green over the parts that ran".
[ "$skip" -eq 0 ] || printf \
  'NOTE: %s check(s) did not run — this is not a full-coverage green.\n' "$skip"
[ "$fail" -eq 0 ] || exit 1
[ "$pass" -gt 0 ] || {
  printf 'no assertions ran at all — treating that as failure\n'
  exit 1
}
