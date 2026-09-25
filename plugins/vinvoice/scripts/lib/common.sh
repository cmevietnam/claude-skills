# Shared helpers for the vinvoice CLI: configuration, URL validation, the curl
# call, and the classification of what came back.
#
# Sourced, never executed. Nothing here has a side effect at source time, so the
# test suite can source this file and call one function in isolation.

# --- output ----------------------------------------------------------------
# Diagnostics go to stderr so a subcommand's JSON can be piped without the
# chatter coming along.
vi_info() { printf '==> %s\n' "$*" >&2; }
vi_step() { printf '    %s\n' "$*" >&2; }
vi_warn() { printf 'WARNING: %s\n' "$*" >&2; }
vi_die() {
  printf 'vinvoice: %s\n' "$*" >&2
  exit 1
}

# vi_redact removes the configured password from text this tool is about to
# print. A vendor or a debugging proxy that echoes the request back would
# otherwise copy the credential into a terminal transcript or a pasted ticket.
#
# Short values are left alone: a two-character password would match everywhere
# and turn the output into noise. It cannot protect `--raw`, which promises the
# vendor's exact bytes — that is what `--raw` means, and it is documented.
vi_redact() {
  local text=$1 pass=${VIETTEL_INVOICE_PASSWORD:-}
  if [ ${#pass} -ge 4 ]; then
    text=${text//"$pass"/«password redacted»}
  fi
  printf '%s' "$text"
}

# --- configuration ----------------------------------------------------------

# The environment variable names are the ones the reference integration uses, so
# a project that already runs the invoice pipeline can point this CLI at its own
# .env and probe the exact account the application will use.
VI_ENV_VARS="VIETTEL_INVOICE_BASE_URL VIETTEL_INVOICE_USERNAME VIETTEL_INVOICE_PASSWORD VIETTEL_INVOICE_SUPPLIER_TAX_CODE"

# vi_timeout resolves the request timeout.
#
# Both names are accepted: VIETTEL_INVOICE_TIMEOUT_SECONDS is what the
# application's own configuration uses, and pointing this CLI at that same env
# file must not silently give it a different timeout from the service it is
# standing in for.
vi_timeout() {
  printf '%s' "${VINVOICE_TIMEOUT:-${VIETTEL_INVOICE_TIMEOUT_SECONDS:-20}}"
}

# vi_load_env_file reads KEY=VALUE lines into the environment WITHOUT executing
# the file.
#
# `set -a; . file` would be shorter and is how most scripts do it — and it runs
# whatever the file contains. An .env holding invoice credentials is exactly the
# file you do not want to hand to the shell, so this parses instead: comments and
# blank lines are skipped, a leading `export ` is tolerated, and one layer of
# matching quotes is stripped. Anything else is left verbatim, including `$` and
# backticks, which are never expanded.
vi_load_env_file() { # <file>
  local file=$1 line key value
  [ -f "$file" ] || vi_die "env file not found: $file"
  while IFS= read -r line || [ -n "$line" ]; do
    # A CRLF file otherwise leaves a carriage return on the end of every value:
    # the base URL stops matching /InvoiceAPI, and the password fails auth with
    # an error that looks nothing like "your file has Windows line endings".
    line=${line%$'\r'}
    case "$line" in
      '' | '#'*) continue ;;
    esac
    line=${line#export }
    case "$line" in
      *=*) ;;
      *) continue ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    # Trim surrounding whitespace on the key only; a value's spaces may matter.
    key=$(printf '%s' "$key" | tr -d '[:space:]')
    case "$key" in
      '' | *[!A-Za-z0-9_]*) continue ;;
    esac
    case "$value" in
      '"'*'"') value=${value#\"}; value=${value%\"} ;;
      "'"*"'") value=${value#\'}; value=${value%\'} ;;
    esac
    export "$key=$value"
  done <"$file"
}

# vi_require_env names EVERY missing variable, not the first one.
#
# Reporting them one per run turns a five-variable setup into five round trips,
# and each round trip is a person going back to a password manager.
vi_require_env() { # <var>...
  local var missing=""
  for var in "$@"; do
    if [ -z "${!var:-}" ]; then
      missing="$missing $var"
    fi
  done
  if [ -n "$missing" ]; then
    printf 'vinvoice: missing required configuration:%s\n' "$missing" >&2
    printf '    set them in the environment, or pass --env-file <file>\n' >&2
    return 1
  fi
  return 0
}

# vi_validate_base_url enforces the properties that are worth a hard failure.
#
# https, because the request carries Basic credentials and the buyer's personal
# data; the /InvoiceAPI suffix, because the vendor's own collection puts every
# path under it and a base URL stopping short of it fails with a 404 that reads
# like a retired endpoint rather than like a typo; and a strict character set,
# because this value is interpolated into curl's own config syntax.
#
# ⚠️ THE CHARACTER CHECKS ARE SECURITY CONTROLS, not tidiness. Three of them,
# each closing a different way to turn a read-only probe into a write:
#
#  * NO LINE BREAKS. curl's config format is line-oriented, so a newline lets the
#    value add directives of its own — another `url`, a `data-binary`, a `next`,
#    or a `trace-ascii` that writes the Basic credential to disk.
#
#  * NO `%`. The read-only guard matches endpoint names literally, and a server
#    decodes the path before routing, so `%63reateInvoice` would sail past the
#    guard and arrive as `createInvoice`. Percent-encoding is never needed here:
#    this value is a plain scheme://host/path, and the one component that can
#    contain arbitrary characters — the supplier tax code — is escaped separately
#    where it is appended.
#
#  * NO `?` OR `#`. The /InvoiceAPI suffix check is what keeps the base URL
#    pointed at this API surface, and a query string can satisfy it while the
#    real path points somewhere else entirely:
#    `https://host/InvoiceWS/createInvoice?/InvoiceAPI` ends in /InvoiceAPI and
#    POSTs to createInvoice.
#
# vi_curl_config escapes on top of all three, and vi_assert_read_only checks the
# rendered request afterwards. Any one of the four could be enough; none of them
# is trusted to be.
vi_validate_base_url() { # <url>
  local url=$1 scheme rest host illegal
  case "$url" in
    '') printf 'VIETTEL_INVOICE_BASE_URL is empty\n' >&2; return 1 ;;
  esac
  case "$url" in
    *$'\n'* | *$'\r'*)
      printf 'VIETTEL_INVOICE_BASE_URL contains a line break — refusing, because this value is written into curl config syntax and a second line there can add another request\n' >&2
      return 1
      ;;
  esac
  case "$url" in
    *%*)
      printf 'VIETTEL_INVOICE_BASE_URL contains %% — percent-encoding is refused here, because the read-only guard matches endpoint names literally while the server decodes the path first (%%63reateInvoice arrives as createInvoice)\n' >&2
      return 1
      ;;
  esac
  case "$url" in
    *'?'* | *'#'*)
      printf 'VIETTEL_INVOICE_BASE_URL contains a query string or fragment — refused, because the /InvoiceAPI suffix check would be satisfied by it while the real path points elsewhere\n' >&2
      return 1
      ;;
  esac
  # Everything outside the legal character set for THIS value, counted in BYTES so
  # a trailing control character cannot be swallowed by command substitution.
  illegal=$(printf '%s' "$url" | LC_ALL=C tr -d "A-Za-z0-9._~:/@!\$&'()*+,;=[]-" | LC_ALL=C wc -c | tr -d ' ')
  if [ "${illegal:-0}" -ne 0 ]; then
    printf 'VIETTEL_INVOICE_BASE_URL contains %s character(s) that are not legal here (quotes, backslashes, spaces and control characters are refused)\n' "$illegal" >&2
    return 1
  fi
  case "$url" in
    *://*) ;;
    *) printf 'VIETTEL_INVOICE_BASE_URL must be an absolute URL (got %s)\n' "$url" >&2; return 1 ;;
  esac
  scheme=${url%%://*}
  rest=${url#*://}
  rest=${rest%%/*}
  rest=${rest##*@}
  # An IPv6 authority is bracketed, so trimming at the first colon would turn
  # [::1]:8443 into "[" and make the loopback exception below unreachable.
  case "$rest" in
    \[*\]*) host=${rest%%\]*}; host=${host#\[} ;;
    *) host=${rest%%:*} ;;
  esac
  case "$scheme" in
    https) ;;
    http)
      case "$host" in
        localhost | 127.0.0.1 | ::1) ;;
        *)
          printf 'VIETTEL_INVOICE_BASE_URL must use https:// — Basic credentials and buyer personal data are POSTed to it (got %s)\n' "$url" >&2
          return 1
          ;;
      esac
      ;;
    *)
      printf 'VIETTEL_INVOICE_BASE_URL must use https:// (got scheme %s)\n' "$scheme" >&2
      return 1
      ;;
  esac
  if [ -z "$host" ]; then
    printf 'VIETTEL_INVOICE_BASE_URL has no host (got %s)\n' "$url" >&2
    return 1
  fi
  case "${url%/}" in
    */InvoiceAPI) ;;
    *)
      printf 'VIETTEL_INVOICE_BASE_URL should end at /InvoiceAPI — every documented path is appended to it (got %s)\n' "$url" >&2
      return 1
      ;;
  esac
  return 0
}

# --- the call ---------------------------------------------------------------

# Endpoints that create, replace, adjust, void or re-file a document. This tool
# must never reach one, so the check is on the rendered request rather than on
# the subcommand name: a dispatcher can be bypassed, a config file cannot lie
# about what it contains.
VI_WRITE_ENDPOINTS="createInvoice createBatchInvoice createOrUpdateInvoiceDraft createExchangeInvoiceFile createInvoiceWithCode createTaxDeductionCertificate InsertSignature cancelTransactionInvoice cancelPaymentStatus updatePaymentStatus update-explanation sendInvoiceByTransactionUuid"

# vi_assert_read_only refuses to run a request whose curl config mentions a write
# endpoint anywhere — in the URL, in an injected second `url` line, in a
# `data-binary`. It is the last line of defence behind vi_validate_base_url's
# character check.
vi_assert_read_only() { # <config text>
  local config=$1 ep epl lower
  # Case-folded, because a path is matched case-sensitively by this shell and
  # case-insensitively by nothing in particular on the far side; `CreateInvoice`
  # must not read as a different endpoint from `createInvoice`. The ORIGINAL
  # spelling is kept for the message — an operator searching the vendor's
  # documentation for "createinvoice" finds less than one searching for the name
  # as it is actually written.
  lower=$(printf '%s' "$config" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  for ep in $VI_WRITE_ENDPOINTS; do
    epl=$(printf '%s' "$ep" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    case "$lower" in
      *"$epl"*)
        printf 'vinvoice: REFUSING to send — the request references the write endpoint %s.\n' "$ep" >&2
        printf '    This tool is read-only; issuing a document is the application'\''s job.\n' >&2
        printf '    If you did not ask for that, check VIETTEL_INVOICE_BASE_URL for injected content.\n' >&2
        return 1
        ;;
    esac
  done
  return 0
}

# vi_curl_config renders a curl -K config carrying the URL and the credentials.
#
# The credentials go through this file (fed on curl's stdin, never written to
# disk) rather than through `--user` on the command line, because an argument is
# visible in `ps` to every other user on the machine for the life of the request.
#
# curl's config format quotes with `"` and understands backslash escapes inside
# the quotes, so both characters have to be escaped in EVERY value — the URL
# included. Escaping only the credentials left the one field an operator can
# supply from an env file able to close its own quote and open a new directive.
vi_curl_config() { # <url> <user> <pass> [data]
  local url=$1 user=$2 pass=$3 data=${4:-} field
  # ⚠️ EVERY value, not just the URL. The first round of this hardening checked
  # the base URL for line breaks and left the credentials unchecked — so a
  # password containing a newline still closed its own `user = "..."` line and
  # opened a directive of its own, which is the same credential-dumping vector
  # through a different field. A newline in a Viettel username or password is
  # never legitimate, so this refuses rather than escaping.
  for field in "$url" "$user" "$pass" "$data"; do
    case "$field" in
      *$'\n'* | *$'\r'*)
        printf 'vinvoice: a configuration value contains a line break — refusing to build a curl config from it (curl config is line-oriented, so a second line becomes a second directive)\n' >&2
        return 1
        ;;
    esac
  done
  url=${url//\\/\\\\}
  url=${url//\"/\\\"}
  user=${user//\\/\\\\}
  user=${user//\"/\\\"}
  pass=${pass//\\/\\\\}
  pass=${pass//\"/\\\"}
  printf 'url = "%s"\n' "$url"
  printf 'user = "%s:%s"\n' "$user" "$pass"
  if [ -n "$data" ]; then
    data=${data//\\/\\\\}
    data=${data//\"/\\\"}
    printf 'data = "%s"\n' "$data"
  fi
}

# vi_post performs one POST and leaves the body in <out_file>, printing the HTTP
# status code on stdout. Returns curl's exit status.
#
# The request body is passed as a file because curl's stdin is taken by the
# config; the body of a read call is never secret, while the config always is.
# `vi_post_secret` is the variant for a body that IS secret.
#
# ⚠️ `--disable` MUST stay the first argument. Without it curl reads ~/.curlrc
# and applies whatever it finds to every request this tool makes — including, in
# a config that supports `next`, an entire additional transfer. A read-only
# guarantee that a dotfile can revoke is not a guarantee.
vi_post() { # <url> <content_type> <body_file> <out_file> [timeout]
  local url=$1 ct=$2 body=$3 out=$4 timeout=${5:-$(vi_timeout)} config
  config=$(vi_curl_config "$url" "${VIETTEL_INVOICE_USERNAME:-}" "${VIETTEL_INVOICE_PASSWORD:-}") || return 91
  vi_assert_read_only "$config$(cat "$body" 2>/dev/null)" || return 90
  printf '%s\n' "$config" |
    curl --disable --silent --show-error --config - \
      --max-time "$timeout" \
      --request POST \
      --header "Content-Type: $ct" \
      --header 'Accept: application/json' \
      --data-binary "@$body" \
      --output "$out" \
      --write-out '%{http_code}'
}

# vi_post_secret is vi_post for a request body that carries a credential.
#
# The body travels inside the config on stdin, so the password never reaches the
# filesystem. Writing it to a temp file was safe on a normal exit and not safe
# on SIGKILL, a panic, or a power loss — and a login body is the one request
# here whose contents are the credential itself.
vi_post_secret() { # <url> <content_type> <body> <out_file> [timeout]
  local url=$1 ct=$2 body=$3 out=$4 timeout=${5:-$(vi_timeout)} config
  config=$(vi_curl_config "$url" "${VIETTEL_INVOICE_USERNAME:-}" "${VIETTEL_INVOICE_PASSWORD:-}" "$body") || return 91
  vi_assert_read_only "$config" || return 90
  printf '%s\n' "$config" |
    curl --disable --silent --show-error --config - \
      --max-time "$timeout" \
      --request POST \
      --header "Content-Type: $ct" \
      --header 'Accept: application/json' \
      --output "$out" \
      --write-out '%{http_code}'
}

# --- reading the answer -----------------------------------------------------

# vi_classify turns a status code and a body into a diagnosis a person can act
# on, and into an exit status.
#
# The case that earns this function is 500. Viettel whitelists source IPs per
# account and answers a caller from an unregistered address with a 500 whose
# body is the plain text "Request Fail" — indistinguishable from a real server
# error unless something says so out loud. Reading that as "the vendor is down"
# costs an afternoon; it is the single most common first-contact failure.
vi_classify() { # <curl_exit> <http_code> <body_file>
  local rc=$1 code=$2 file=$3 body=""
  if [ -f "$file" ]; then body=$(vi_redact "$(head -c 400 "$file" 2>/dev/null || true)"); fi

  if [ "$rc" -ne 0 ]; then
    case "$rc" in
      6) printf 'transport: DNS lookup failed — check the host in VIETTEL_INVOICE_BASE_URL\n' >&2 ;;
      7) printf 'transport: connection refused — nothing accepted the request\n' >&2 ;;
      28) printf 'transport: timed out after %ss — raise VINVOICE_TIMEOUT (or VIETTEL_INVOICE_TIMEOUT_SECONDS) if the network is slow\n' "$(vi_timeout)" >&2 ;;
      35 | 60) printf 'transport: TLS failed — the vendor serves a complete chain from a public CA, so a failure here is local (a proxy, or a pinned/custom trust store)\n' >&2 ;;
      90 | 91) printf 'transport: the request was refused before it was sent (see above)\n' >&2 ;;
      *) printf 'transport: curl exit %s\n' "$rc" >&2 ;;
    esac
    return 1
  fi

  case "$code" in
    200 | 201)
      if [ -z "$body" ]; then
        printf 'http 200 with an EMPTY body — the vendor accepted the call and said nothing; do not read this as success\n' >&2
        return 1
      fi
      return 0
      ;;
    401 | 403)
      printf 'http %s — rejected at the door. Check the credentials AND the source-IP whitelisting on the account; the username is the supplier tax code (branch suffix included, e.g. 0100109106-507)\n' "$code" >&2
      return 1
      ;;
    404)
      printf 'http 404 — no such path. Check VIETTEL_INVOICE_BASE_URL ends at /InvoiceAPI, and that the host is api-vinvoice.viettel.vn (api-sinvoice.viettel.vn answers 404 for this API surface)\n' >&2
      return 1
      ;;
    500)
      printf 'http 500 — and this is the trap: a 500 whose body is "Request Fail" is what Viettel answers a caller whose SOURCE IP IS NOT WHITELISTED on the account, not a vendor outage. Run `vinvoice egress-ip`, and have that address registered before concluding anything else. Body: %s\n' "$body" >&2
      return 1
      ;;
    5*)
      printf 'http %s — a vendor-side error. For a READ this is simply a failure; for a write it would be AMBIGUOUS (the document may exist). Body: %s\n' "$code" "$body" >&2
      return 1
      ;;
    *)
      printf 'http %s: %s\n' "$code" "$body" >&2
      return 1
      ;;
  esac
}

# vi_have_json reports whether the JSON reader this tool needs is available.
#
# It exists so a caller can say "I cannot confirm this" instead of reporting the
# thing it could not look at as absent — which is what `check` did when python3
# was missing: the raw-JSON fallback never emits the `templateCode: <v>` lines it
# matches on, so a correctly configured account was reported as not holding its
# own mẫu số.
vi_have_json() { command -v python3 >/dev/null 2>&1; }

# vi_json_pairs prints "<a>|<b>" for every OBJECT in the response that carries
# both keys, so a caller can check that two values belong together.
#
# Checking them independently is not the same question. An account holding
# (1/001, C26TAA) and (2/002, C26TBB) answers yes to "is 1/001 registered?" and
# yes to "is C26TBB registered?" while the pair 1/001 + C26TBB does not exist and
# is rejected on every invoice.
vi_json_pairs() { # <file> <keyA> <keyB>
  vi_have_json || return 2
  VI_A=$2 VI_B=$3 python3 - "$1" <<'PY'
import json, os, sys

try:
    doc = json.loads(open(sys.argv[1], "rb").read().decode("utf-8", "replace"))
except ValueError:
    sys.exit(2)

a, b = os.environ["VI_A"], os.environ["VI_B"]
seen = set()

def walk(node):
    if isinstance(node, dict):
        if a in node and b in node and node[a] is not None and node[b] is not None:
            seen.add("%s|%s" % (node[a], node[b]))
        for v in node.values():
            walk(v)
    elif isinstance(node, list):
        for v in node:
            walk(v)

walk(doc)
for line in sorted(seen):
    print(line)
sys.exit(0 if seen else 1)
PY
}

# vi_json_report pretty-prints a vendor response and pulls out the fields that
# decide what happened.
#
# It scans for the keys ANYWHERE in the tree rather than at a fixed path,
# because the vendor is inconsistent about whether identifiers sit at the top
# level or under `result` — the reference client carries a fallback for exactly
# that. A reader that assumed one shape would report "not found" for a response
# that plainly contains the number.
#
# A body that is not JSON, and a body carrying an errorCode, both exit NON-ZERO.
# An HTTP 200 holding an intermediary's HTML error page is not a proven call,
# and `vinvoice check` must not print PROVEN under one.
vi_json_report() { # <file> [key]...
  local file=$1
  shift
  if ! vi_have_json; then
    vi_redact "$(cat "$file")"
    printf '\n'
    return 0
  fi
  VI_KEYS="$*" VI_PASS="${VIETTEL_INVOICE_PASSWORD:-}" python3 - "$file" <<'PY'
import json, os, sys

path = sys.argv[1]
raw = open(path, "rb").read().decode("utf-8", "replace")

secret = os.environ.get("VI_PASS", "")

def redact(s):
    return s.replace(secret, "«password redacted»") if len(secret) >= 4 else s

def scrub(node):
    # Redact the parsed VALUES, before serializing. Running a string replace over
    # json.dumps output instead matches nothing whenever the password contains a
    # quote or a backslash, because the dump has escaped them by then.
    if isinstance(node, dict):
        return {k: scrub(v) for k, v in node.items()}
    if isinstance(node, list):
        return [scrub(v) for v in node]
    if isinstance(node, str):
        return redact(node)
    return node

try:
    doc = json.loads(raw)
except ValueError:
    # A non-JSON 200 is a real outcome, not a parse bug to hide: an intermediary
    # can answer with an HTML error page, and the vendor answers a non-whitelisted
    # caller with the plain text "Request Fail". Exiting 0 here let `check` report
    # a proven connection under a 502.
    print("response is NOT JSON — the call is NOT proven. Printing it verbatim:")
    print(redact(raw[:2000]))
    sys.exit(1)

doc = scrub(doc)
print(json.dumps(doc, ensure_ascii=False, indent=2)[:20000])

keys = [k for k in os.environ.get("VI_KEYS", "").split() if k]
if not keys:
    sys.exit(0)

found = {}
def walk(node):
    if isinstance(node, dict):
        for k, v in node.items():
            if k in keys and not isinstance(v, (dict, list)) and v not in (None, ""):
                found.setdefault(k, []).append(v)
            walk(v)
    elif isinstance(node, list):
        for v in node:
            walk(v)

walk(doc)
if found:
    print("\n--- fields ---")
    for k in keys:
        for v in found.get(k, []):
            print(f"{k}: {v}")

err = found.get("errorCode")
if err:
    print("\nerrorCode is set — the vendor REJECTED this call.")
    sys.exit(1)
PY
}
