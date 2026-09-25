#!/usr/bin/env bash
# Tests for the vinvoice library and CLI. No network and no vendor: `curl` is
# stubbed on PATH, and the stub is created BEFORE the first test that could
# reach one, so a regression cannot fall through to the real Viettel API.
#
#   bash plugins/vinvoice/scripts/test-vinvoice.sh
#   bash plugins/vinvoice/scripts/test-vinvoice.sh --self-check
#
# Assertion discipline, because a suite that cannot fail is not evidence:
#   - `want` demands a specific string. An EMPTY expectation is itself a failure,
#     since every string contains the empty string.
#   - Empty output is always a hard failure, never agreement.
#   - `want_absent` additionally requires a marker proving execution reached the
#     code under test; otherwise silence from an unrelated crash scores as a pass.
#   - `want_status` pins an exit code. EVERY behaviour test asserts one: a review
#     found four checks that passed on the diagnostic text alone and would have
#     kept passing if the command had started returning success.
#   - stdout and stderr are captured SEPARATELY, so a test can prove which stream
#     something went to. Merging them let `--raw` pass even if the vendor bytes
#     had gone to stderr, where a pipe would never see them.
#   - --self-check breaks five assertions on purpose and fails the run unless all
#     five go red.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
plugin=$(dirname "$here")
VINVOICE="$plugin/bin/vinvoice"

pass=0
fail=0
out=""
err=""
both=""
status=0

ok() {
  printf '  ok   %-62s %s\n' "$1" "${2:-}"
  pass=$((pass + 1))
}
bad() {
  printf '  FAIL %-62s %s\n' "$1" "$2"
  fail=$((fail + 1))
}

want() { # <label> <want> <got>
  if [ -z "$2" ]; then
    bad "$1" "EMPTY EXPECTATION — every string contains it; this check can never fail"
    return
  fi
  if [ -z "$3" ]; then
    bad "$1" "EMPTY OUTPUT — the command produced nothing; it likely never ran"
    return
  fi
  case "$3" in
    *"$2"*) ok "$1" ;;
    *) bad "$1" "want substring [$2] got [$(printf '%s' "$3" | tr '\n' '/' | cut -c1-110)]" ;;
  esac
}

want_absent() { # <label> <unwanted> <proof> <got>
  if [ -z "$2" ] || [ -z "$3" ]; then
    bad "$1" "want_absent needs both an unwanted string and a proof marker"
    return
  fi
  case "$4" in
    *"$3"*) ;;
    *)
      bad "$1" "PROOF MARKER [$3] missing — the code under test never ran, so the absence proves nothing"
      return
      ;;
  esac
  case "$4" in
    *"$2"*) bad "$1" "unwanted string [$2] is present" ;;
    *) ok "$1" ;;
  esac
}

want_status() { # <label> <want> <got>
  if [ "$2" = "$3" ]; then
    ok "$1" "exit $3"
  else
    bad "$1" "want exit $2 got $3"
  fi
}

# --- the stub vendor --------------------------------------------------------
# Created first, before anything can call out.

stubdir=$(mktemp -d "${TMPDIR:-/tmp}/vinvoice-test.XXXXXX")
# ⚠️ Not paranoia. Without this, a failing `mktemp` leaves `stubdir` empty, and
# the next two lines become `mkdir -p /bin` and `cat > /bin/curl` — the suite
# would either damage the system curl or, having failed to write the stub, run
# the REAL curl against the real vendor while reporting itself offline.
if [ -z "$stubdir" ] || [ ! -d "$stubdir" ]; then
  echo "FATAL: could not create a temp directory; refusing to run (the curl stub would not exist)" >&2
  exit 1
fi
case "$stubdir" in
  /tmp | / | "") echo "FATAL: refusing to use [$stubdir] as the stub directory" >&2; exit 1 ;;
esac
trap 'rm -rf "$stubdir"' EXIT
mkdir -p "$stubdir/bin"

cat >"$stubdir/bin/curl" <<'STUB'
#!/usr/bin/env bash
# Stub curl. Records its argv and its stdin (curl's -K config, which is where the
# credentials travel), copies the request body aside, writes the fixture to the
# --output path, and prints the status code on stdout exactly as
# --write-out '%{http_code}' would.
: >"$VI_TEST_ARGV"
for a in "$@"; do printf '%s\n' "$a" >>"$VI_TEST_ARGV"; done
cat >"$VI_TEST_STDIN"
: >"$VI_TEST_BODY"
out=""
prev=""
for a in "$@"; do
  case "$prev" in
    --output) out=$a ;;
    --data-binary) [ -f "${a#@}" ] && cp "${a#@}" "$VI_TEST_BODY" ;;
  esac
  prev=$a
done
if [ -n "$out" ]; then printf '%s' "${VI_TEST_FIXTURE-}" >"$out"; fi
printf '%s' "${VI_TEST_CODE:-200}"
exit "${VI_TEST_CURL_RC:-0}"
STUB
chmod +x "$stubdir/bin/curl"

export PATH="$stubdir/bin:$PATH"
export VI_TEST_ARGV="$stubdir/argv"
export VI_TEST_STDIN="$stubdir/stdin"
export VI_TEST_BODY="$stubdir/body"
export VI_TEST_FIXTURE='{"errorCode":null,"description":null,"result":{"invoiceNo":"K25TAA123","reservationCode":"ABC123XYZ"}}'
export VI_TEST_CODE=200
export VI_TEST_CURL_RC=0

# A complete, valid configuration. Individual tests override one variable at a
# time so a failure names the variable that caused it. The password deliberately
# contains both characters that need escaping in a curl config file.
export VIETTEL_INVOICE_BASE_URL="https://api-vinvoice.viettel.vn/services/einvoiceapplication/api/InvoiceAPI"
export VIETTEL_INVOICE_USERNAME="0100109106-507"
export VIETTEL_INVOICE_PASSWORD='p@ss"w\ord'
export VIETTEL_INVOICE_SUPPLIER_TAX_CODE="0100109106-507"
export VIETTEL_INVOICE_TEMPLATE_CODE="1/001"
export VIETTEL_INVOICE_SERIAL="C26TAA"

# runenv sets the globals `out` (stdout), `err` (stderr), `both`, and `status`.
#
# Not `out=$(run …)`: a command substitution runs the function in a SUBSHELL, so
# the exit status it recorded would never reach the parent and every want_status
# would compare a stale value. Environment overrides go through `env` rather than
# a `VAR=x func` prefix, whose persistence after the call differs between bash's
# POSIX and default modes.
#
# The two streams are kept apart on purpose — see the header.
runenv() { # <VAR=value>... -- <args>...
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift || true
  env ${envs+"${envs[@]}"} "$VINVOICE" "$@" >"$stubdir/stdout" 2>"$stubdir/stderr"
  status=$?
  out=$(cat "$stubdir/stdout")
  err=$(cat "$stubdir/stderr")
  both="$out$err"
}
run() { runenv -- "$@"; }

argv() { cat "$VI_TEST_ARGV" 2>/dev/null; }
first_arg() { head -1 "$VI_TEST_ARGV" 2>/dev/null; }
sent_body() { cat "$VI_TEST_BODY" 2>/dev/null; }
sent_config() { cat "$VI_TEST_STDIN" 2>/dev/null; }
sent_all() { printf '%s\n%s\n%s' "$(argv)" "$(sent_config)" "$(sent_body)"; }

# shellcheck source=lib/common.sh
. "$plugin/scripts/lib/common.sh"

echo "vinvoice test suite"
echo

# --- usage and refusals -----------------------------------------------------
echo "usage and refusals"

run
want_status "no arguments exits 2" 2 "$status"
want "no arguments prints usage" "read-only probe" "$both"

for verb in create issue cancel void adjust replace delete; do
  run "$verb"
  want_status "$verb is refused" 3 "$status"
done
run create
want "the refusal explains the frozen snapshot" "FROZEN snapshot" "$both"
want "the refusal points at the pipeline" "issue from the pipeline" "$both"
# The old form of this check only looked for the absence of getAllInvoiceTemplates,
# so a regression that POSTed createInvoice while still printing the refusal would
# have passed. Assert on the write endpoint itself, across argv, config AND body.
want_absent "a refused create sends no createInvoice request" "createInvoice" "not available" "$both$(sent_all)"

run frobnicate
want_status "an unknown command exits 2" 2 "$status"

# --- the read-only guarantee ------------------------------------------------
echo
echo "read-only guarantee"

run templates
want "curl is invoked with --disable FIRST, so ~/.curlrc cannot add a request" "--disable" "$(first_arg)"

vout=$(vi_assert_read_only 'url = "https://x/InvoiceWS/createInvoice/1"' 2>&1)
want_status "a config naming a write endpoint is refused" 1 "$?"
want "that refusal names the endpoint" "write endpoint createInvoice" "$vout"

vi_assert_read_only 'url = "https://x/InvoiceUtilsWS/getAllInvoiceTemplates"' 2>/dev/null
want_status "a read endpoint is still allowed" 0 "$?"

for ep in createBatchInvoice cancelTransactionInvoice updatePaymentStatus sendInvoiceByTransactionUuid; do
  vi_assert_read_only "url = \"https://x/InvoiceWS/$ep\"" 2>/dev/null
  want_status "$ep is refused too" 1 "$?"
done

# The guard has to be WIRED IN, not merely present: vi_post must consult it, and
# must not reach curl at all. Emptying argv first is what makes the second
# assertion mean "curl was never invoked" rather than "argv looks stale".
: >"$VI_TEST_ARGV"
vi_post "https://x/InvoiceWS/createInvoice/1" "application/json" /dev/null "$stubdir/refused" 2>/dev/null
want_status "vi_post refuses a write endpoint before sending" 90 "$?"
if [ -s "$VI_TEST_ARGV" ]; then
  bad "a refused write endpoint never reaches curl" "curl WAS invoked: $(tr '\n' ' ' <"$VI_TEST_ARGV" | cut -c1-70)"
else
  ok "a refused write endpoint never reaches curl"
fi

# --- configuration ----------------------------------------------------------
echo
echo "configuration"

runenv VIETTEL_INVOICE_PASSWORD= VIETTEL_INVOICE_USERNAME= -- templates
want_status "missing configuration exits 1" 1 "$status"
want "missing configuration names the password" "VIETTEL_INVOICE_PASSWORD" "$both"
want "missing configuration names the username too, not just the first" "VIETTEL_INVOICE_USERNAME" "$both"

vout=$(vi_validate_base_url "http://api-vinvoice.viettel.vn/x/InvoiceAPI" 2>&1)
want_status "plain http is rejected" 1 "$?"
want "the http rejection says why" "Basic credentials and buyer personal data" "$vout"

vi_validate_base_url "http://localhost:8443/InvoiceAPI" 2>/dev/null
want_status "http on localhost is allowed (a local mock)" 0 "$?"

vi_validate_base_url "http://[::1]:8443/InvoiceAPI" 2>/dev/null
want_status "http on the IPv6 loopback is allowed too" 0 "$?"

vout=$(vi_validate_base_url "https://api-vinvoice.viettel.vn/services" 2>&1)
want_status "a base URL stopping short of /InvoiceAPI is rejected" 1 "$?"
want "that rejection names the suffix" "/InvoiceAPI" "$vout"

vi_validate_base_url "$VIETTEL_INVOICE_BASE_URL" 2>/dev/null
want_status "the vendor's own base URL is accepted" 0 "$?"

vi_validate_base_url "ftp://api-vinvoice.viettel.vn/InvoiceAPI" 2>/dev/null
want_status "a non-http scheme is rejected" 1 "$?"

# Injection into curl's config syntax. Each of these ends in /InvoiceAPI, so the
# suffix check alone would have accepted every one.
vout=$(vi_validate_base_url "$(printf 'https://x/InvoiceAPI\nurl = "https://y/InvoiceAPI')" 2>&1)
want_status "a base URL containing a newline is rejected" 1 "$?"
want "the newline rejection explains the curl config risk" "another request" "$vout"

vout=$(vi_validate_base_url "$(printf 'https://x/InvoiceAPI\r')" 2>&1)
want_status "a base URL containing a carriage return is rejected" 1 "$?"

vi_validate_base_url 'https://x"y/InvoiceAPI' 2>/dev/null
want_status "a base URL containing a double quote is rejected" 1 "$?"

vi_validate_base_url 'https://x\y/InvoiceAPI' 2>/dev/null
want_status "a base URL containing a backslash is rejected" 1 "$?"

vi_validate_base_url 'https://x y/InvoiceAPI' 2>/dev/null
want_status "a base URL containing a space is rejected" 1 "$?"

# The two bypasses a second review round found. Each ends in /InvoiceAPI, so the
# suffix check alone accepted both; each reaches a write endpoint anyway — one by
# percent-encoding a letter past the literal deny list, one by parking the suffix
# in a query string while the real path points at createInvoice.
vout=$(vi_validate_base_url 'https://host/InvoiceWS/%63reateInvoice?/InvoiceAPI' 2>&1)
want_status "the percent-encoded write endpoint is rejected" 1 "$?"
want "the rejection explains percent-encoding" "percent-encoding is refused" "$vout"

vout=$(vi_validate_base_url 'https://host/InvoiceWS/createInvoice?x=/InvoiceAPI' 2>&1)
want_status "a query string carrying the suffix is rejected" 1 "$?"
want "the rejection explains the query string" "query string or fragment" "$vout"

vi_validate_base_url 'https://host/InvoiceAPI#/InvoiceAPI' 2>/dev/null
want_status "a fragment carrying the suffix is rejected" 1 "$?"

# Ends in /InvoiceAPI, so only the percent rule can catch it.
vi_validate_base_url 'https://host/a%2Fb/InvoiceAPI' 2>/dev/null
want_status "any percent sign at all is rejected" 1 "$?"

# Case is not a way past the guard either.
vi_assert_read_only 'url = "https://x/InvoiceWS/CreateInvoice/1"' 2>/dev/null
want_status "a mixed-case write endpoint is refused" 1 "$?"
vout=$(vi_assert_read_only 'url = "https://x/InvoiceWS/CREATEINVOICE/1"' 2>&1)
want_status "an upper-case write endpoint is refused" 1 "$?"
want "the refusal keeps the endpoint's real spelling" "write endpoint createInvoice" "$vout"

# --- credential handling ----------------------------------------------------
echo
echo "credential handling"

cfg=$(vi_curl_config "https://x/y" 'user' 'p@ss"w\ord')
want "the curl config escapes a quote in the password" 'p@ss\"w' "$cfg"
want "the curl config escapes a backslash in the password" '\\ord' "$cfg"
want "the curl config carries the url" 'url = "https://x/y"' "$cfg"

cfg=$(vi_curl_config 'https://a\b"c/InvoiceAPI' u p)
want "the URL is escaped too, not only the credentials" 'https://a\\b\"c/InvoiceAPI' "$cfg"

# The first hardening round checked the URL for line breaks and left the
# credentials unchecked, so the same injection worked through the password.
vout=$(vi_curl_config "https://x/InvoiceAPI" "user" "$(printf 'p\ntrace-ascii = "/tmp/leak"')" 2>&1)
want_status "a newline in the PASSWORD is refused" 1 "$?"
want "that refusal explains the curl config risk" "line-oriented" "$vout"

vi_curl_config "https://x/InvoiceAPI" "$(printf 'u\nnext')" "pass" >/dev/null 2>&1
want_status "a newline in the USERNAME is refused" 1 "$?"

vi_curl_config "https://x/InvoiceAPI" "user" "$(printf 'p\rmore')" >/dev/null 2>&1
want_status "a carriage return in the password is refused" 1 "$?"

vi_curl_config "https://x/InvoiceAPI" "user" "ordinary-password" >/dev/null 2>&1
want_status "an ordinary password is still accepted" 0 "$?"

# And the refusal has to be WIRED IN: vi_post must not reach curl with it.
: >"$VI_TEST_ARGV"
(
  export VIETTEL_INVOICE_PASSWORD="$(printf 'p\ntrace-ascii = \"/tmp/leak\"')"
  vi_post "https://x/InvoiceUtilsWS/getAllInvoiceTemplates" "application/json" /dev/null "$stubdir/o"
) >/dev/null 2>&1
want_status "vi_post refuses to build a config from a poisoned credential" 91 "$?"
if [ -s "$VI_TEST_ARGV" ]; then
  bad "a poisoned credential never reaches curl" "curl WAS invoked"
else
  ok "a poisoned credential never reaches curl"
fi

run templates
want_status "templates succeeds against the stub" 0 "$status"
want_absent "the password never reaches the command line" 'p@ss"w\ord' "--write-out" "$(argv)"
want "the password does reach curl, through the config on stdin" 'p@ss\"w' "$(sent_config)"

run env
want "env reports the password as set" "set (10 chars)" "$both"
want_absent "env never prints the password" 'p@ss"w\ord' "VIETTEL_INVOICE_USERNAME" "$both"

# A vendor or a debugging proxy that echoes the request back must not copy the
# credential into the terminal.
runenv VI_TEST_FIXTURE='{"description":"bad password p@ss\"w\\ord"}' -- templates
want "a response echoing the password is redacted" "«password redacted»" "$both"
want_absent "the echoed password is not printed" 'p@ss"w\ord' "«password redacted»" "$both"

run login
want "login sends its body inside the curl config, not through a file" 'data = "{\"username\"' "$(sent_config)"
want_absent "login writes no request body to disk" "--data-binary" "data = " "$(argv)$(sent_config)"

# --- env files are parsed, never executed -----------------------------------
echo
echo "env files"

envfile="$stubdir/creds.env"
export PWNED_MARKER="$stubdir/pwned"
cat >"$envfile" <<'ENVF'
# a comment
export VIETTEL_INVOICE_SUPPLIER_TAX_CODE="0999999999-001"
VIETTEL_INVOICE_TEMPLATE_CODE='2/002'
VI_TEST_INJECTED=$(touch "$PWNED_MARKER")
ENVF
run --env-file "$envfile" templates
want "an env file supplies values" "0999999999-001" "$(sent_body)"
if [ -e "$PWNED_MARKER" ]; then
  bad "an env file is never executed" "command substitution in a value ran and created $PWNED_MARKER"
else
  ok "an env file is never executed"
fi

printf 'VIETTEL_INVOICE_SUPPLIER_TAX_CODE=0123456789\r\n' >"$stubdir/crlf.env"
crlfout=$(
  . "$plugin/scripts/lib/common.sh"
  vi_load_env_file "$stubdir/crlf.env"
  printf '%s' "${#VIETTEL_INVOICE_SUPPLIER_TAX_CODE}"
)
want "a CRLF env file does not leave a carriage return in the value" "10" "$crlfout"

run --env-file "$stubdir/nope.env" templates
want_status "a missing env file is fatal" 1 "$status"
want "a missing env file says so" "env file not found" "$both"

# --- argument handling ------------------------------------------------------
echo
echo "argument handling"

# Every one of these used to exit 1 printing NOTHING AT ALL: `shift 2` with one
# positional left fails, and `set -e` turned that into a silent abort.
for spec in "search --from" "search --to" "search --from 2026-01-01 --to 2026-01-02 --invoice-no" \
  "search --from 2026-01-01 --to 2026-01-02 --page" "search --from 2026-01-01 --to 2026-01-02 --per" \
  "file K1 --type" "file K1 --out"; do
  # shellcheck disable=SC2086
  run $spec
  flag=${spec##* }
  want_status "\`$spec\` (no value) exits 1" 1 "$status"
  want "\`$spec\` says which flag needs a value" "$flag needs a value" "$both"
done

# --- what actually goes on the wire -----------------------------------------
echo
echo "requests"

run templates
want "templates calls getAllInvoiceTemplates" "/InvoiceUtilsWS/getAllInvoiceTemplates" "$(sent_config)"
want "templates asks for every invoice type" '"invoiceType":"all"' "$(sent_body)"
want "templates sends the supplier tax code" '0100109106-507' "$(sent_body)"

run lookup 'abc/123 xyz'
want "lookup calls searchInvoiceByTransactionUuid" "/InvoiceWS/searchInvoiceByTransactionUuid" "$(sent_config)"
want "lookup posts a form, not JSON" "Content-Type: application/x-www-form-urlencoded" "$(argv)"
want "lookup percent-encodes the uuid" "transactionUuid=abc%2F123%20xyz" "$(sent_body)"

run lookup
want_status "lookup without a uuid is a usage error" 1 "$status"
want "lookup says what it needs" "needs a transactionUuid" "$both"

run search --from 2026-09-01 --to 2026-09-30
want_status "search without --invoice-no still runs" 0 "$status"
want "search uses the UTC+7 endpoint" "/InvoiceUtilsWS/getInvoicesAll/" "$(sent_config)"
want_absent "search does not use the UTC+0 endpoint" "getAllInvoices/" "getInvoicesAll" "$(sent_config)"
want "search sends the period" '"startDate":"2026-09-01"' "$(sent_body)"

run search --from 2026-09-01 --to 2026-09-30 --invoice-no K25TAA123
want "search passes an invoice number through" '"invoiceNo":"K25TAA123"' "$(sent_body)"

run search --to 2026-09-30
want_status "search without a period is refused" 1 "$status"

run file K25TAA123
want "file calls getInvoiceRepresentationFile" "/InvoiceUtilsWS/getInvoiceRepresentationFile" "$(sent_config)"
want "file defaults to PDF" '"fileType":"PDF"' "$(sent_body)"
want "file sends the template code" '"templateCode":"1/001"' "$(sent_body)"

runenv VIETTEL_INVOICE_TEMPLATE_CODE= -- file K25TAA123
want_status "file without a template code is refused" 1 "$status"
want "file says which value is missing" "mẫu số" "$both"

# --out must not be opened until there is something to write into it.
printf 'ORIGINAL CONTENT\n' >"$stubdir/keepme.pdf"
runenv VI_TEST_CODE=500 VI_TEST_FIXTURE='Request Fail' -- file K1 --out "$stubdir/keepme.pdf"
want_status "a failed \`file --out\` exits 1" 1 "$status"
want "a failed \`file --out\` leaves the existing file untouched" "ORIGINAL CONTENT" "$(cat "$stubdir/keepme.pdf")"

run file K1 --out "$stubdir/keepme.pdf"
want_status "a successful \`file --out\` exits 0" 0 "$status"
want "a successful \`file --out\` writes the vendor's bytes" "K25TAA123" "$(cat "$stubdir/keepme.pdf")"

# --- check ------------------------------------------------------------------
echo
echo "check"

runenv VI_TEST_FIXTURE='{"result":[{"templateCode":"1/001","invoiceSeries":"C26TAA"}]}' -- check
want_status "check passes when the configured identity is registered" 0 "$status"
want "check confirms the mẫu số and ký hiệu as a PAIR" "mẫu số 1/001 and ký hiệu C26TAA are registered TOGETHER" "$both"

runenv VI_TEST_FIXTURE='{"result":[{"templateCode":"9/999","invoiceSeries":"ZZZZZZ"}]}' -- check
want_status "check FAILS when the configured mẫu số is not on the account" 1 "$status"
want "check says the identity is unconfirmed" "invoice identity is UNCONFIRMED" "$both"

runenv VIETTEL_INVOICE_SERIAL= VI_TEST_FIXTURE='{"result":[{"templateCode":"1/001"}]}' -- check
want_status "check FAILS when the ký hiệu is not configured at all" 1 "$status"

printf '{"result":[{"templateCode":"1/001","invoiceSeries":"C26TAA"},{"templateCode":"2/002","invoiceSeries":"C26TBB"}]}' >"$stubdir/pairs.json"
pairs=$(vi_json_pairs "$stubdir/pairs.json" templateCode invoiceSeries)
want_status "vi_json_pairs succeeds when objects carry both keys" 0 "$?"
want "vi_json_pairs reports the first pair" "1/001|C26TAA" "$pairs"
want "vi_json_pairs reports the second pair" "2/002|C26TBB" "$pairs"

printf '{"result":[{"templateCode":"1/001"},{"invoiceSeries":"C26TAA"}]}' >"$stubdir/unpaired.json"
vi_json_pairs "$stubdir/unpaired.json" templateCode invoiceSeries >/dev/null 2>&1
want_status "vi_json_pairs reports 1 when nothing pairs the two keys" 1 "$?"

# THE PAIR, not the two values separately. This account holds both configured
# values — but not together, and that combination is rejected on every invoice.
runenv VIETTEL_INVOICE_TEMPLATE_CODE=1/001 VIETTEL_INVOICE_SERIAL=C26TBB \
  VI_TEST_FIXTURE='{"result":[{"templateCode":"1/001","invoiceSeries":"C26TAA"},{"templateCode":"2/002","invoiceSeries":"C26TBB"}]}' -- check
want_status "check FAILS on a cross-paired mẫu số and ký hiệu" 1 "$status"
want "check names the pair it could not find" "PAIR mẫu số 1/001 + ký hiệu C26TBB" "$both"
want "check lists the pairs the account does hold" "2/002" "$both"

# Without a JSON reader the answer is "I cannot tell", never "not registered".
sandbox="$stubdir/nopython"
mkdir -p "$sandbox"
for t in bash env mktemp cat head tr wc mv rm grep dirname readlink sed; do
  src=$(command -v "$t" 2>/dev/null) && ln -sf "$src" "$sandbox/$t"
done
ln -sf "$stubdir/bin/curl" "$sandbox/curl"
# The probe runs in a CHILD shell on purpose. `PATH=x command -v python3` in this
# shell answers from bash's command hash, which already holds the real python3
# because vi_json_pairs ran earlier — so the precondition passed while the PATH
# it was testing had nothing to do with the answer. A child bash starts with an
# empty hash and actually searches the PATH it was given.
if [ -x "$sandbox/bash" ] && ! PATH="$sandbox" bash -c 'command -v python3' >/dev/null 2>&1; then
  out=$(PATH="$sandbox" "$VINVOICE" check 2>&1)
  status=$?
  want_status "check FAILS when python3 is unavailable" 1 "$status"
  want "check blames python3, not the account" "python3 is not installed" "$out"
  want_absent "check does not claim the mẫu số is missing" "is NOT in the list" "python3 is not installed" "$out"
else
  bad "check without python3" "could not build a python3-free PATH sandbox"
fi

# --- reading the answer -----------------------------------------------------
echo
echo "classification"

run lookup 3f7c
want_status "a successful lookup exits 0" 0 "$status"
want "a successful call reports the identifiers it found" "invoiceNo: K25TAA123" "$both"
want "nested identifiers are found, not only top-level ones" "reservationCode: ABC123XYZ" "$both"

runenv VI_TEST_FIXTURE='{"invoiceNo":"TOP1"}' -- lookup u1
want "a top-level identifier is found too" "invoiceNo: TOP1" "$both"

# Each subcommand asks for the keys that answer ITS question.
runenv VI_TEST_FIXTURE='{"result":[{"templateCode":"1/001","invoiceSeries":"C26TAA"}]}' -- templates
want "templates surfaces the mẫu số" "templateCode: 1/001" "$both"
want "templates surfaces the ký hiệu" "invoiceSeries: C26TAA" "$both"

runenv VI_TEST_FIXTURE='{"errorCode":"INV_001","description":"Ký hiệu không tồn tại"}' -- templates
want_status "a vendor rejection exits non-zero" 1 "$status"
want "a vendor rejection is named as one" "the vendor REJECTED this call" "$both"
want "a vendor rejection quotes the vendor's own words" "Ký hiệu không tồn tại" "$both"

runenv VI_TEST_CODE=500 VI_TEST_FIXTURE='Request Fail' -- templates
want_status "a 500 exits non-zero" 1 "$status"
want "a 500 names the IP whitelist before anything else" "SOURCE IP IS NOT WHITELISTED" "$both"
want "a 500 says how to find the address" "vinvoice egress-ip" "$both"

# A 503 is not the whitelist signature, and saying so sends people down the
# wrong path for an hour.
runenv VI_TEST_CODE=503 VI_TEST_FIXTURE='<html>Service Unavailable</html>' -- templates
want_status "a 503 exits non-zero" 1 "$status"
want "a 503 is reported as a vendor-side error" "a vendor-side error" "$both"
want_absent "a 503 is NOT blamed on the IP whitelist" "SOURCE IP IS NOT WHITELISTED" "vendor-side error" "$both"

runenv VI_TEST_CODE=404 -- templates
want_status "a 404 exits non-zero" 1 "$status"
want "a 404 distinguishes the two vendor hosts" "api-sinvoice.viettel.vn answers 404" "$both"

runenv VI_TEST_CODE=401 -- templates
want_status "a 401 exits non-zero" 1 "$status"
want "a 401 explains that the username is the tax code" "username is the supplier tax code" "$both"
want "a 401 also points at the IP whitelist" "source-IP whitelisting" "$both"

runenv VI_TEST_CODE=200 VI_TEST_FIXTURE= -- templates
want_status "an empty 200 is a failure, not a pass" 1 "$status"
want "an empty 200 says not to read it as success" "do not read this as success" "$both"

# The one a review caught: this used to exit 0, so `check` printed PROVEN under
# an intermediary's HTML error page.
runenv VI_TEST_FIXTURE='<html>502 Bad Gateway</html>' -- templates
want_status "a non-JSON 200 exits NON-ZERO" 1 "$status"
want "a non-JSON 200 says the call is not proven" "the call is NOT proven" "$both"
want "a non-JSON 200 is printed verbatim rather than swallowed" "502 Bad Gateway" "$both"

runenv VI_TEST_FIXTURE='<html>502 Bad Gateway</html>' -- check
want_status "check FAILS on a non-JSON 200" 1 "$status"
want_absent "check does not claim PROVEN on a non-JSON 200" "PROVEN" "NOT proven" "$both"

runenv VI_TEST_CURL_RC=6 -- templates
want_status "a DNS failure exits non-zero" 1 "$status"
want "a DNS failure is named" "DNS lookup failed" "$both"

runenv VI_TEST_CURL_RC=28 -- templates
want_status "a timeout exits non-zero" 1 "$status"
want "a timeout points at the timeout variables" "VINVOICE_TIMEOUT" "$both"

runenv VI_TEST_CURL_RC=60 -- templates
want_status "a TLS failure exits non-zero" 1 "$status"
want "a TLS failure says the fault is local" "a failure here is local" "$both"

runenv VIETTEL_INVOICE_TIMEOUT_SECONDS=7 VINVOICE_TIMEOUT= -- env
# Whitespace-normalised so the assertion is about the value, not about the width
# of a printf column.
want "the application's own timeout variable is honoured" "(timeout in force) 7s" "$(printf '%s' "$both" | tr -s ' ')"

runenv VI_TEST_FIXTURE='{"result":{"invoiceNo":"RAW1"}}' -- --raw templates
want_status "--raw exits 0" 0 "$status"
# Deliberately asserted against stdout ALONE: a pipe only sees stdout, so a
# regression that printed the vendor bytes to stderr must go red here.
want "--raw passes the vendor bytes through on STDOUT" '{"result":{"invoiceNo":"RAW1"}}' "$out"

# --- self-check -------------------------------------------------------------
if [ "${1:-}" = "--self-check" ]; then
  echo
  echo "self-check: five assertions are broken on purpose and MUST go red"
  before=$fail
  want "SELF-CHECK empty expectation must fail" "" "anything"
  want "SELF-CHECK empty output must fail" "something" ""
  want "SELF-CHECK wrong substring must fail" "not-in-there" "some output"
  want_absent "SELF-CHECK missing proof marker must fail" "x" "marker-that-is-absent" "some output"
  want_status "SELF-CHECK wrong status must fail" 0 7
  broke=$((fail - before))
  if [ "$broke" -eq 5 ]; then
    echo "  self-check: all 5 sabotaged assertions went red"
    fail=$before
    pass=$((pass + 5))
  else
    echo "  self-check: only $broke of 5 sabotaged assertions went red — THE HARNESS IS NOT BINDING"
    fail=$((before + 1))
  fi
fi

echo
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
