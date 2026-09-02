# Local cluster engines: what actually differs

Written against Rancher Desktop, which is what these instructions were developed
and verified on. The other three work; they differ in two places that matter and
a few that do not.

## The two things that differ

**How an image reaches the node.** Only Rancher Desktop and Docker Desktop share
a daemon with the cluster, so a plain `docker build` is enough. kind, k3d and
minikube run the cluster inside their own container or VM with a separate image
store, and a build on the host is invisible to it — the pod sits in
`ErrImageNeverPull` on an image you can see in `docker images`.

**Which ingress controller is present.** Only Rancher Desktop ships one. On the
others an `Ingress` naming a class that does not exist applies cleanly, the
rollout goes green, and every hostname routes nowhere.

|                     | Image into the cluster                                                                 | Ingress out of the box                              | Context name      |
| ------------------- | -------------------------------------------------------------------------------------- | --------------------------------------------------- | ----------------- |
| **Rancher Desktop** | nothing — shares the daemon (moby), or `nerdctl --namespace k8s.io build` (containerd) | Traefik, on `localhost:80`                          | `rancher-desktop` |
| **Docker Desktop**  | nothing — shares the daemon                                                            | none                                                | `docker-desktop`  |
| **kind**            | `kind load docker-image <img>`                                                         | none                                                | `kind-<cluster>`  |
| **k3d**             | `k3d image import <img> -c <cluster>`                                                  | Traefik (k3s), unless `--k3s-arg --disable=traefik` | `k3d-<cluster>`   |
| **minikube**        | `minikube image load <img>`, or build inside via `eval $(minikube docker-env)`         | none until `minikube addons enable ingress` (nginx) | `minikube`        |

## Rancher Desktop

Two engines, selectable in preferences, and the choice changes how you build:

- **moby** — `docker build` is enough; k3s reads that daemon. `nerdctl` is still
  installed and still on `PATH`, and it **cannot** reach the containerd socket
  here. This is why the engine probe tests `nerdctl --namespace k8s.io info`
  rather than `command -v nerdctl`.
- **containerd** — `nerdctl --namespace k8s.io build`. The namespace is
  mandatory: an image in containerd's `default` namespace is invisible to k3s.

Traefik listens on `localhost:80` and `:443`. The `LoadBalancer` Service also
gets the VM's own IP, so `kubectl get svc -n kube-system traefik` shows an
external IP that is not `127.0.0.1` — both work, and `127.0.0.1` is the one to
use, since that is where a wildcard DNS name resolves.

Storage class is `local-path` (Rancher's provisioner), the default. Relevant only
if you decide to give a datastore a volume, which for a local stack you generally
should not.

## kind

Load after every build — this is the step people forget, and the symptom is a
pod running the _previous_ image with no indication anything is stale:

```bash
docker build -t app:local . && kind load docker-image app:local
```

For ingress, either install nginx and set `ingressClassName: nginx`, or skip
ingress and use `kubectl port-forward`. The cluster also needs
`extraPortMappings` in its config for host ports to reach it, which must be set
at cluster-creation time and cannot be added afterwards.

## k3d

`k3d image import app:local -c mycluster` after each build. k3d runs k3s, so
Traefik is present unless it was explicitly disabled — the same
`ingressClassName: traefik` works. Host ports need `-p "80:80@loadbalancer"` at
cluster creation.

## minikube

Either load after each build, or build directly into the cluster's daemon:

```bash
eval $(minikube docker-env)   # this shell's docker now IS the cluster's
docker build -t app:local .   # no load step needed
```

Ingress is `minikube addons enable ingress`, which installs **nginx**, not
Traefik — so `ingressClassName` must change. Reaching it usually needs
`minikube tunnel` running in another terminal.

## Docker Desktop

Shares the daemon, so builds need no extra step, but it ships no ingress
controller at all. Install one, or use `kubectl port-forward`.

## Adding an engine to the guard

`klocal` refuses any context not on its whitelist. To add one, put its exact
name in `kl_context_is_local` in `scripts/lib/cluster.sh` and add a case to the
test suite. Do not relax the pattern into a substring match: `*local*` would
accept a production cluster named `localstack-prod`, which is precisely the
accident the guard exists to prevent.

## Hostnames, on every engine

`lvh.me` resolves every name — including any subdomain — to `127.0.0.1`, so
multi-tenant subdomain routing works with no `/etc/hosts` entry and no DNS setup.
`nip.io` and `sslip.io` do the same and additionally encode an arbitrary IP
(`app.192-168-64-5.nip.io`), which is useful when the cluster is not on
loopback.

`*.localhost` is reserved and resolves locally on most systems, with one
advantage: browsers treat it as a secure context over plain http, so `__Host-`
cookies survive without TLS. It is not universally resolvable outside the
browser, though — some resolvers and HTTP clients do not honour it.

All of these depend on public DNS (or the resolver's own handling) and stop
working offline. If that matters, add the specific hostnames to `/etc/hosts`.
