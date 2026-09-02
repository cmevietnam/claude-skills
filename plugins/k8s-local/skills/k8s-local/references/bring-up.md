# Bringing the stack up, and why the steps are in this order

Each step here exists because skipping it produces a failure that looks like
something else. The ordering is not cosmetic: several steps are only safe once an
earlier one has happened.

## 0. Preflight — everything that must hold before anything is applied

Checked before a single manifest is touched, because every one of these is
cheaper to catch now than to diagnose from a symptom later.

1. **`kubectl` exists.**
2. **A context exists, and it is local.** A whitelist of exact names. No context
   at all is refused the same way a remote one is — failing closed, because the
   alternative is applying to whatever happens to be current.
3. **The cluster answers.** `kubectl cluster-info`. A context can name a cluster
   that is not running.
4. **The IngressClass exists.** A _warning_, not a failure — the stack still runs
   and `kubectl port-forward` still works. But it has to be said out loud: the
   manifests apply cleanly and the rollout goes green while every hostname routes
   nowhere, and from the symptom end that is indistinguishable from an app bug.

## 1. Build into the cluster's image store

There is no registry and no push. The kubelet finds the tag locally, provided
two things are true:

- The overlay sets `imagePullPolicy: IfNotPresent` and `imagePullSecrets: null`.
  With the default `Always`, the kubelet ignores the local image and tries to
  pull `PROJECT-api:local` from Docker Hub, which fails with `ImagePullBackOff`
  on an image that is sitting right there.
- The build went to the store the cluster actually reads.

**Probe the socket, not the binary.** Rancher Desktop ships `nerdctl` even when
the configured engine is moby, and there it cannot reach the k3s containerd
socket. `command -v nerdctl` succeeding proves nothing:

```bash
if command -v nerdctl >/dev/null && nerdctl --namespace k8s.io info >/dev/null 2>&1; then
  nerdctl --namespace k8s.io build -t "$IMAGE" "$CONTEXT"   # containerd: k3s reads k8s.io
elif command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  docker build -t "$IMAGE" "$CONTEXT"                        # moby: the cluster shares this daemon
fi
```

The `k8s.io` namespace is not optional on containerd. An image built into the
default namespace is invisible to the kubelet, with the same
`ErrImageNeverPull` symptom as not having built it at all.

## 2. Namespace, then secret, then manifests

The namespace must exist before the Secret; the Secret must exist before the
workloads, or the app starts, finds no `secretKeyRef`, and crash-loops while the
real problem is one step upstream.

**Secret values must never touch disk.** The pattern that achieves this: the
bring-up script re-enters itself under a vault runner, so the values exist only
in that child process's environment and go straight into `kubectl` on stdin.

```bash
opgate run -f api/.env.op -- ./deploy/scripts/local-secret.sh
```

and inside that script:

```bash
kubectl create secret generic "$KL_SECRET" -n "$KL_NAMESPACE" "${args[@]}" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
```

`create --dry-run=client | apply` is what makes it idempotent — plain
`kubectl create secret` fails on the second run.

### Reuse generated values; never rotate them on a re-run

Some values are not in the vault and get generated: a Redis password, signing
keys, a test secret. Generating them on every run is the bug:

- Redis keeps the `--requirepass` it was started with for the life of the
  container. Rotate the Secret and the app crash-loops on `WRONGPASS` against a
  password only the Secret knows.
- A rotated signing key stops matching an already-running dev server, whose
  requests then fail closed — often as a 503 on every tenant subdomain.

So: read what the Secret already holds, and fall back to a generator only when
it is absent.

```bash
keep() { # <key> <generator...>
  local v
  v=$(kubectl get secret "$SECRET" -n "$NS" -o "jsonpath={.data.$1}" 2>/dev/null \
      | base64 -d 2>/dev/null || true)
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  shift; "$@"
}
REDIS_PASSWORD=$(keep REDIS_PASSWORD openssl rand -hex 16)
```

If a value does change anyway, restart the workload that holds the stale copy in
the same run.

## 3. Wait for the datastores before touching the database

Roll out in dependency order — database, cache, then the app — and wait on each.
The database role work in step 4 runs `psql` inside the Postgres pod, which is
only possible once that rollout is complete.

## 4. Create the least-privilege application role

The `postgres` image hands you a superuser. If the app connects as it, every
`FORCE ROW LEVEL SECURITY` policy is bypassed: tenant isolation is off, and
nothing fails — local behaves subtly differently from production, in the
direction that hides multi-tenancy bugs rather than surfacing them.

Three properties, all of which must hold:

```sql
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_role') THEN
    CREATE ROLE app_role;
  END IF;
END $$;
-- Unconditional. A role left from an earlier run may carry a different
-- password, NOLOGIN, or worse SUPERUSER — exactly what this role exists to avoid.
ALTER ROLE app_role LOGIN PASSWORD 'app_local_only'
  NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;
GRANT CONNECT ON DATABASE app_dev TO app_role;
-- Covers everything the migrations create from here on.
ALTER DEFAULT PRIVILEGES FOR ROLE owner GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_role;
ALTER DEFAULT PRIVILEGES FOR ROLE owner GRANT USAGE, SELECT, UPDATE ON SEQUENCES TO app_role;
```

Then **assert it**, and fail the bring-up if the assertion does not hold:

```bash
[ "$(psql -tAc "SELECT rolsuper OR rolbypassrls OR NOT rolcanlogin
                FROM pg_roles WHERE rolname='app_role'")" = "f" ] \
  || { echo "FAIL: app_role is not a safe login role" >&2; exit 1; }
```

`ALTER DEFAULT PRIVILEGES` only covers objects created _after_ it runs. On any
re-run against an already-migrated database, the existing tables and sequences
still need explicit grants — so reconcile them every time, not once.

## 5. Migrations, run as the owner

The datastores have no volume. A pod restart empties the database and the
migrations must be re-run — this is the deliberate trade-off, not a defect. Run
them as the owning role, not the app role: the app role is not supposed to be
able to create tables.

After any migration that adds a schema, re-run the grant step.

## 6. TLS, when the app requires https

Skip this only if the app genuinely works over plain http. Two things commonly
mean it does not, and both fail in ways that look like routing bugs:

- The app rejects any `Origin` that is not https. Requests route, CORS passes,
  and login returns an origin error.
- The app sets `__Host-` cookies, which are `Secure` unconditionally. The
  browser drops them silently, so every request after login is anonymous.

The fix is a TLS front door in front of the cluster — not TLS on the Ingress —
so one certificate covers both the API and the frontend dev server, and browsers
reach a single origin. `templates/https-proxy.mjs` is ~90 lines of Node
built-ins: it terminates TLS on `:8443` and routes by `Host`, forwarding
WebSocket upgrades so hot reload keeps working.

Two details people lose an hour to:

- **The SAN needs a config file.** macOS ships LibreSSL, which has no `-addext`.
- **Server-side fetches need the cert trusted**, or they die on
  `DEPTH_ZERO_SELF_SIGNED_CERT` and render as a server exception with no clue
  about certificates. For Node: `NODE_EXTRA_CA_CERTS=<cert.pem>`.

## 7. Print the next steps

The last thing a bring-up prints is the best documentation the project has,
because it is the only copy that cannot drift out of date without someone
noticing. Say where the stack is reachable, that the data is ephemeral, how to
read logs, and how to tear down.

## Teardown

```bash
kubectl delete namespace PROJECT-local
```

That is the whole uninstall, which is the reason everything lives in one
namespace.
