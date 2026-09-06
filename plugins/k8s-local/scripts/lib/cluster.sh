# Cluster-facing helpers for klocal: context guard, image build, secret reuse,
# and manifest-vs-live drift.
#
# Sourced, never executed. Each function is written to be callable on its own so
# the test suite can drive it against a stubbed kubectl.

# --- context guard ---------------------------------------------------------
# Two independent checks, because neither is sufficient alone.
#
# The name is a hint, not evidence: `kind-*` and `k3d-*` names are chosen by
# whoever created the cluster, so a remote cluster can be called `kind-prod` and
# a `docker-desktop` entry can be re-pointed at anything. The name check exists
# to catch the ordinary mistake early and with a clear message.
#
# The address is the actual proof: a cluster whose API server is on loopback or
# a private network is local in the sense that matters here.
kl_context_name_is_local() { # <context>
  # Whitespace here would split the kind/k3d loader command built from this name.
  case "$1" in
    *[[:space:]]*) return 1 ;;
  esac
  # Glob metacharacters would EXPAND when the name travels through an unquoted
  # expansion. KL_KUBECTL is exported as a command string and the documented hook
  # invokes it unquoted (it has to, to split into arguments), so a context named
  # `kind-?` in a project containing a file `kind-p` rewrote the hook's own
  # --context to a different cluster. The loaders were already fixed by passing an
  # explicit argument list; the hook cannot be, so the name is refused instead.
  case "$1" in
    *[*?[]* | *]*) return 1 ;;
  esac
  case "$1" in
    rancher-desktop | docker-desktop | minikube | colima) return 0 ;;
    kind-* | k3d-*) return 0 ;;
    *) return 1 ;;
  esac
}

# One field of the CURRENT-ly selected cluster, via --minify.
#
# The context name is passed as a FLAG VALUE, never interpolated into the
# JSONPath. Building "jsonpath={.contexts[?(@.name=='$ctx')]...}" let a context
# named  kind-x')].context.cluster}{.contexts[0].context.cluster}{.contexts[?(@.name=='x
# close the expression and append two more: kubectl composes {...}{...}, so the
# host check could be pointed at a loopback decoy while every real call used the
# remote context. Verified: composed JSONPath does evaluate all parts.
kl_cluster_field() { # <context> <jsonpath-after-.cluster>
  kubectl config view --minify --context "$1" -o \
    "jsonpath={.clusters[0].cluster.$2}" 2>/dev/null || true
}

# The whole `server` field, used to prove the cluster behind a context has not
# been swapped. The HOST alone is not enough: two different local clusters differ
# only by port, and comparing hosts accepted a switch between them.
kl_context_server_url() { # <context>
  local server
  server=$(kl_cluster_field "$1" server)
  [ -n "$server" ] || return 1
  printf '%s\n' "$server"
}

# Host part of a cluster's API server URL. Handles the bracketed IPv6 form.
#
# The USERINFO field is removed first, and this is the whole point of the
# function. `https://127.0.0.1:unused@prod.example.com:6443` is a legal URL whose
# host is prod.example.com; trimming at the first `:` instead returned
# "127.0.0.1", so the one check that naming cannot fake accepted a remote cluster
# outright. RFC 3986: userinfo runs to the LAST `@` in the authority.
kl_context_server_host() { # <context>
  local server host
  server=$(kl_context_server_url "$1") || return 1
  host=${server#*://}
  host=${host%%/*}
  host=${host%%\?*}
  host=${host%%#*}
  case "$host" in
    *@*) host=${host##*@} ;;
  esac
  case "$host" in
    "["*)
      host=${host#[}
      host=${host%%]*}
      ;; # [::1]:6443
    *) host=${host%%:*} ;;
  esac
  # An empty or still-suspicious authority is a refusal, not a pass.
  [ -n "$host" ] || return 1
  printf '%s\n' "$host"
}

# A loopback `server` proves nothing when the connection is tunnelled elsewhere:
# kubectl sends every request through proxy-url, and tls-server-name changes which
# certificate is accepted. Neither is anything a local cluster needs, so their
# presence is a refusal rather than something to interpret.
kl_context_has_indirection() { # <context> -> 0 if proxy-url/tls-server-name set
  local p t
  p=$(kl_cluster_field "$1" proxy-url)
  t=$(kl_cluster_field "$1" tls-server-name)
  [ -n "$p" ] || [ -n "$t" ]
}

# Loopback, link-local, or RFC1918. Deliberately conservative: an address this
# does not recognise is treated as remote.
#
# The private ranges are matched only against a real dotted-decimal literal, never
# as a text prefix. A glob like 10.* also matches `10.prod.example.com`, and
# `127.*` matches `127.attacker.net` — a remote cluster would have walked straight
# through the one check that is supposed to be unfakeable.
kl_host_is_local() { # <host>
  local h=$1 o1 o2
  case "$h" in
    localhost | localhost.localdomain | host.docker.internal \
      | kubernetes.docker.internal | host.lima.internal) return 0 ;;
    *.local) return 0 ;; # mDNS
  esac

  # IPv6: loopback, link-local fe80::/10, unique-local fc00::/7.
  case "$h" in
    *:*)
      case "$h" in
        ::1 | 0:0:0:0:0:0:0:1) return 0 ;;
        fe8*:* | fe9*:* | fea*:* | feb*:*) return 0 ;;
        fc*:* | fd*:*) return 0 ;;
      esac
      return 1
      ;;
  esac

  # Everything else must be exactly four dot-separated decimal octets.
  case "$h" in
    *[!0-9.]*) return 1 ;;    # any non-digit, non-dot character
    *.*.*.*.*) return 1 ;;    # too many parts
    *.*.*.*) : ;;             # exactly four
    *) return 1 ;;
  esac

  # Every octet must be a real 0-255 value: 10.999.999.999 is not an address, and
  # a resolver may well treat it as a name and look it up somewhere remote.
  local rest=$h part
  while [ -n "$rest" ]; do
    case "$rest" in
      *.*)
        part=${rest%%.*}
        rest=${rest#*.}
        ;;
      *)
        part=$rest
        rest=""
        ;;
    esac
    case "$part" in
      "" | *[!0-9]*) return 1 ;;
    esac
    [ "${#part}" -le 3 ] || return 1
    [ "$part" -le 255 ] 2>/dev/null || return 1
  done

  o1=${h%%.*}
  o2=${h#*.}
  o2=${o2%%.*}
  [ -n "$o1" ] && [ -n "$o2" ] || return 1

  case "$o1" in
    0 | 127) return 0 ;; # unspecified, loopback
    10) return 0 ;;      # RFC1918 /8
    192) [ "$o2" = "168" ] && return 0 ;;
    169) [ "$o2" = "254" ] && return 0 ;;
    172) # RFC1918 172.16.0.0/12
      case "$o2" in
        1[6-9] | 2[0-9] | 3[01]) return 0 ;;
      esac
      ;;
  esac
  return 1
}

kl_current_context() {
  kubectl config current-context 2>/dev/null || true
}

# Both checks, without exiting — for callers that report rather than refuse.
# Read-only commands still must not query a cluster they have not verified, so
# they use this rather than the name check alone.
kl_context_is_local() { # <context>
  local host
  [ -n "$1" ] || return 1
  kl_context_name_is_local "$1" || return 1
  kl_context_has_indirection "$1" && return 1
  host=$(kl_context_server_host "$1") || return 1
  kl_host_is_local "$host" || return 1
  return 0
}

# A build takes minutes, and `down` waits at a confirmation prompt for as long as
# the operator takes to answer. In either window another terminal can switch the
# kubeconfig, or remap the same context name onto a different cluster. Pinning
# --context carries the NAME forward, not the cluster it pointed at, so re-verify
# before anything is written or deleted.
#
# Compares the whole server URL, not just the host: two local clusters commonly
# differ only by port, and a host-only comparison let a swap between them through.
kl_assert_context_unchanged() { # <context> <server-url-seen-earlier> [what]
  local now url what=${3:-the build}
  now=$(kl_current_context)
  [ "$now" = "$1" ] || kl_die \
    "REFUSING: the current context changed from '$1' to '${now:-<none>}' during $what"
  url=$(kl_context_server_url "$1") ||
    kl_die "REFUSING: cannot re-read the API server address for '$1'"
  [ "$url" = "$2" ] || kl_die \
    "REFUSING: context '$1' now points at $url, not $2, as it did before $what"
  kl_context_has_indirection "$1" &&
    kl_die "REFUSING: context '$1' gained proxy-url/tls-server-name during $what"
  return 0
}

# Fails closed at every step: no context, an unrecognised name, an unreadable
# kubeconfig, or a non-private API server are all refusals.
#
# Prints the verified context name on stdout. Callers MUST pin every subsequent
# kubectl call to it with --context (see kl_kubectl): checking `current-context`
# and then relying on it later is a race — a build takes minutes, and another
# terminal can switch the shared kubeconfig in between.
kl_require_local_context() {
  local ctx host
  ctx=$(kl_current_context)
  [ -n "$ctx" ] || kl_die "no kubectl context — start your local cluster first"

  # kl_image_load_cmd derives a cluster name from the context and the result is
  # word-split on purpose; whitespace in the name would silently pass the wrong
  # --name to kind/k3d. Nothing legitimate has it, so refuse it outright.
  case "$ctx" in
    *[[:space:]]*) kl_die "REFUSING: context name contains whitespace: '$ctx'" ;;
  esac

  if ! kl_context_name_is_local "$ctx"; then
    printf 'klocal: REFUSING: context '\''%s'\'' does not look local.\n' "$ctx" >&2
    printf '        Local contexts: rancher-desktop, docker-desktop, minikube, colima, kind-*, k3d-*\n' >&2
    printf '        Switch with: kubectl config use-context rancher-desktop\n' >&2
    exit 1
  fi

  if kl_context_has_indirection "$ctx"; then
    printf 'klocal: REFUSING: context '\''%s'\'' sets proxy-url or tls-server-name.\n' "$ctx" >&2
    printf '        The API server address then says nothing about where requests go.\n' >&2
    exit 1
  fi

  host=$(kl_context_server_host "$ctx") ||
    kl_die "REFUSING: cannot read the API server address for context '$ctx'"
  if ! kl_host_is_local "$host"; then
    printf 'klocal: REFUSING: context '\''%s'\'' is named like a local cluster but its\n' "$ctx" >&2
    printf '        API server is at %s, which is not loopback or a private network.\n' "$host" >&2
    printf '        A local-looking name on a remote cluster is exactly what this check is for.\n' >&2
    exit 1
  fi

  kubectl --context "$ctx" cluster-info >/dev/null 2>&1 ||
    kl_die "cluster unreachable (context $ctx)"
  printf '%s\n' "$ctx"
}

# Every cluster call goes through here, pinned to the context that was verified.
# KL_CONTEXT is set once by preflight and never re-read from the kubeconfig.
kl_kubectl() {
  [ -n "${KL_CONTEXT:-}" ] || kl_die "internal: kl_kubectl called before the context was verified"
  kubectl --context "$KL_CONTEXT" "$@"
}

# --- ingress ---------------------------------------------------------------
# A missing IngressClass is a warning, never a failure: the stack still runs and
# port-forward still works. But it must be said out loud, because the manifests
# apply cleanly and the rollout goes green while every hostname routes nowhere,
# which is a miserable thing to debug from the symptom end.
kl_check_ingressclass() { # <class>
  if kl_kubectl get ingressclass "$1" >/dev/null 2>&1; then
    kl_step "ingressclass: $1"
    return 0
  fi
  kl_warn "no IngressClass '$1' in this cluster."
  kl_step "k3s-based clusters (Rancher Desktop, k3d) ship traefik; Docker Desktop,"
  kl_step "kind and minikube do not until you install one."
  kl_step "The stack will still run, but no hostname will route. Use kubectl port-forward,"
  kl_step "or install a controller — see references/engines.md."
  return 0
}

# --- image build -----------------------------------------------------------
# Probe the SOCKET, not the binary. Rancher Desktop ships nerdctl even when the
# configured engine is moby, and there it cannot reach the k3s containerd
# socket — so `command -v nerdctl` succeeding proves nothing.
kl_detect_engine() { # -> "nerdctl" | "docker" | "" (and never fails)
  if command -v nerdctl >/dev/null 2>&1 && nerdctl --namespace k8s.io info >/dev/null 2>&1; then
    printf 'nerdctl\n'
  elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    printf 'docker\n'
  else
    printf '\n'
  fi
}

# Only Rancher Desktop and Docker Desktop share an image store with the cluster.
# kind, k3d and minikube each run the node in their own container or VM, so a
# host build is invisible there and the pod keeps running the previous image
# with no error anywhere — the worst possible symptom.
kl_image_load_cmd() { # <context> <image> -> prints the load command, or nothing
  local ctx=$1 image=$2
  case "$ctx" in
    kind-*) printf 'kind load docker-image %s --name %s\n' "$image" "${ctx#kind-}" ;;
    k3d-*) printf 'k3d image import %s -c %s\n' "$image" "${ctx#k3d-}" ;;
    minikube) printf 'minikube image load %s\n' "$image" ;;
    *) : ;; # rancher-desktop, docker-desktop, colima: shared store, nothing to do
  esac
}

# Contexts whose cluster reads the DOCKER store, either by sharing the daemon
# (docker-desktop) or because their loader imports from it (kind/k3d/minikube).
# A reachable nerdctl socket says a containerd exists somewhere on the machine —
# it does not say the selected cluster reads it. With Rancher Desktop on
# containerd installed alongside Docker Desktop, both probes answer, and picking
# nerdctl by probe order built the image into a store `docker-desktop` never
# reads, with no error anywhere: the stale-image symptom this file exists to stop.
kl_context_wants_docker() { # <context>
  [ -n "$(kl_image_load_cmd "$1" x)" ] && return 0
  case "$1" in
    docker-desktop) return 0 ;;
  esac
  return 1
}

# Builds into the local engine, then imports into the cluster when the engine and
# the cluster do not share a store.
kl_build_image() { # <image> <context-dir>
  local image=$1 context=$2 engine load
  engine=$(kl_detect_engine)

  # When the cluster reads the docker store, the loader looks in its PROVIDER's
  # store — Docker for a default kind/k3d/minikube cluster. Building into
  # nerdctl's k8s.io namespace just because that socket answers would leave the
  # loader (or the kubelet) unable to find the tag.
  if kl_context_wants_docker "${KL_CONTEXT:-}" && [ "$engine" = "nerdctl" ]; then
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
      kl_step "context ${KL_CONTEXT} imports from the docker store; using docker, not nerdctl"
      engine=docker
    else
      kl_warn "context ${KL_CONTEXT} needs an image import, but only nerdctl is available."
      kl_warn "If the cluster was created with the docker provider, the import will not find the image."
    fi
  fi

  case "$engine" in
    nerdctl)
      # containerd engine: k3s reads the k8s.io namespace directly.
      kl_step "engine: nerdctl (containerd, namespace k8s.io)"
      nerdctl --namespace k8s.io build -t "$image" "$context"
      ;;
    docker)
      # moby engine: a Rancher/Docker Desktop cluster shares this daemon.
      kl_step "engine: docker (moby)"
      docker build -t "$image" "$context"
      ;;
    *)
      kl_die "no working container engine — start Rancher Desktop (or Docker) and retry"
      ;;
  esac

  load=$(kl_image_load_cmd "${KL_CONTEXT:-}" "$image")
  if [ -n "$load" ]; then
    kl_step "importing into the cluster: $load"
    # No fallback: silently skipping the import is what leaves the node running
    # a stale image, so a missing kind/k3d/minikube binary must be fatal.
    command -v "${load%% *}" >/dev/null 2>&1 ||
      kl_die "${load%% *} not found, but context '$KL_CONTEXT' needs it to see the image"
    kl_run_image_load "${KL_CONTEXT:-}" "$image"
  fi
}

# Runs the loader with an explicit argument list. Splitting the printed command
# string instead exposed the cluster name to word-splitting AND pathname
# expansion: a context named `kind-*` would have globbed against the working
# directory, and `kind-dev --name other` would have appended a second --name.
kl_run_image_load() { # <context> <image>
  case "$1" in
    kind-*) kind load docker-image "$2" --name "${1#kind-}" ;;
    k3d-*) k3d image import "$2" -c "${1#k3d-}" ;;
    minikube) minikube image load "$2" ;;
    *) : ;;
  esac
}

# --- secrets ---------------------------------------------------------------
# Distinguishes three outcomes that must not be conflated:
#   0 + value  the key is present
#   1          the Secret or key does not exist (a normal first run)
#   2          the read itself failed (API down, RBAC, broken base64)
# Treating case 2 as case 1 makes the caller generate a fresh value and overwrite
# a credential a running container still holds — the exact outage kl_keep_or_generate
# exists to prevent.
#
# Every failing command below is captured with `x=$(cmd) && rc=0 || rc=$?`, never
# `x=$(cmd); rc=$?`. Under the caller's `set -e` — which bin/klocal has and the
# test suite did NOT — the second form never reaches the `rc=$?` line at all: the
# shell exits at the assignment. That silently turned this whole three-way
# contract into "exit 1, no message", including for a genuinely absent Secret,
# where the generator then never ran.
kl_secret_value() { # <namespace> <secret> <key>
  local ns=$1 secret=$2 key=$3 exists rc keys raw

  # The key is interpolated into a go-template below. Kubernetes only permits
  # alphanumerics, '-', '_' and '.' in a Secret key, so anything else is not a
  # key we could read anyway — refuse rather than build a broken template.
  case "$key" in
    "" | *[!a-zA-Z0-9._-]*) return 2 ;;
  esac

  # --ignore-not-found is what separates "absent" from "cannot read": a missing
  # Secret gives empty output and exit 0, while RBAC denial or an API failure
  # gives a non-zero exit. Inferring absence from a failed read instead meant a
  # forbidden Secret looked absent, and the caller then rotated a live credential.
  exists=$(kl_kubectl get secret "$secret" -n "$ns" -o name --ignore-not-found 2>/dev/null) &&
    rc=0 || rc=$?
  [ "$rc" -eq 0 ] || return 2
  [ -n "$exists" ] || return 1 # genuinely not there

  # List the keys rather than probing one: jsonpath {.data.tls.crt} looks up a
  # nested path that does not exist and returns empty, so any key containing a
  # dot read as "absent". A range over .data has no such problem.
  keys=$(kl_kubectl get secret "$secret" -n "$ns" \
    -o "go-template={{range \$k, \$v := .data}}{{\$k}}{{\"\n\"}}{{end}}" 2>/dev/null) &&
    rc=0 || rc=$?
  [ "$rc" -eq 0 ] || return 2
  printf '%s\n' "$keys" | grep -Fxq -- "$key" || return 1 # key not set

  # Present. An empty value is a real value, not an absence, so this returns 0
  # with empty output rather than inviting the caller to generate a replacement.
  raw=$(kl_kubectl get secret "$secret" -n "$ns" \
    -o "go-template={{index .data \"$key\"}}" 2>/dev/null) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || return 2
  [ -n "$raw" ] || return 0
  printf '%s' "$raw" | base64 -d 2>/dev/null || return 2
}

# Reuse before generating. Regenerating on every run rotates a password out from
# under a container that keeps the one it booted with — Redis then answers
# WRONGPASS and the app crash-loops — and rotates signing keys away from an
# already-running dev server, whose calls start failing closed.
kl_keep_or_generate() { # <namespace> <secret> <key> <generator...>
  local ns=$1 secret=$2 key=$3 existing rc
  shift 3
  existing=$(kl_secret_value "$ns" "$secret" "$key") && rc=0 || rc=$?
  case "$rc" in
    0)
      # Present, possibly empty. An empty stored value is still a decision
      # someone made; replacing it would rotate what a running pod is using.
      printf '%s' "$existing"
      return 0
      ;;
    1) "$@" ;; # genuinely absent: generate
    *) kl_die "cannot read $key from secret/$secret in $ns — refusing to generate a
       replacement, which would rotate the credential out from under a running pod" ;;
  esac
}

# --- drift -----------------------------------------------------------------
# Compare what the manifests say against what the cluster is running. This is
# the "observe the machine, not the config file" rule made executable, and a
# duplicated env var is the case that most needs it, because the two ways one
# can reach the cluster fail in OPPOSITE directions (both verified with
# client-side kustomize + kubectl apply, 2026-09-02):
#
#   In a kustomize patch: the strategic merge collapses the duplicate to a
#   single entry and keeps the FIRST. The later value is gone before kubectl
#   ever sees it, so nothing warns. Reading the file cannot tell you.
#
#   In a plain manifest applied client-side: BOTH entries survive into the live
#   spec. `kubectl apply` warns ("hides previous definition of ..."), and at
#   runtime the kubelet builds the environment in order, so the LAST wins.
#
# Neither is a guaranteed API contract — duplicate keys in a merge-keyed list are
# malformed input, and server-side apply rejects them outright rather than
# picking a winner. So the point is not to memorise which one wins: it is that
# the manifest cannot tell you, and only the live object can.
# Live env entries for one variable, in one container, of one workload.
#
# Reads JSON and parses it, rather than composing a JSONPath from the container
# and variable names: those come from a manifest, and interpolating them would
# reintroduce exactly the injection fixed in kl_cluster_field. It also means a
# multiline value stays ONE entry — a jsonpath emitting raw values made a single
# value containing newlines look like several live entries.
#
# Prints one line per entry: "value<TAB>source", source being "value",
# "secret:<name>/<key>", "configmap:<name>/<key>", "fieldRef" or "other".
#
# Exit codes matter here, because "the variable is not set" and "I could not
# find out" are different answers and only one of them is a finding:
#   0  the read succeeded; any lines printed are the live entries
#   2  the read failed (RBAC, API down, no JSON parser) — nothing was learned
# Returning 0 for both let a denied read print "not present on deploy/x", which
# is a confident negative about something never observed.
kl_env_of() { # <namespace> <workload> <containerKind> <container> <var>
  local json rc
  json=$(kl_kubectl get deploy -n "$1" -o json -- "$2" 2>/dev/null) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || return 2
  [ -n "$json" ] || return 2
  # jq OR python3, matching what kl_json_get accepts and what the README
  # advertises. Requiring python3 here meant a jq-only machine got a drift report
  # that said "not present" about every variable in the file.
  if command -v python3 >/dev/null 2>&1; then
    kl_env_of_python "$3" "$4" "$5" <<EOF || return 2
$json
EOF
  elif command -v jq >/dev/null 2>&1; then
    kl_env_of_jq "$3" "$4" "$5" <<EOF || return 2
$json
EOF
  else
    return 2
  fi
  return 0
}

# The value and the source are TAB-separated, so a TAB inside a value would split
# the record and make the reader show a truncated value beside a bogus source.
# Escaped alongside the newline that was already handled.
kl_env_of_jq() { # <containerKind> <container> <var>  (JSON on stdin)
  jq -r --arg kind "$1" --arg cname "$2" --arg var "$3" '
    def src: if has("value") then "value"
             else (.valueFrom // {}) as $f
               | if $f.secretKeyRef then "secret:\($f.secretKeyRef.name)/\($f.secretKeyRef.key)"
                 elif $f.configMapKeyRef then "configmap:\($f.configMapKeyRef.name)/\($f.configMapKeyRef.key)"
                 elif $f.fieldRef then "fieldRef"
                 else "other" end
             end;
    (.spec.template.spec[$kind] // [])[]
    | select(.name == $cname)
    | (.env // [])[]
    | select(.name == $var)
    | ((.value // "") | gsub("\n"; "\\n") | gsub("\t"; "\\t")) + "\t" + src
  '
}

kl_env_of_python() { # <containerKind> <container> <var>  (JSON on stdin)
  KL_C_KIND=$1 KL_C_NAME=$2 KL_VAR=$3 python3 -c '
import json, os, sys
d = json.load(sys.stdin)
spec = d.get("spec", {}).get("template", {}).get("spec", {})
for c in spec.get(os.environ["KL_C_KIND"], []) or []:
    if c.get("name") != os.environ["KL_C_NAME"]:
        continue
    for e in c.get("env", []) or []:
        if e.get("name") != os.environ["KL_VAR"]:
            continue
        if "value" in e:
            v, src = e["value"], "value"
        else:
            f = e.get("valueFrom", {}) or {}
            if "secretKeyRef" in f:
                r = f["secretKeyRef"]; v, src = "", "secret:%s/%s" % (r.get("name"), r.get("key"))
            elif "configMapKeyRef" in f:
                r = f["configMapKeyRef"]; v, src = "", "configmap:%s/%s" % (r.get("name"), r.get("key"))
            elif "fieldRef" in f:
                v, src = "", "fieldRef"
            else:
                v, src = "", "other"
        print("%s\t%s" % (v.replace("\n", "\\n").replace("\t", "\\t"), src))
'
}

# Report env names a manifest declares more than once WITHIN one container's env
# list. Scoping matters: counting `- name:` across a whole file also counts
# container names, port names, and volume names, and reports two Deployments
# that each declare APP_ENV once as a duplicate. Emits "<doc>/<container> <NAME> <count>".
kl_duplicate_env_vars() { # <manifest-file>
  [ -f "$1" ] || return 0
  awk '
    function flush() {
      for (k in seen)
        if (seen[k] > 1)
          printf "DUP %s %s %s %s %d\n", (workload == "" ? "?" : workload), ckind, \
            (container == "" ? "?" : container), k, seen[k]
      delete seen
    }
    # Turn a raw YAML scalar into the value it denotes. A trailing comment is NOT
    # part of the name: `name: demo-api # the app` yielded the workload
    # "demo-api # the app", which then went to kubectl as an object name, failed,
    # and made klocal status report every variable as absent from the cluster.
    # In YAML a # only opens a comment when preceded by whitespace, and never
    # inside a quoted scalar — so quoted values are cut at their closing quote
    # instead, and an unquoted `a#b` stays intact.
    function scrub(v,   q) {
      sub(/^[[:space:]]+/, "", v)
      q = substr(v, 1, 1)
      if (q == "\"" || q == "'"'"'") {
        v = substr(v, 2)
        sub(q ".*$", "", v)
        return v
      }
      sub(/[[:space:]]+#.*$/, "", v)
      sub(/[[:space:]]+$/, "", v)
      return v
    }
    function unreadable(why) {
      if (!warned[why]) { printf "UNREADABLE %s %s\n", FILENAME, why; warned[why] = 1 }
    }
    # A new YAML document resets everything. `--- # a comment` and `---   ` are
    # both ordinary separators; anchoring at end-of-line missed them and merged
    # the documents, so a duplicate was attributed to the previous object.
    /^---([[:space:]].*)?$/ { flush(); doc++; workload=""; container=""; ckind="containers"; inenv=0; next }
    # The workload this document defines, so a duplicate is looked up against the
    # right object: previously every finding was queried against the app
    # Deployment, so a duplicate in the Postgres manifest read as "not set".
    /^  name:[[:space:]]*/ && workload == "" {
      w = $0; sub(/^  name:[[:space:]]*/, "", w)
      workload = scrub(w); next
    }
    /^[[:space:]]*initContainers:[[:space:]]*(#.*)?$/ { flush(); ckind="initContainers"; container=""; inenv=0; next }
    /^[[:space:]]*containers:[[:space:]]*(#.*)?$/ { flush(); ckind="containers"; container=""; inenv=0; next }
    # Shapes this line-oriented scanner cannot read. Reporting them is the point:
    # silently skipping one would be a false all-clear on the very file the user
    # asked about.
    /^[[:space:]]*env:[[:space:]]*[\[&*]/ { unreadable("flow-or-anchor-env"); next }
    /^[[:space:]]*<<:[[:space:]]*\*/ { unreadable("merge-key-alias"); next }
    # Only a LIST ENTRY ("- name:") is significant. A bare "name:" is a field of
    # some other object — the secret in a valueFrom.secretKeyRef, the target of an
    # envFrom.secretRef — and counting those reported "demo-api-secrets 2" for the
    # entirely normal case of two variables sourced from the same Secret, and let
    # an envFrom target be mistaken for the container name.
    match($0, /^[[:space:]]*- name:[[:space:]]*/) {
      indent = index($0, "name:") - 1
      val = $0; sub(/^[[:space:]]*(- )?name:[[:space:]]*/, "", val)
      val = scrub(val)
      # Deeper than the env: key means this is an entry in that env list.
      if (inenv && indent > envindent) { seen[val]++; next }
      # Otherwise it is a container name — and if we were inside an env list, a
      # `- name:` at or left of the env indent is how that list ends. Missing
      # this is what let two containers sharing a variable look like a duplicate.
      inenv = 0
      flush()
      container = val
      scope = "doc" doc "/" container
      next
    }
    # An env entry whose FIRST key is not `name:` — `- value: "1"` with `name:`
    # on the next line is equally valid YAML. This scanner is line-oriented and
    # cannot pair those up, so it says so. Staying quiet printed "no duplicate env
    # declarations", which is a false all-clear on the one file the user asked
    # about — the exact failure the UNREADABLE branch exists to prevent.
    inenv && /^[[:space:]]*- / {
      here = match($0, /[^[:space:]]/) - 1
      if (here > envindent) { unreadable("env-entry-not-starting-with-name"); next }
    }
    /^[[:space:]]*env:[[:space:]]*(#.*)?$/ { inenv=1; envindent = index($0, "env:") - 1; next }
    # Any key at or left of the env: indentation ends the env list.
    inenv && /^[[:space:]]*[a-zA-Z_]+:/ {
      here = match($0, /[^[:space:]]/) - 1
      if (here <= envindent) inenv = 0
    }
    END { flush() }
  ' "$1" | sort
}

# Every manifest under the directory, including .yml and nested paths — a
# top-level *.yaml glob silently skips both.
kl_manifest_files() { # <dir>
  [ -d "$1" ] || return 0
  find "$1" -type f \( -name '*.yaml' -o -name '*.yml' \) | sort
}

# The hostnames the cluster is really serving, straight from the Ingress objects.
# Never guess this from a naming convention: the whole point of the drift check
# is that the manifest is a hypothesis and the cluster is the answer.
kl_ingress_hosts() { # <namespace>
  kl_kubectl get ingress -n "$1" \
    -o "jsonpath={range .items[*].spec.rules[*]}{.host}{'\n'}{end}" 2>/dev/null |
    grep -v '^$' | sort -u || true
}
