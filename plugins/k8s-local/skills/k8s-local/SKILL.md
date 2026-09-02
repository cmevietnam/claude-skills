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

**Never apply anything without checking the kubecontext first.** One stale
context is the whole difference between a local bring-up and a production
deploy, and `kubectl` will not ask. `klocal` refuses any context that is not
`rancher-desktop`, `docker-desktop`, `minikube`, `colima`, `kind-*` or `k3d-*`,
and refuses when there is no context at all.

The check is a name whitelist, not a heuristic — "contains the word local" would
happily accept a production cluster called `localstack-prod`. If a legitimate
local context is refused, add its exact name to `kl_context_is_local`; never
loosen the pattern.

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
- Declare an env var twice. The two ways it reaches the cluster fail in opposite
  directions: in a **kustomize patch** the strategic merge collapses it and keeps
  the **first**, silently, before `kubectl` ever sees it; in a **plain manifest**
  both survive, `kubectl apply` warns, and the kubelet gives the container the
  **last**. Guessing which value is live gets it wrong half the time — read the
  live object, or run `klocal status`, which reports both cases distinctly.
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
| `klocal psql`            | Running migrations or inspecting local data                            |
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
