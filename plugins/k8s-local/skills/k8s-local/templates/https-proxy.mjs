/**
 * TLS front door for the local stack.
 *
 * Needed when the app requires https even locally — it rejects non-https Origins,
 * or it sets __Host- cookies, which are Secure unconditionally. Without this, a
 * plain-HTTP local stack routes requests and passes CORS but can never complete a
 * login, which looks like a routing bug and is not one.
 *
 * Terminates TLS on :8443 with a self-signed wildcard certificate and routes by
 * Host header:
 *
 *   api.<root>      -> the cluster, through the ingress controller on :80
 *   everything else -> the frontend dev server
 *
 * Hostnames live under lvh.me, a public domain answering every name with
 * 127.0.0.1, so no /etc/hosts entry is needed for any subdomain.
 *
 * Node built-ins only — this has to run with nothing installed.
 *
 * Binds 127.0.0.1 only. Both upstreams are loopback-bound, so listening on the
 * wildcard address would have turned two local-only services into LAN-reachable
 * ones: any machine on the network could send Host: api.<root> to this port and
 * reach the cluster. Pass --host 0.0.0.0 to opt in deliberately.
 *
 * Usage: node deploy/local/https-proxy.mjs [--port 8443] [--cert DIR] [--host H]
 *
 * Generate the certificate first (SAN goes through a config file because macOS
 * LibreSSL has no -addext):
 *
 *   printf '[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n[dn]\nCN=*.lvh.me\n[v3]\nsubjectAltName=DNS:*.lvh.me,DNS:lvh.me\nbasicConstraints=CA:FALSE\n' > ~/.local-tls/openssl.cnf
 *   openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
 *     -keyout ~/.local-tls/key.pem -out ~/.local-tls/cert.pem -config ~/.local-tls/openssl.cnf
 *
 * Any server-side process that fetches through this proxy must trust that
 * certificate, or its requests die on DEPTH_ZERO_SELF_SIGNED_CERT:
 *
 *   NODE_EXTRA_CA_CERTS=~/.local-tls/cert.pem npm run dev
 */
import https from "node:https";
import http from "node:http";
import fs from "node:fs";
import net from "node:net";
import path from "node:path";

const arg = (name, fallback) => {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? fallback : process.argv[i + 1];
};

const PORT = Number(arg("port", 8443));
const HOST = arg("host", "127.0.0.1");
const CERT_DIR = arg("cert", path.join(process.env.HOME ?? ".", ".local-tls"));
const INGRESS = { host: "127.0.0.1", port: Number(arg("ingress-port", 80)) };
const WEB = { host: "127.0.0.1", port: Number(arg("web-port", 3000)) };

// Strip the port before matching: the Host header carries one and "api.x:8443"
// would not match a bare prefix test on some inputs.
const target = (hostHeader = "") =>
  hostHeader.split(":")[0].startsWith("api.") ? INGRESS : WEB;

let creds;
try {
  creds = {
    key: fs.readFileSync(path.join(CERT_DIR, "key.pem")),
    cert: fs.readFileSync(path.join(CERT_DIR, "cert.pem")),
  };
} catch {
  console.error(`no certificate in ${CERT_DIR} — see the header of this file`);
  process.exit(1);
}

const server = https.createServer(creds, (req, res) => {
  const up = http.request(
    {
      ...target(req.headers.host),
      method: req.method,
      path: req.url,
      headers: req.headers,
    },
    (r) => {
      res.writeHead(r.statusCode, r.headers);
      // If the upstream dies mid-body, `pipe` does NOT forward the error, and
      // nothing ends the downstream response: the browser sat waiting on a
      // request that would never complete. Headers are already sent by then, so
      // there is no status left to change — destroying the socket is what tells
      // the client the response was truncated.
      r.on("error", () => res.destroy());
      r.pipe(res);
    },
  );
  up.on("error", (e) => {
    // Once the status line is out, there is no 502 left to send, and `res.end()`
    // cannot honour the Content-Length already promised to the browser — it
    // finishes short, and the client waits for the rest of a body that will
    // never arrive. Destroying the socket is what makes it read as truncated.
    if (res.headersSent) {
      res.destroy();
      return;
    }
    res.writeHead(502, { "content-type": "text/plain" });
    res.end(`local proxy: ${e.message}\n`);
  });
  // A client that disconnects mid-request leaves the upstream request open and
  // its socket held until the upstream times out.
  req.on("error", () => up.destroy());
  res.on("close", () => {
    if (!res.writableEnded) up.destroy();
  });
  req.pipe(up);
});

// Dev servers open a websocket for hot reload; replay the handshake and pipe it
// through, or every save reloads nothing and the page goes quiet.
server.on("upgrade", (req, socket, head) => {
  const up = net.connect(target(req.headers.host), () => {
    const lines = [`${req.method} ${req.url} HTTP/1.1`];
    for (let i = 0; i < req.rawHeaders.length; i += 2) {
      lines.push(`${req.rawHeaders[i]}: ${req.rawHeaders[i + 1]}`);
    }
    up.write(lines.join("\r\n") + "\r\n\r\n");
    if (head?.length) up.write(head);
    up.pipe(socket);
    socket.pipe(up);
  });
  up.on("error", () => socket.destroy());
  socket.on("error", () => up.destroy());
});

server.listen(PORT, HOST, () => {
  console.log(
    `https://<host>.lvh.me:${PORT} (bound ${HOST})  ->  api.* to ingress:${INGRESS.port}, rest to web:${WEB.port}`,
  );
});
