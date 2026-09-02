# Symptom, cause, fix

Ordered roughly by how long each one wastes before you find it. The expensive
ones are near the top, and they share a shape: everything reports healthy.

## The hostname returns nothing, but every pod is Running

Three different causes, distinguished by where the response stops.

**No ingress controller.** The `Ingress` names a class nothing implements. It
applied cleanly and will never route.

```bash
kubectl get ingressclass                 # empty, or missing the one you named
kubectl get ingress -A                   # ADDRESS column empty
```

Install a controller, or drop ingress and use `kubectl port-forward`. See
`engines.md` — only Rancher Desktop and k3d ship one.

**The name does not resolve.** `ping api.lvh.me` should give `127.0.0.1`. Public
wildcard DNS needs the network; offline, add the host to `/etc/hosts`.

**It routes, and the app is answering 404.** This is success being misread. Tell
the two apart by the body, not the status code:

```bash
curl -s http://api.lvh.me/some-path
# "404 page not found"  -> Go's default; your app answered, the route is just wrong
# Traefik's 404 page    -> the ingress matched nothing
```

## The pod will not start: ImagePullBackOff / ErrImageNeverPull on a local image

The image exists on your machine and the cluster cannot see it.

- `imagePullPolicy` resolved to `Always`. Kubernetes defaults it by tag:
  `IfNotPresent` for an ordinary tag, `Always` for `:latest` or no tag at all. So
  a local image tagged `:latest` gets pulled from Docker Hub instead of used.
  Tag local builds something other than `latest` and set the policy explicitly.
  (`ErrImageNeverPull` rather than `ImagePullBackOff` means the policy is
  `Never` — then the image really is absent from the node's store.)
- The build went to the wrong store. On containerd the `k8s.io` namespace is
  mandatory. On kind, k3d or minikube a host build never reaches the cluster
  without an explicit load step.

```bash
nerdctl --namespace k8s.io images | grep app   # containerd: must be listed here
```

## The app crash-loops on WRONGPASS (or a signing/JWT error) after a re-run

The bring-up regenerated a value that a running container still holds the old
copy of. Redis keeps the `--requirepass` it booted with; a dev server keeps the
signing key it started with.

The fix is not to rotate: read the existing Secret value and generate only when
absent (`bring-up.md` §2). To recover now, restart the workload holding the stale
copy:

```bash
kubectl rollout restart deployment/PROJECT-redis -n PROJECT-local
```

## An env var has a value that is in no manifest — or the wrong one of two

An env name declared twice. Which value ends up live depends on how it reached
the cluster, and the two paths resolve in **opposite** directions — both verified
on a real cluster, 2026-09-02:

| Declared twice in                    | Live spec                  | Observed winner                            | Warning                                                 |
| ------------------------------------ | -------------------------- | ------------------------------------------ | ------------------------------------------------------- |
| a kustomize strategic-merge patch    | collapsed to **one** entry | the **first**                              | none, from anything                                     |
| a plain manifest applied client-side | **both** entries survive   | the **last** (kubelet builds env in order) | `kubectl apply` says "hides previous definition of ..." |
| server-side apply                    | rejected                   | —                                          | the request fails                                       |

None of this is an API guarantee. Duplicate keys in a merge-keyed list are
malformed input, so a JSON6902 patch, or a resource with no strategic-merge
schema, need not behave like the first row. The reliable conclusion is narrower
and more useful: **the manifest cannot tell you which value is live.** A patch
duplicate is the nastiest case because the losing value is discarded during the
merge, before `kubectl` sees anything, so no tool reports it at all.

```bash
klocal status                            # distinguishes the two cases
kubectl get deploy APP -n NS -o jsonpath='{.spec.template.spec.containers[0].env}'
```

Always compare against the **live object**. The manifest is a hypothesis about
what is running.

## Login fails over http, though routing and CORS both work

Requests arrive, CORS passes, and authentication still refuses. Two causes, both
by design in the app:

- It rejects any `Origin` that is not https.
- It sets `__Host-` cookies, which are `Secure` unconditionally, so the browser
  drops them and every subsequent request is anonymous.

No amount of ingress work fixes either. Put a TLS front door on `:8443`
(`bring-up.md` §6).

`*.localhost` helps with the **second** cause only: browsers treat it as a secure
context over plain http, so `Secure` cookies survive. It does nothing for the
first — the request still carries `Origin: http://foo.localhost`, and an app that
rejects non-https origins rejects that too. Only real TLS fixes both.

## Server-side fetches fail with DEPTH_ZERO_SELF_SIGNED_CERT

The browser was told to trust the self-signed cert; the server-side runtime was
not. It usually surfaces as a rendered server exception with nothing about
certificates in it.

```bash
NODE_EXTRA_CA_CERTS="$HOME/.local-tls/cert.pem" npm run dev
```

## openssl: unknown option -addext

macOS ships LibreSSL. Put the SAN in a config file and pass `-config` — see the
header of `templates/https-proxy.mjs`.

## Tenant data leaks across tenants locally, but not in production

The app is connecting as the Postgres superuser, which bypasses every
`FORCE ROW LEVEL SECURITY` policy. Nothing errors; isolation is just off.

```sql
SELECT rolname, rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user;
```

Both flags must be false. Create a `NOSUPERUSER NOBYPASSRLS` role and assert it
during bring-up (`bring-up.md` §4).

## The database is empty after a restart

Working as designed — the local datastores have no volume. Re-run the migrations.
If you need data to survive, add a PVC, and accept that a corrupt local database
stops being a `rollout restart`.

## klocal refuses the context

```
klocal: REFUSING: context 'gke_...' does not look local.
```

Working as designed. Switch context:

```bash
kubectl config use-context rancher-desktop
```

If a _genuinely_ local context is refused, add its exact name to
`kl_context_is_local` in `scripts/lib/cluster.sh` and add a test case. Never
widen it to a substring match.

## klocal: no .k8s-local/project.json found

Not in the project, or it was never scaffolded. `klocal` walks up from `$PWD` the
way git looks for its root, so any subdirectory of the project works.

```bash
klocal scaffold
```

## Everything looks right and still does not work

Stop reading manifests and look at the machine. In order: `klocal status`, then
`kubectl describe pod` (events explain scheduling and image failures that logs
never mention), then `kubectl logs --previous` for a crash-looping container —
its current logs are from the container that has not failed yet.
