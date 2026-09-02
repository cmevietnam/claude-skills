# Cluster-facing helpers for klocal: context guard, image build, secret reuse,
# and manifest-vs-live drift.
#
# Sourced, never executed. Each function is written to be callable on its own so
# the test suite can drive it against a stubbed kubectl.

# --- context guard ---------------------------------------------------------
# The most important function in this plugin. Without it, one stale kubecontext
# turns `klocal up` into a production deploy.
#
# The list is names a local cluster actually uses. `kind-*` and `k3d-*` are
# prefixes because those tools name the context after the cluster. Deliberately
# NOT matched: anything containing the substring "local" (a production cluster
# may be called "localstack-prod"), and anything from a kubeconfig the user
# merged in from a cloud provider.
kl_context_is_local() { # <context>  -> 0 local, 1 not
  case "$1" in
    rancher-desktop | docker-desktop | minikube | colima) return 0 ;;
    kind-* | k3d-*) return 0 ;;
    *) return 1 ;;
  esac
}

kl_current_context() {
  kubectl config current-context 2>/dev/null || true
}

# Fails closed: no context at all is refused just like a remote one.
kl_require_local_context() {
  local ctx
  ctx=$(kl_current_context)
  [ -n "$ctx" ] || kl_die "no kubectl context — start your local cluster first"
  if ! kl_context_is_local "$ctx"; then
    printf 'klocal: REFUSING: context '\''%s'\'' does not look local.\n' "$ctx" >&2
    printf '        Local contexts: rancher-desktop, docker-desktop, minikube, colima, kind-*, k3d-*\n' >&2
    printf '        Switch with: kubectl config use-context rancher-desktop\n' >&2
    exit 1
  fi
  kubectl cluster-info >/dev/null 2>&1 || kl_die "cluster unreachable (context $ctx)"
  printf '%s\n' "$ctx"
}

# --- ingress ---------------------------------------------------------------
# A missing IngressClass is a warning, never a failure: the stack still runs and
# port-forward still works. But it must be said out loud, because the manifests
# apply cleanly and the rollout goes green while every hostname routes nowhere,
# which is a miserable thing to debug from the symptom end.
kl_check_ingressclass() { # <class>
  if kubectl get ingressclass "$1" >/dev/null 2>&1; then
    kl_step "ingressclass: $1"
    return 0
  fi
  kl_warn "no IngressClass '$1' in this cluster."
  kl_step "Rancher Desktop ships traefik; Docker Desktop, kind and minikube do not."
  kl_step "The stack will still run, but no hostname will route. Use kubectl port-forward,"
  kl_step "or install one — see references/engines.md."
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

# Builds into the cluster's own image store. There is no registry and no push:
# with imagePullPolicy IfNotPresent the kubelet finds the tag locally.
kl_build_image() { # <image> <context-dir>
  local image=$1 context=$2 engine
  engine=$(kl_detect_engine)
  case "$engine" in
    nerdctl)
      # containerd engine: k3s reads the k8s.io namespace directly.
      kl_step "engine: nerdctl (containerd, namespace k8s.io)"
      nerdctl --namespace k8s.io build -t "$image" "$context"
      ;;
    docker)
      # moby engine: Rancher Desktop points k3s at this same daemon.
      kl_step "engine: docker (moby)"
      docker build -t "$image" "$context"
      ;;
    *)
      kl_die "no working container engine — start Rancher Desktop (or Docker) and retry"
      ;;
  esac
}

# --- secrets ---------------------------------------------------------------
# Read a value the Secret already holds. Empty output means "not there yet".
kl_secret_value() { # <namespace> <secret> <key>
  kubectl get secret "$2" -n "$1" -o "jsonpath={.data.$3}" 2>/dev/null |
    base64 -d 2>/dev/null || true
}

# Reuse before generating. Regenerating on every run rotates a password out from
# under a container that keeps the one it booted with — Redis then answers
# WRONGPASS and the app crash-loops — and rotates signing keys away from an
# already-running dev server, whose calls start failing closed.
kl_keep_or_generate() { # <namespace> <secret> <key> <generator...>
  local ns=$1 secret=$2 key=$3
  shift 3
  local existing
  existing=$(kl_secret_value "$ns" "$secret" "$key")
  if [ -n "$existing" ]; then
    printf '%s' "$existing"
    return 0
  fi
  "$@"
}

# --- drift -----------------------------------------------------------------
# Compare what the manifests say against what the cluster is running. This is
# the "observe the machine, not the config file" rule made executable, and a
# duplicated env var is the case that most needs it, because the two ways one
# can reach the cluster fail in OPPOSITE directions (both verified, 2026-09-02):
#
#   In a kustomize patch: the strategic merge collapses the duplicate to a
#   single entry and keeps the FIRST. The later value is gone before kubectl
#   ever sees it, so nothing warns — not kustomize, not kubectl, not the
#   rollout. Reading the file cannot tell you this happened.
#
#   In a plain manifest applied directly: BOTH entries survive into the live
#   spec. `kubectl apply` does warn ("hides previous definition of ..."), and at
#   runtime the kubelet builds the environment in order, so the LAST wins.
#
# First wins in one path, last in the other. Hence: always read the live object,
# and when it holds more than one, report the last as the effective value.
kl_env_of() { # <namespace> <deployment> <var>  -> live value(s), one per line
  kubectl get deploy "$2" -n "$1" \
    -o "jsonpath={range .spec.template.spec.containers[*].env[?(@.name=='$3')]}{.value}{'\n'}{end}" \
    2>/dev/null || true
}

# Report every env var a manifest declares more than once.
kl_duplicate_env_vars() { # <manifest-file> -> "NAME count" per offender
  [ -f "$1" ] || return 0
  awk '
    /^[[:space:]]*-[[:space:]]*name:[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*$/ {
      name = $NF
      seen[name]++
    }
    END { for (n in seen) if (seen[n] > 1) printf "%s %d\n", n, seen[n] }
  ' "$1" | sort
}

# The hostnames the cluster is really serving, straight from the Ingress objects.
# Never guess this from a naming convention: the whole point of the drift check
# is that the manifest is a hypothesis and the cluster is the answer.
kl_ingress_hosts() { # <namespace>
  kubectl get ingress -n "$1" \
    -o "jsonpath={range .items[*].spec.rules[*]}{.host}{'\n'}{end}" 2>/dev/null |
    grep -v '^$' | sort -u || true
}
