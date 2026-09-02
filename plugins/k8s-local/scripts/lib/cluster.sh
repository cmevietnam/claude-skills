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
  case "$1" in
    rancher-desktop | docker-desktop | minikube | colima) return 0 ;;
    kind-* | k3d-*) return 0 ;;
    *) return 1 ;;
  esac
}

# Host part of a cluster's API server URL. Handles the bracketed IPv6 form.
kl_context_server_host() { # <context>
  local ctx=$1 cluster server host
  cluster=$(kubectl config view -o \
    "jsonpath={.contexts[?(@.name=='$ctx')].context.cluster}" 2>/dev/null || true)
  [ -n "$cluster" ] || return 1
  server=$(kubectl config view -o \
    "jsonpath={.clusters[?(@.name=='$cluster')].cluster.server}" 2>/dev/null || true)
  [ -n "$server" ] || return 1
  host=${server#*://}
  host=${host%%/*}
  case "$host" in
    "["*) host=${host#[}; host=${host%%]*} ;; # [::1]:6443
    *) host=${host%%:*} ;;
  esac
  printf '%s\n' "$host"
}

# Loopback, link-local, or RFC1918. Deliberately conservative: an address this
# does not recognise is treated as remote.
kl_host_is_local() { # <host>
  case "$1" in
    localhost | localhost.localdomain | ::1 | 0.0.0.0) return 0 ;;
    127.*) return 0 ;;
    10.*) return 0 ;;
    192.168.*) return 0 ;;
    172.1[6-9].* | 172.2[0-9].* | 172.3[01].*) return 0 ;;
    169.254.*) return 0 ;;
    fe80:* | fd*: | fc*:) return 0 ;;
    *.local | host.docker.internal | kubernetes.docker.internal | host.lima.internal) return 0 ;;
    *) return 1 ;;
  esac
}

kl_current_context() {
  kubectl config current-context 2>/dev/null || true
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

  if ! kl_context_name_is_local "$ctx"; then
    printf 'klocal: REFUSING: context '\''%s'\'' does not look local.\n' "$ctx" >&2
    printf '        Local contexts: rancher-desktop, docker-desktop, minikube, colima, kind-*, k3d-*\n' >&2
    printf '        Switch with: kubectl config use-context rancher-desktop\n' >&2
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

# Builds into the local engine, then imports into the cluster when the engine and
# the cluster do not share a store.
kl_build_image() { # <image> <context-dir>
  local image=$1 context=$2 engine load
  engine=$(kl_detect_engine)
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
    $load
  fi
}

# --- secrets ---------------------------------------------------------------
# Distinguishes three outcomes that must not be conflated:
#   0 + value  the key is present
#   1          the Secret or key does not exist (a normal first run)
#   2          the read itself failed (API down, RBAC, broken base64)
# Treating case 2 as case 1 makes the caller generate a fresh value and overwrite
# a credential a running container still holds — the exact outage kl_keep_or_generate
# exists to prevent.
kl_secret_value() { # <namespace> <secret> <key>
  local raw rc
  raw=$(kl_kubectl get secret "$2" -n "$1" -o "jsonpath={.data.$3}" 2>/dev/null)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    # Absent Secret and failed API call both exit non-zero, so ask again whether
    # the Secret exists at all; only then is "absent" the right conclusion.
    if kl_kubectl get secret "$2" -n "$1" >/dev/null 2>&1; then
      return 2 # the Secret is there, so the read failed for another reason
    fi
    kl_kubectl get namespace "$1" >/dev/null 2>&1 || return 2
    return 1 # namespace reachable, Secret genuinely absent
  fi
  [ -n "$raw" ] || return 1 # Secret exists, key not set
  printf '%s' "$raw" | base64 -d 2>/dev/null || return 2
}

# Reuse before generating. Regenerating on every run rotates a password out from
# under a container that keeps the one it booted with — Redis then answers
# WRONGPASS and the app crash-loops — and rotates signing keys away from an
# already-running dev server, whose calls start failing closed.
kl_keep_or_generate() { # <namespace> <secret> <key> <generator...>
  local ns=$1 secret=$2 key=$3 existing rc
  shift 3
  existing=$(kl_secret_value "$ns" "$secret" "$key")
  rc=$?
  case "$rc" in
    0)
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
kl_env_of() { # <namespace> <deployment> <container> <var> -> live value(s)
  kl_kubectl get deploy "$2" -n "$1" -o "jsonpath={range .spec.template.spec.containers[?(@.name=='$3')].env[?(@.name=='$4')]}{.value}{'\t'}{.valueFrom.secretKeyRef.name}{'\n'}{end}" 2>/dev/null || true
}

kl_containers_of() { # <namespace> <deployment>
  kl_kubectl get deploy "$2" -n "$1" \
    -o "jsonpath={range .spec.template.spec.containers[*]}{.name}{'\n'}{end}" 2>/dev/null || true
}

# Report env names a manifest declares more than once WITHIN one container's env
# list. Scoping matters: counting `- name:` across a whole file also counts
# container names, port names, and volume names, and reports two Deployments
# that each declare APP_ENV once as a duplicate. Emits "<doc>/<container> <NAME> <count>".
kl_duplicate_env_vars() { # <manifest-file>
  [ -f "$1" ] || return 0
  awk '
    function flush() {
      for (k in seen) if (seen[k] > 1) printf "%s %s %d\n", scope, k, seen[k]
      delete seen
    }
    # A new YAML document resets everything.
    /^---[[:space:]]*$/ { flush(); doc++; container=""; inenv=0; next }
    # Track indentation of the env: key so we can tell when its list ends.
    match($0, /^[[:space:]]*(- )?name:[[:space:]]*/) {
      indent = index($0, "name:") - 1
      val = $0; sub(/^[[:space:]]*(- )?name:[[:space:]]*/, "", val)
      gsub(/^["'"'"']|["'"'"']$/, "", val)
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
    /^[[:space:]]*env:[[:space:]]*$/ { inenv=1; envindent = index($0, "env:") - 1; next }
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
