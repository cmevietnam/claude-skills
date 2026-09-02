---
name: k8s-local
description: Run a project's whole stack on a local Kubernetes cluster with `klocal`, on Rancher Desktop, kind, k3d or minikube. Use when setting up local development for a project, when the app needs a database and a real hostname to run, when a locally built image will not start in the cluster, when a hostname routes nowhere, or when a local login fails over http.
---

# A project's stack on a local Kubernetes cluster

Docker Compose stops being enough once the app needs ingress hostnames,
subdomain routing, or the same manifests it runs in production. A local
Kubernetes cluster gives you that, and adds three traps that cost an afternoon
each: an image the kubelet refuses to see, a hostname that routes nowhere while
everything reports healthy, and a login that fails only over plain http.

`klocal` drives the stack; the project's shape lives in a committed
`.k8s-local/project.json`, so the same tool works in every repo.

## The rule that matters most

**Never touch a cluster without checking the kubecontext first.** One stale
context is the whole difference between a local bring-up and a production
deploy, and `kubectl` will not ask. Two independent checks, because neither is
enough alone:

1. **The name** must be `rancher-desktop`, `docker-desktop`, `minikube`,
   `colima`, `kind-*` or `k3d-*`. A whitelist, not a heuristic — "contains the
   word local" would accept a production cluster called `localstack-prod`.
2. **The API server address** must be loopback or RFC1918. Names are chosen by
   whoever created the cluster, so a remote cluster can be called `kind-prod`;
   the address is the part that naming cannot fake.

No context at all is refused the same way a remote one is. Every command that
reaches the cluster is guarded — including `logs` and `psql`, which read and
write through a pod — and the verified context is pinned with `--context` on
every call, so switching the kubeconfig mid-build cannot redirect the rest.

If a legitimate local context is refused, add its exact name to
`kl_context_name_is_local` and a case to the test suite; never loosen the pattern.

## Do not

- Push a local image to a registry. Build it straight into the cluster's image
  store, and set `imagePullPolicy: IfNotPresent` with `imagePullSecrets: null`.
  Miss either and the kubelet ignores the local tag and tries to pull it.
- Pick the build engine by which binary exists. Rancher Desktop ships `nerdctl`
  even when the engine is moby, where it cannot reach the k3s containerd socket.
  Probe the socket: `nerdctl --namespace k8s.io info`, then `docker info`.
- Let the app connect to Postgres as the container's superuser. It bypasses
  every `FORCE ROW LEVEL SECURITY` policy, so tenant isolation is silently off
  while all tests still pass. Create a `NOSUPERUSER NOBYPASSRLS` role, and assert
  it before declaring the stack up.
- Regenerate a password or signing key on a re-run. Redis keeps the
  `--requirepass` it booted with, so the app crash-loops on `WRONGPASS`; a
  rotated signing key breaks an already-running dev server. Read the existing
  value first, generate only when it is absent.
- Declare an env var twice. It is malformed input to a merge-keyed list, and
  what happens next depends on the path: a **kustomize patch** collapses it and
  keeps the **first**, silently, before `kubectl` sees anything; a **plain
  manifest** applied client-side keeps **both**, warns, and the kubelet uses the
  **last**; server-side apply rejects it outright. Do not memorise a winner —
  the point is that the manifest cannot tell you and only the live object can.
  `klocal status` reports the duplicate next to the value actually in effect.
- Give the local datastores a volume. They are meant to be throwaway; say so in
  the project's docs rather than making local state precious.

## Commands

| Command                  | Use it when                                                            |
| ------------------------ | ---------------------------------------------------------------------- |
| `klocal scaffold [dir]`  | Starting local Kubernetes in a project for the first time              |
| `klocal up`              | Bringing the stack up, or after pulling changes to the manifests       |
| `klocal status`          | Something is wrong, or before trusting any claim about what is running |
| `klocal rebuild`         | Code changed and the image tag did not                                 |
| `klocal logs [workload]` | The app is crash-looping or answering wrong                            |
| `klocal psql [--app]`    | Migrations as the owner, or `--app` to check that RLS actually bites   |
| `klocal down`            | Finished, or the local database needs a clean slate                    |

## Common workflows

**Set a project up.** `scaffold` writes the manifests and config; every file
carries `PROJECT` placeholders and comments explaining what to decide.

```bash
klocal scaffold                       # from the project root
$EDITOR .k8s-local/project.json       # then the PROJECT placeholders in deploy/
klocal up
```

**Get secrets in without writing them to disk.** `klocal` never handles secret
values. Point `secret.hook` at a command that creates the Secret, and it runs
from the project root with `KL_NAMESPACE`, `KL_SECRET` and `KL_SECRET_ENV_FILE`
exported. Piping a vault straight into `kubectl` keeps values out of both the
filesystem and the transcript — see the `onepassword` skill for `opgate`.

```json
"secret": { "hook": "opgate run -f api/.env.op -- ./deploy/scripts/local-secret.sh" }
```

**Check what is actually running.** Never report the manifest's intent as fact.
`klocal status` prints the live pods, services and ingress, whether the
datastores are ephemeral, and any env var a manifest declares twice alongside the
value that actually won.

## Before you say it works

A green rollout means the pods started, not that the stack works. Confirm the
hostname answers, and confirm the answer came from the app rather than the
ingress controller — a `404` from the app and a `404` from Traefik look
identical until you read the body.

## Further reading

- `references/bring-up.md` — the procedure step by step, and why it is ordered so
- `references/engines.md` — Rancher Desktop, kind, k3d, minikube: what differs
- `references/troubleshooting.md` — symptom, cause, fix
- `references/example-cme.md` — a real multi-tenant stack, worked end to end
