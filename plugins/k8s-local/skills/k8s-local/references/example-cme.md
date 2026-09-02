# Worked example: a multi-tenant stack (CME)

The setup this skill was extracted from. A Go API, a Next.js frontend, Postgres
and Redis, serving many tenants on their own subdomains, on Rancher Desktop.
Useful because every rule in `SKILL.md` traces to something that broke here.

Observed live on 2026-09-01, not read from the config files:

```
engine     Rancher Desktop, k3s v1.36.4+k3s1, arm64, runtime docker:// (moby)
ingress    Traefik LoadBalancer, localhost:80
namespace  cme-local
workloads  cme-api (cme-api:local) | cme-postgres (postgres:16-alpine) | cme-redis (redis:7.4-alpine)
storage    no PVC, no PV, no volumes — Postgres data is in the container layer
secret     cme-api-secrets, 18 keys
routing    api.lvh.me -> 127.0.0.1 -> Traefik -> cme-api
database   NodePort 30432 on 127.0.0.1
```

## Layout

```
deploy/k8s-local/
  kustomization.yaml          namespace, overlay, image rewrite, patch
  namespace.yaml
  postgres.yaml               throwaway, NodePort 30432
  ingress.yaml                api.lvh.me -> cme-api:80
  api-deployment-patch.yaml   local-only env
deploy/local/https-proxy.mjs  TLS front door on :8443
deploy/scripts/k8s-local-up.sh
```

The overlay inherits the production base (`../k8s`) and deliberately excludes two
things, with the reason written into `kustomization.yaml`:

- `cloudflared.yaml` — needs real tunnel credentials, and only exists to put the
  cluster on the internet.
- `network-policy.yaml` — its allow-rule admits traffic only from cloudflared
  pods, which this overlay does not run. Applying it locally would silently break
  `kubectl port-forward`.

That second one is the general lesson: **a NetworkPolicy whose allow-rules name
pods your local overlay does not run will apply cleanly and then drop traffic you
need.**

## The four problems this stack hit, in the order they were found

**1. The app connected as the Postgres superuser.** The image creates `cme` as
superuser, and the obvious `DATABASE_URL` uses it. Ten tables have
`FORCE ROW LEVEL SECURITY`; a superuser bypasses all of them, so every tenant
could read every other tenant — locally only, silently, with all tests green.

The fix was a `cme_app` role (`NOSUPERUSER NOBYPASSRLS`) plus a boot-time
assertion in the app itself, which refuses to start rather than run unsafe:

```
refusing to start: db role "cme" bypasses row-level security (superuser/BYPASSRLS)
but 10 forced-RLS table(s) exist — per-user tenant isolation would be SILENTLY DISABLED
```

Worth copying: the check lives in the application, so it protects every
environment, not just the one whose script remembered to look.

**2. Subdomains needed real hostnames.** Tenants are served at
`<slug>.<root-domain>`, which `localhost:3000` cannot express. `lvh.me` resolves
every name to `127.0.0.1`, so `acme.lvh.me` works with no `/etc/hosts` entry and
no wildcard DNS of their own.

Slug rules are enforced in the app and matter when picking test names: lowercase,
digits and hyphens only — no underscore — and `www`, `admin`, `tools` are
reserved.

**3. Plain http could never have worked.** The first version routed correctly,
passed CORS, and still could not log in. The API rejects any non-https `Origin`,
so the failure appears at authentication with everything upstream looking
perfect.

Hence `https-proxy.mjs`: TLS on `:8443`, routing `api.*` to Traefik and
everything else to the Next dev server, with WebSocket upgrades forwarded so hot
reload survives. TLS deliberately terminates at the proxy rather than the
Ingress, so one certificate covers both the API and the frontend.

**4. Re-running the bring-up broke the running stack.** Regenerating
`REDIS_PASSWORD` left Redis holding its boot-time password and the API
crash-looping on `WRONGPASS`; regenerating `INTERNAL_SIGNING_KEY` desynced it
from a running web dev server, whose tenant lookups then failed closed with a 503
on every subdomain. Fixed by the `keep()` helper — read the Secret first,
generate only when absent — plus a Redis restart if the value changes anyway.

## Two variables that must agree across processes

Local dev runs the web outside the cluster, so both are passed by hand:

```bash
cd web && env \
  INTERNAL_SIGNING_KEY="$(kubectl get secret cme-api-secrets -n cme-local \
      -o jsonpath={.data.INTERNAL_SIGNING_KEY} | base64 -d)" \
  NODE_EXTRA_CA_CERTS="$HOME/.cme-local-tls/cert.pem" \
  NEXT_PUBLIC_API_URL=https://api.lvh.me:8443 \
  NEXT_PUBLIC_ROOT_DOMAIN=lvh.me \
  npx next dev
```

The signing key must match the API's or every tenant subdomain answers 503. The
CA path must be set or server-side fetches die on `DEPTH_ZERO_SELF_SIGNED_CERT`
and render as a server exception.

## A bug found by comparing the manifest to the running object

`api-deployment-patch.yaml` declared `PUBLIC_BASE_URL` twice — once
`http://localhost:3000`, once `https://www.lvh.me:8443`. Kustomize keys env
entries by name, so one silently won:

```
$ kubectl get deploy cme-api -n cme-local -o jsonpath='{...PUBLIC_BASE_URL...}'
PUBLIC_BASE_URL=http://localhost:3000
```

The intended value lost. Every absolute URL the API generated locally pointed at
a plain-http origin the app itself rejects — and nothing anywhere reported a
problem.

Reproduced in isolation with `kubectl kustomize` to be sure of the mechanism: the
strategic merge collapses the two entries into one and keeps the **first**, so
the second never reaches the cluster and there is nothing left for `kubectl` to
warn about. Note that the same duplicate in a _plain_ manifest behaves the other
way round — both entries survive, `kubectl apply` warns, and the kubelet gives
the container the **last**. First wins in one path, last in the other, which is
exactly why guessing from the file is worse than useless.

This is why `klocal status` reports duplicate env declarations alongside the
value actually in effect, and distinguishes the two cases.

## Where the knowledge lived before this plugin

Nowhere reusable, which is the reason this plugin exists. The project's `docs/`
mentions none of it; its one "Local Development" section describes a superseded
plain-http setup and recommends a file the project's own conventions forbid. The
real knowledge was in shell comments, the bring-up script's closing output, and
four commit messages — none of which travel to the next project.
