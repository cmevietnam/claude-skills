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

One stale context is the whole difference between a local bring-up and a
production deploy, and `kubectl` will not ask. `klocal` checks two things, and
both must hold:

1. **The context name** is `rancher-desktop`, `docker-desktop`, `minikube`,
   `colima`, `kind-*` or `k3d-*` — a whitelist of exact names, not a heuristic,
   because matching "contains local" would accept `localstack-prod`.
2. **The API server address** is loopback or RFC1918. The name is chosen by
   whoever created the cluster, so a remote cluster can be called `kind-prod`;
   the address is the part naming cannot fake.

No context at all is refused like a remote one. Every subcommand that reaches the
cluster is guarded — `logs` and `psql` included, since they read and write
through a pod — and the verified context is pinned with `--context` on every
call, so a kubeconfig switch during a long build cannot redirect what follows.

Values from `project.json` that become kubectl arguments are validated, not just
quoted: quoting stops word-splitting but not option interpretation, and a
namespace of `--all` would otherwise turn `klocal down --yes` into
`kubectl delete namespace --all`.

To add a legitimate local context, put its exact name in
`kl_context_name_is_local` (`scripts/lib/cluster.sh`) and add a test case.

This stops the ordinary mistake. It is not a sandbox — it guards `klocal`, not
the `kubectl` you type yourself.

## Commands

| Command                      | Does                                                                     |
| ---------------------------- | ------------------------------------------------------------------------ |
| `klocal up [--no-build]`     | Build, apply the overlay, wait for rollout, print next steps             |
| `klocal down [--yes]`        | Delete the namespace and everything in it                                |
| `klocal status`              | Pods, services, ingress, ephemeral storage, manifest-vs-live drift       |
| `klocal logs [workload]`     | Follow logs (default: the app workload)                                  |
| `klocal rebuild`             | Rebuild the image and restart the rollout                                |
| `klocal psql [--app] [args]` | `psql` in the database pod; `--app` connects as the least-privilege role |
| `klocal scaffold [dir]`      | Write manifests + config into a project                                  |

## Configuration

`.k8s-local/project.json`, committed, found by walking up from `$PWD`. Every key
below is optional except `project`.

| Key                                  | Default                 | Meaning                                                  |
| ------------------------------------ | ----------------------- | -------------------------------------------------------- |
| `project`                            | —                       | Required. Names the stack                                |
| `namespace`                          | `<project>-local`       | Everything lives here; deleting it is the uninstall      |
| `rootDomain`                         | `lvh.me`                | Wildcard-DNS domain for hostnames                        |
| `ingressClass`                       | `traefik`               | Warned about, not enforced, when absent                  |
| `image.name`                         | `<project>-api:local`   | Tag built into the cluster's store                       |
| `image.context`                      | `.`                     | Build context, relative to the project root              |
| `manifests`                          | `deploy/k8s-local`      | Applied with `-k` if it holds a `kustomization.yaml`     |
| `workloads.app` / `.db` / `.cache`   | `<project>-api` / — / — | Rollout order is db, cache, app                          |
| `secret.name` / `.envFile` / `.hook` | —                       | See below                                                |
| `database.name` / `.superuser`       | —                       | Database and owning role `klocal psql` connects to       |
| `database.appRole`                   | —                       | The least-privilege role `klocal psql --app` connects as |
| `tls.port` / `.certDir`              | —                       | Reported in the closing message                          |

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
bash plugins/k8s-local/scripts/test-klocal.sh              # 159 assertions
bash plugins/k8s-local/scripts/test-klocal.sh --self-check # + prove it can fail
```

No cluster, no network, no container engine: `kubectl`, `docker`, `nerdctl`,
`kind`, `k3d` and `minikube` are all stubbed on `PATH` — created before the first
test that could reach one, so a regression in the context guard cannot fall
through to a real engine — and `HOME` is redirected to a temp dir, so live state
is never touched.

The assertion discipline, because a suite that cannot fail is not evidence:

- `want` demands a specific string. An **empty expectation is itself a failure**,
  since every string contains the empty string and such a check can never go red.
- Empty output is always a hard failure, never agreement.
- `want_absent` also requires a marker proving execution reached the code under
  test; otherwise silence from an unrelated crash scores as a pass.
- `want_empty` requires a **positive control** — the same function producing
  output on a known input — so "no output" cannot pass when the function is
  missing or broken.
- `--self-check` breaks four assertions on purpose and exits non-zero unless all
  four go red.

## Read

- [`skills/k8s-local/SKILL.md`](skills/k8s-local/SKILL.md) — the rules, and the command surface
- [`references/bring-up.md`](skills/k8s-local/references/bring-up.md) — the procedure, and why it is ordered so
- [`references/engines.md`](skills/k8s-local/references/engines.md) — Rancher Desktop, kind, k3d, minikube
- [`references/troubleshooting.md`](skills/k8s-local/references/troubleshooting.md) — symptom, cause, fix
- [`references/example-cme.md`](skills/k8s-local/references/example-cme.md) — a real multi-tenant stack, worked end to end
