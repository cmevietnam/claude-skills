#!/usr/bin/env python3
"""Generate scripts/lib/cf-commands.tsv from the `cf` CLI's own command manifest.

The Cloudflare CLI (`cf`, npm package `cf`) ships dist/_meta/commands.json: every
command with its HTTP method, API path, positional arguments and typed options.
The guard maps a `cf` invocation to the API request it sends and checks that
request like a curl call, so this table is generated, never written by hand.

    python3 scripts/gen-cf-table.py <path to node_modules/cf>

Commands with no API path (project commands, auth, tunnels run...) are classified
in HAND below. A new one fails the generator: classify it before shipping.
"""
import glob
import json
import os
import re
import sys

# kind for commands that send no single API request:
#   read      reaches Cloudflare but changes nothing
#   local     never reaches Cloudflare
#   cli       changes cf's own login or settings
#   secret    prints a credential
#   project   deploys from cloudflare.config.ts, which the guard cannot evaluate
#   account   account-level, belongs to no project
#   expose    publishes a local port on a public hostname
#   tunnelrun runs a tunnel connector (name checked, literal token refused)
#   d1id      writes to a D1 database addressed by id
HAND = {
    "access curl": "read",
    "access login": "cli",
    "access ssh-config": "local",
    "access ssh-gen": "local",
    "access tcp": "local",
    "access token": "secret",
    "auth activate": "cli",
    "auth create": "cli",
    "auth deactivate": "cli",
    "auth delete": "cli",
    "auth list": "read",
    "auth login": "cli",
    "auth logout": "cli",
    "auth whoami": "read",
    "build": "local",
    "cli search": "read",
    "cli telemetry disable": "local",
    "cli telemetry enable": "local",
    "cli telemetry status": "local",
    "complete": "local",
    "containers build": "local",
    "containers images delete": "account",
    "containers images list": "read",
    "containers push": "account",
    "containers ssh": "account",
    "d1 migrations apply": "d1id",
    "d1 migrations create": "local",
    "d1 migrations list": "read",
    "deploy": "project",
    "dev": "local",
    "init": "local",
    "init workers": "local",
    "migrate": "local",
    "pages deploy": "project",
    "previews deploy": "project",
    "schema": "local",
    "tools": "account",
    "tunnels diag": "read",
    "tunnels login": "cli",
    "tunnels quick-start": "expose",
    "tunnels ready": "read",
    "tunnels run": "tunnelrun",
    "tunnels tail": "read",
    "workers check": "local",
    "workers triggers deploy": "project",
    "workers types": "local",
    "workers versions create": "project",
}

# Options whose value is a credential: written literally, it is in the transcript.
# Three signals, because a name alone misses the commands whose whole purpose is
# storing a secret (`workers secrets update --text`, `secrets-store ... --value`).
SECRET_RE = re.compile(
    r"(^|-)(password|secret|private-key|token|api-key|credentials|secret-access-key|client-secret|signing-secret"
    r"|tunnel-secret|authorization|md5-key|custom-key|key-base64|pem|psks)$"
)
NOT_SECRET = {"page-token", "filters-token-id"}
# The manifest's own description says the value is the secret.
SECRET_DESC_RE = re.compile(r"^(The (secret|credential) value|The value of the secret)", re.I)
# Commands that store secrets: their --body carries the same values.
SECRET_BODY_CMD_RE = re.compile(r"(^| )(secrets|credentials) (bulk|create|edit|update)$")


def is_secret(path, opt):
    if opt["type"] == "boolean" or opt["name"] in NOT_SECRET:
        return False
    return bool(
        SECRET_RE.search(opt["name"])
        or SECRET_DESC_RE.search(opt.get("description") or "")
        or (opt["name"] == "body" and SECRET_BODY_CMD_RE.search(path))
    )


def kebab(name):
    """yargs reads `--fooBar` as `--foo-bar`; the table keeps the kebab form."""
    return re.sub(r"([A-Z])", lambda m: "-" + m.group(1).lower(), name)


# Every command also takes these (cf adds them when it builds the command).
ALWAYS_BOOL = ["dry-run", "force"]


def bundle_options(root):
    """How cf's bundled yargs builders really declare options: the names read as
    greedy arrays (`array: true` swallows every following word that is not an
    option) and the aliases. The manifest records neither."""
    pat = re.compile(r"\.option\(`([^`]+)`,\{([^{}]*)\}")
    arrays, aliases = set(), {}
    for fn in glob.glob(os.path.join(root, "dist", "*.mjs")):
        for name, body in pat.findall(open(fn, encoding="utf-8").read()):
            if "array:!0" in body:
                arrays.add(kebab(name))
            for a in re.findall(r"alias:`([\w-]+)`", body) + re.findall(r"alias:\[([^\]]*)\]", body):
                for one in re.findall(r"[\w-]+", a):
                    if one != name:
                        aliases[one] = kebab(name)
    if not arrays:
        sys.exit("no `array: true` option found in the bundle; cf changed how it declares options")
    return sorted(arrays), aliases


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    root = sys.argv[1]
    meta = json.load(open(os.path.join(root, "dist", "_meta", "commands.json")))
    version = json.load(open(os.path.join(root, "package.json")))["version"]
    arrays, aliases = bundle_options(root)
    rows, missing = [], []
    for c in meta["commands"]:
        path = " ".join(c["fullPath"])
        method = c.get("httpMethod") or "-"
        api = c.get("apiPath") or "-"
        if api == "-":
            kind = HAND.get(path)
            if kind is None:
                missing.append(path)
                continue
        else:
            kind = "read" if method == "GET" else "write"
        opts = [dict(o, name=kebab(o["name"])) for o in c.get("options", [])]
        argnames = [a["name"] for a in c.get("arguments", [])]
        # cf fills the path by position: when the one path parameter has a
        # different name from the one positional (ai-gateway gateways delete
        # <gateway-id> sends /gateways/{id}), name the positional after it.
        params = [q for q in re.findall(r"\{(\w+)\}", api)
                  if q not in ("account_id", "zone_id", "zone_identifier", "account_or_zone", "account_or_zone_id")]
        known = set(argnames) | {o["name"] for o in opts}
        unmatched = [q for q in params if q.replace("_", "-") not in known and q not in known
                     and not (q == "script_name" and known & {"worker", "script"})]
        if len(unmatched) == 1 and len(argnames) == 1 and argnames[0].replace("-", "_") not in params:
            argnames = [unmatched[0].replace("_", "-")]
        args = ",".join(argnames)
        vals = ",".join(o["name"] for o in opts if o["type"] != "boolean")
        secrets = ",".join(o["name"] for o in opts if is_secret(path, o))
        bools = [o["name"] for o in opts if o["type"] == "boolean"]
        bools += [b for b in ALWAYS_BOOL if b not in bools]
        rows.append("\t".join([path, kind, method, api, args or "-", vals or "-", secrets or "-",
                               c.get("category") or "-", ",".join(bools)]))
    if missing:
        sys.exit("unclassified commands with no API path (add them to HAND): " + ", ".join(missing))
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib", "cf-commands.tsv")
    with open(out, "w") as f:
        f.write(f"# generated by scripts/gen-cf-table.py from cf {version} ({meta.get('generatedAt', '?')}); do not edit\n")
        f.write("# path\tkind\tmethod\tapiPath\targs\tvalue-options\tsecret-options\tcategory\tboolean-options\n")
        f.write("#arrays\t" + ",".join(arrays) + "\n")
        f.write("#aliases\t" + ",".join(f"{k}={v}" for k, v in sorted(aliases.items())) + "\n")
        f.write("\n".join(rows) + "\n")
    print(f"{len(rows)} commands from cf {version} -> {out} ({len(arrays)} array options, {len(aliases)} aliases)")


if __name__ == "__main__":
    main()
