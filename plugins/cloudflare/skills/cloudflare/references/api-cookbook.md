# REST API recipes (curl)

wrangler has no DNS, cache or zone-settings commands; the API does. Every call
below assumes `$CLOUDFLARE_API_TOKEN` was filled by `opgate exec` (see
`secrets.md`) and is written as `$CLOUDFLARE_API_TOKEN`, never as a value.

## Reads

```bash
curl -sS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/zones?name=cmevietnam.dev" | jq '.result[] | {id, name}'
curl -sS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/zones/<zone id>/dns_records?per_page=100" \
  | jq -r '.result[] | [.type, .name, .content, .proxied] | @tsv'
curl -sS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/zones/<zone id>/settings/ssl" | jq .result
curl -sS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/user/tokens/verify" | jq .result.status
```

Paginate before you conclude: list endpoints default to 20 or 100 items per page;
read `result_info.total_pages`.

## DNS records

```bash
curl -sS -X POST -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/<zone id>/dns_records" \
  --json '{"type":"CNAME","name":"cdn","content":"cme-cdn-staging.workers.dev","proxied":true}'

curl -sS -X PATCH -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/<zone id>/dns_records/<record id>" \
  --json '{"proxied":false}'

curl -sS -X DELETE -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  "https://api.cloudflare.com/client/v4/zones/<zone id>/dns_records/<record id>"
```

A GitHub Pages custom domain needs its CNAME set to DNS only (`"proxied":false`).

## Cache

```bash
curl -sS -X POST -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/zones/<zone id>/purge_cache" \
  --json '{"files":["https://cdn.cmevietnam.dev/a.css"]}'
# purge_everything on a protected zone asks first
```

## Zone settings and rules

```bash
curl -sS -X PATCH -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/zones/<zone id>/settings/always_use_https" \
  --json '{"value":"on"}'
curl -sS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/zones/<zone id>/rulesets" | jq '.result[] | {id, phase, name}'
```

## Analytics (GraphQL)

POST to `/graphql` is a read and passes:

```bash
curl -sS -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" "https://api.cloudflare.com/client/v4/graphql" --json '{"query":"{ viewer { zones(filter:{zoneTag:\"<zone id>\"}) { httpRequests1dGroups(limit:7, filter:{date_gt:\"2026-09-27\"}) { sum { requests } dimensions { date } } } } }"}'
```

## Errors

The API answers `{"success":false,"errors":[{"code":...,"message":...}]}` with
an HTTP 4xx. `curl -f` throws that body away; keep it (`-sS`, then check
`.success`), because the message is where Cloudflare says which permission is
missing.
