# k8s-local

Run a project's whole stack on a local Kubernetes cluster. Builds the image
straight into the cluster's image store, refuses to apply anything against a
context that is not local, and keeps the datastores throwaway.

Docker Compose stops being enough once the app needs ingress hostnames,
subdomain routing, or the same manifests it runs in production. This plugin
carries the parts of that move which are not obvious: an image the kubelet
refuses to see, a hostname that routes nowhere while everything reports healthy,
and a login that fails only over plain http.

## Install

```bash
claude plugin marketplace add hieuvo/claude-skills
claude plugin install k8s-local@hieuvo-skills
```

Then, in a project:

```bash
klocal scaffold                  # writes manifests + .k8s-local/project.json
$EDITOR .k8s-local/project.json  # then the PROJECT placeholders in deploy/
klocal up
```

`klocal` needs `kubectl`, a container engine, and `jq` or `python3`. Nothing from
Claude Code — symlink `bin/klocal` onto `PATH` and use it as an ordinary tool.

## The guard

`klocal` refuses any kubecontext that is not `rancher-desktop`,
`docker-desktop`, `minikube`, `colima`, `kind-*` or `k3d-*`, and refuses when
there is no context at all. One stale context is the whole difference between a
local bring-up and a production deploy, and `kubectl` will not ask.

It is a whitelist of exact names, not a heuristic: matching "contains local"
would accept a production cluster called `localstack-prod`. To add a legitimate
local context, put its exact name in `kl_context_is_local`
(`scripts/lib/cluster.sh`) and add a test case.

This stops the ordinary mistake. It is not a sandbox — it guards `klocal`, not
the `kubectl` you type yourself.

## Commands

| Command                  | Does                                                               |
| ------------------------ | ------------------------------------------------------------------ |
| `klocal up [--no-build]` | Build, apply the overlay, wait for rollout, print next steps       |
| `klocal down [--yes]`    | Delete the namespace and everything in it                          |
| `klocal status`          | Pods, services, ingress, ephemeral storage, manifest-vs-live drift |
| `klocal logs [workload]` | Follow logs (default: the app workload)                            |
| `klocal rebuild`         | Rebuild the image and restart the rollout                          |
| `klocal psql [args]`     | `psql` inside the database pod                                     |
| `klocal scaffold [dir]`  | Write manifests + config into a project                            |

## Configuration

`.k8s-local/project.json`, committed, found by walking up from `$PWD`. Every key
below is optional except `project`.

| Key                                         | Default                 | Meaning                                              |
| ------------------------------------------- | ----------------------- | ---------------------------------------------------- |
| `project`                                   | —                       | Required. Names the stack                            |
| `namespace`                                 | `<project>-local`       | Everything lives here; deleting it is the uninstall  |
| `rootDomain`                                | `lvh.me`                | Wildcard-DNS domain for hostnames                    |
| `ingressClass`                              | `traefik`               | Warned about, not enforced, when absent              |
| `image.name`                                | `<project>-api:local`   | Tag built into the cluster's store                   |
| `image.context`                             | `.`                     | Build context, relative to the project root          |
| `manifests`                                 | `deploy/k8s-local`      | Applied with `-k` if it holds a `kustomization.yaml` |
| `workloads.app` / `.db` / `.cache`          | `<project>-api` / — / — | Rollout order is db, cache, app                      |
| `secret.name` / `.envFile` / `.hook`        | —                       | See below                                            |
| `database.name` / `.superuser` / `.appRole` | —                       | Used by `klocal psql`                                |
| `tls.port` / `.certDir`                     | —                       | Reported in the closing message                      |

### Secrets

`klocal` never handles secret values. If `secret.hook` is set, it runs from the
project root with `KL_NAMESPACE`, `KL_SECRET` and `KL_SECRET_ENV_FILE` exported,
and that command is responsible for creating the Secret. Piping a vault straight
into `kubectl` keeps values out of both the filesystem and the model transcript:

```json
"secret": {
  "name": "myapp-api-secrets",
  "envFile": "api/.env.op",
  "hook": "opgate run -f api/.env.op -- ./deploy/scripts/local-secret.sh"
}
```

See the [`onepassword`](../onepassword) plugin for `opgate`.

## Drift

`klocal status` compares the manifests against the live objects rather than
trusting either alone. It reports any env var a manifest declares twice, next to
the value actually in effect — and the two ways a duplicate reaches the cluster
resolve in opposite directions:

- In a **kustomize patch**, the strategic merge collapses it and keeps the
  **first**. The other value is gone before `kubectl` sees it, so nothing warns.
- In a **plain manifest**, both entries survive, `kubectl apply` warns, and the
  kubelet gives the container the **last**.

Guessing from the file therefore gets it wrong half the time. A live instance of
exactly this defect was found this way in a real repo.

## Tests

```bash
bash plugins/k8s-local/scripts/test-klocal.sh              # 55 assertions
bash plugins/k8s-local/scripts/test-klocal.sh --self-check # + prove it can fail
```

No cluster, no network, no container engine: `kubectl`, `docker` and `nerdctl`
are stubbed on `PATH` and `HOME` is redirected to a temp dir, so live state is
never touched.

Every assertion demands a specific string that only appears when the code under
test actually ran, and empty output is a hard failure — an assertion phrased as
an absence cannot tell a passing run from a run that never happened. The two
absence checks additionally require an execution marker. `--self-check`
deliberately breaks three assertions and requires all three to go red; if fewer
fail, the suite exits non-zero instead of reporting green, because a harness that
cannot fail is not evidence.

## Read

- [`skills/k8s-local/SKILL.md`](skills/k8s-local/SKILL.md) — the rules, and the command surface
- [`references/bring-up.md`](skills/k8s-local/references/bring-up.md) — the procedure, and why it is ordered so
- [`references/engines.md`](skills/k8s-local/references/engines.md) — Rancher Desktop, kind, k3d, minikube
- [`references/troubleshooting.md`](skills/k8s-local/references/troubleshooting.md) — symptom, cause, fix
- [`references/example-cme.md`](skills/k8s-local/references/example-cme.md) — a real multi-tenant stack, worked end to end
