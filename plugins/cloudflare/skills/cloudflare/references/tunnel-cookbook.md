# cloudflared recipes

## Which certificate, which zone

`cloudflared tunnel login` authorises ONE zone and writes `~/.cloudflared/cert.pem`.
Tunnel commands that create DNS records act inside that zone: `route dns` with a
hostname from another zone produces `<hostname>.<cert zone>`, a record in the
wrong zone. Keep one certificate per zone and pass it explicitly:

```bash
ls ~/.cloudflared/cert.pem*
cfgate doctor                     # says which zone the default cert.pem is for
cloudflared tunnel --origincert ~/.cloudflared/cert.pem.cmevietnam.dev <command>
```

`TUNNEL_ORIGIN_CERT=<file>` works too. Never `cat` a cert: it holds an API token.

## Named tunnels

```bash
cloudflared tunnel list
cloudflared tunnel info cme-api
cloudflared tunnel --origincert ~/.cloudflared/cert.pem.cmevietnam.dev create cme-api
cloudflared tunnel --origincert ~/.cloudflared/cert.pem.cmevietnam.dev route dns cme-api api.cmevietnam.dev
cloudflared tunnel --config ~/.cloudflared/cme-api.yml run cme-api
cloudflared tunnel cleanup cme-api            # drop stale connections
cloudflared tunnel delete cme-api
```

Tunnel names carry the project prefix like every other resource. A tunnel named
by UUID asks first: the UUID does not say whose it is.

Locally-managed config (`~/.cloudflared/<name>.yml`):

```yaml
tunnel: cme-api
credentials-file: /Users/me/.cloudflared/<tunnel-uuid>.json
ingress:
  - hostname: api.cmevietnam.dev
    service: http://localhost:8080
  - service: http_status:404
```

The DNS record and the tunnel are independent: deleting a tunnel leaves its CNAME
pointing nowhere (visitors get error 1016). Remove the record through the API.

## Remotely-managed tunnels (token)

The dashboard or API owns the ingress; the connector only needs the token.

```bash
cloudflared tunnel token cme-api | opgate put cme TUNNEL_TOKEN
opgate exec TUNNEL_TOKEN=op://Dev/cme/TUNNEL_TOKEN -- cloudflared tunnel run
```

## What asks or is refused

- `--overwrite-dns` replaces whatever the hostname points to now: asks.
- `cloudflared tunnel --url http://localhost:8080` (quick tunnel) publishes the
  port on a random public `trycloudflare.com` name: asks.
- `tunnel route ip` and `tunnel vnet` change the account's private network: ask.
- `tunnel login`, `service install`, `update`: ask; they change the tool, not a
  resource. `service install` with a token on the line is refused.

## Access

```bash
cloudflared access login https://admin.cmevietnam.dev     # browser login, asks
cloudflared access curl https://admin.cmevietnam.dev/api  # a request with the Access token
cloudflared access tcp --hostname db.cmevietnam.dev --url localhost:5433
```

`cloudflared access token <url>` prints a token: send it to a variable, not the
transcript.
