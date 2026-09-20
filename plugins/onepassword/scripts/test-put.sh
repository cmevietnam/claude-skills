#!/usr/bin/env bash
# Tests for `opgate put`, driven against a stubbed `op` and a stubbed gate.
#
# All three bugs these cover were SILENT: `put` printed its usual success line
# every time. Nothing surfaced until a value was read back and found unusable,
# which is the worst possible moment for a secret store to be wrong.
#
#   1. an item was created without tags, so the ownership check rejected it on
#      the very next put -- the item could never gain a second field
#   2. the trailing newline was stripped from every value, which corrupts an
#      OpenSSH private key or PEM block (ssh-keygen: "invalid format")
#   3. a failed `op item list` was treated as "the item does not exist", so a
#      transient 1Password timeout silently created a SECOND item with the same
#      title and split the project's secrets across both
#
# No real 1Password, no Touch ID: HOME is redirected so the gate binary is a
# stub, and a fake `op` on PATH records what would have been written.
set -uo pipefail

dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
opgate_bin="$dir/../bin/opgate"

pass=0 fail=0
tmp=$(mktemp -d "${TMPDIR:-/tmp}/opgate-test-put.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

chk() { # <label> <got> <want>
  if [[ "$2" == "$3" ]]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL %s\n       got  [%s]\n       want [%s]\n' "$1" "$2" "$3"; fi
}
chk_has() { # <label> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then pass=$((pass+1)); printf '  ok   %s\n' "$1"
  else fail=$((fail+1)); printf '  FAIL %s\n       %q not found in: %s\n' "$1" "$3" "${2:0:200}"; fi
}

# --- stubs -------------------------------------------------------------------
mkdir -p "$tmp/home/.local/share/opgate/bin" "$tmp/bin"
cat > "$tmp/home/.local/share/opgate/bin/touchid-gate" <<'GATE'
#!/usr/bin/env bash
exit 0
GATE
chmod +x "$tmp/home/.local/share/opgate/bin/touchid-gate"
# No .sha256 alongside it: _verify_gate_binary warns and allows, which is the
# documented "not built yet" path.

# Fake `op`. LIST_MODE picks what `op item list` does; every create/edit
# template is copied out so the test can inspect exactly what would be stored.
cat > "$tmp/bin/op" <<'OP'
#!/usr/bin/env bash
sub="${1:-} ${2:-}"
template=""
for (( i = 1; i <= $#; i++ )); do
  if [[ "${!i}" == "--template" ]]; then j=$((i+1)); template="${!j}"; fi
done
case "$sub" in
  "item list")
    case "${LIST_MODE:-empty}" in
      empty)     printf '[]\n' ;;
      one)       printf '[{"id":"a1","title":"itm","category":"SECURE_NOTE","tags":["opgate"]}]\n' ;;
      duplicate) printf '[{"id":"a1","title":"itm","category":"SECURE_NOTE","tags":["opgate"]},{"id":"a2","title":"itm","category":"SECURE_NOTE","tags":["opgate"]}]\n' ;;
      fail)      echo "[ERROR] authorization timeout" >&2; exit 1 ;;
    esac
    ;;
  "item get")    printf '{"id":"a1","title":"itm","category":"SECURE_NOTE","tags":["opgate"],"fields":[]}\n' ;;
  "item create") [[ -n "$template" ]] && cat "$template" > "$OP_CAPTURE.create" ;;
  "item edit")   [[ -n "$template" ]] && cat "$template" > "$OP_CAPTURE.edit" ;;
esac
exit 0
OP
chmod +x "$tmp/bin/op"

run_put() { # <list-mode> <stdin-value> [extra args...]  -> prints opgate output
  local mode="$1" value="$2"; shift 2
  rm -f "$tmp/cap.create" "$tmp/cap.edit"
  HOME="$tmp/home" PATH="$tmp/bin:$PATH" LIST_MODE="$mode" OP_CAPTURE="$tmp/cap" \
    printf '%s' "$value" | HOME="$tmp/home" PATH="$tmp/bin:$PATH" LIST_MODE="$mode" \
    OP_CAPTURE="$tmp/cap" bash "$opgate_bin" put itm FLD "$@" 2>&1
}
# Reads the value jq wrote into the captured template, BYTE-EXACTLY.
# `jq -j` so jq adds no newline of its own, and the `printf x` trick because
# $(...) strips trailing newlines -- which is precisely the byte under test.
stored_value() {
  local f="$tmp/cap.create"; [[ -f "$f" ]] || f="$tmp/cap.edit"; [[ -f "$f" ]] || return 1
  local v; v=$(jq -j '.fields[] | select(.label=="FLD") | .value' "$f"; printf x)
  printf '%s' "${v%x}"
}
# Same guard for the caller: capture without losing the final byte.
grab() { local v; v=$(stored_value; printf x); printf '%s' "${v%x}"; }

command -v jq >/dev/null || { echo "jq is required for these tests"; exit 1; }

# --- 1. the item must be tagged when created ---------------------------------
echo "tagging on create"
out=$(run_put empty 'plain-token')
if [[ -f "$tmp/cap.create" ]]; then
  chk_has "create template carries the opgate tag" "$(jq -c '.tags' "$tmp/cap.create")" '"opgate"'
  chk_has "create template carries a project tag"  "$(jq -c '.tags' "$tmp/cap.create")" '"project:'
else
  fail=$((fail+2)); printf '  FAIL no create template captured\n       %s\n' "${out:0:200}"
fi

# --- 2. trailing newline: kept for multi-line, stripped for single-line -------
echo
echo "trailing newline"
pem=$'-----BEGIN OPENSSH PRIVATE KEY-----\nabc\ndef\n-----END OPENSSH PRIVATE KEY-----\n'
run_put empty "$pem" --multiline >/dev/null
# $(...) strips trailing newlines, so even `grab` must be captured with the
# sentinel trick -- the final byte is the whole point of this assertion.
got=$(grab; printf x); got="${got%x}"
[[ -n "$got" ]] || got='<nothing captured>'
chk "a multi-line value keeps its final newline" \
    "$(printf '%s' "$got" | tail -c1 | od -An -c | tr -d ' ')" '\n'
chk "a multi-line value is otherwise byte-identical" "$got" "$pem"

run_put empty $'plain-token\n' >/dev/null
chk "a single-line value drops the convenience newline" "$(grab)" 'plain-token'

# --- 3. a failed lookup must not create a second item ------------------------
echo
echo "lookup failure is fatal, not 'item does not exist'"
out=$(run_put fail 'v')
chk "nothing is created when the lookup fails" \
    "$( [[ -f "$tmp/cap.create" ]] && echo created || echo 'no write' )" 'no write'
chk_has "the error names the real cause" "$out" 'could not list items'

echo
echo "duplicate titles are refused"
out=$(run_put duplicate 'v')
chk "nothing is written when the title is ambiguous" \
    "$( [[ -f "$tmp/cap.create" || -f "$tmp/cap.edit" ]] && echo wrote || echo 'no write' )" 'no write'
chk_has "the error explains why op:// cannot resolve" "$out" 'items titled'

# --- 4. an existing, owned item is edited rather than duplicated -------------
echo
echo "existing item"
run_put one 'v2' >/dev/null
chk "an existing owned item is edited, not re-created" \
    "$( [[ -f "$tmp/cap.edit" ]] && echo edited || echo 'not edited' )" 'edited'

echo
printf 'put: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
