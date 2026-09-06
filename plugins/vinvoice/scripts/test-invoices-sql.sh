#!/usr/bin/env bash
# Apply skills/vinvoice/templates/invoices.sql to a THROWAWAY Postgres and prove
# that every constraint it claims actually rejects what it says it rejects.
#
#   bash plugins/vinvoice/scripts/test-invoices-sql.sh
#
# Why this exists as a separate suite: a schema template is the one artefact in
# this plugin whose defects are invisible to reading. A CHECK that is subtly
# unsatisfiable, or one that accepts the value it was written to refuse, looks
# identical on the page to a correct one. Five of the constraints below were
# added because a review found the states they now forbid were reachable — and
# writing them was not evidence that they work.
#
# ⚠️ EVERY REJECTION MUST NAME THE CONSTRAINT THAT CAUSED IT. An earlier revision
# of this file scored any non-empty psql output as "rejected", which meant a
# mistyped column name, a value-count mismatch or a plain syntax error all read
# as a passing test. Measured, not assumed: three deliberately malformed
# statements were inserted into that version and all three went green. `--self-check`
# below re-runs exactly those three and fails the suite unless they are now caught.
#
# Nothing here touches any real database: a container is started on a random
# port, used, and removed. It skips cleanly when docker or psql is unavailable.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
plugin=$(dirname "$here")
TEMPLATE="$plugin/skills/vinvoice/templates/invoices.sql"
IMAGE=${VINVOICE_PG_IMAGE:-postgres:16-alpine}

for tool in docker psql; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "skip: $tool is not installed — this suite needs both docker and psql" >&2
    exit 0
  }
done
docker info >/dev/null 2>&1 || {
  echo "skip: the docker daemon is not running" >&2
  exit 0
}
[ -f "$TEMPLATE" ] || { echo "FATAL: $TEMPLATE not found" >&2; exit 1; }

pass=0
fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s — %s\n' "$1" "$2"; fail=$((fail + 1)); }

CID=""
cleanup() { [ -n "$CID" ] && docker rm -f "$CID" >/dev/null 2>&1; return 0; }
trap cleanup EXIT

echo "vinvoice schema suite ($IMAGE)"
echo
CID=$(docker run -d -e POSTGRES_PASSWORD=x -P "$IMAGE") || {
  echo "FATAL: could not start $IMAGE" >&2; exit 1; }
PORT=$(docker port "$CID" 5432/tcp | head -1 | sed 's/.*://')
[ -n "$PORT" ] || { echo "FATAL: no mapped port" >&2; exit 1; }
export PGPASSWORD=x

for _ in $(seq 1 60); do
  psql -h 127.0.0.1 -p "$PORT" -U postgres -c 'SELECT 1' >/dev/null 2>&1 && break
  sleep 0.5
done
psql -h 127.0.0.1 -p "$PORT" -U postgres -c 'SELECT 1' >/dev/null 2>&1 || {
  echo "FATAL: postgres never accepted a connection" >&2; exit 1; }

q() { psql -h 127.0.0.1 -p "$PORT" -U postgres -v ON_ERROR_STOP=1 -qtA "$@" 2>&1; }

# The template's two project-specific dependencies, stubbed: `payments` is
# whatever table records settled money, and uuid_generate_v7() is whatever id
# default the project uses. The stub carries `status` and `paid_at` because the
# template's sweep indexes are partial over them.
q -c "CREATE TABLE payments (
        id UUID PRIMARY KEY,
        status TEXT NOT NULL DEFAULT 'paid',
        paid_at TIMESTAMPTZ);
      CREATE FUNCTION uuid_generate_v7() RETURNS uuid LANGUAGE sql
        AS \$\$ SELECT gen_random_uuid() \$\$;
      INSERT INTO payments (id) VALUES ('11111111-1111-1111-1111-111111111111');" >/dev/null

out=$(q -f "$TEMPLATE")
if [ $? -eq 0 ]; then
  ok "the template applies to a real Postgres"
else
  bad "the template applies to a real Postgres" "$out"
  printf '\npassed: %d   failed: %d\n' "$pass" "$fail"
  exit 1
fi

PAYMENT="'11111111-1111-1111-1111-111111111111'"

# ins runs one INSERT and judges it.
#
#   want = "accept"          -> the statement must succeed
#   want = <constraint name> -> the statement must be rejected BY THAT CONSTRAINT
#
# The second form is the whole point. "Some error occurred" is not evidence that
# the schema refused anything: Postgres emits an error for a typo in this file
# too, and that error would otherwise be indistinguishable from the rejection the
# test claims to be observing.
ins() { # <label> <accept|constraint-name> <extra columns> <extra values>
  local label=$1 want=$2 cols=$3 vals=$4 res
  res=$(q -c "INSERT INTO invoices (payment_id, $cols) VALUES ($PAYMENT, $vals);")
  if [ "$want" = "accept" ]; then
    if [ -z "$res" ]; then ok "$label"; else bad "$label" "want accept, got: $res"; fi
  elif [ -z "$res" ]; then
    bad "$label" "want rejection by $want, but the row was ACCEPTED"
  else
    case "$res" in
      *"$want"*) ok "$label" ;;
      *) bad "$label" "want rejection by [$want] but Postgres said: $(printf '%s' "$res" | tr '\n' ' ' | cut -c1-120)" ;;
    esac
  fi
  q -c "DELETE FROM invoices" >/dev/null
}

BASE="total_with_tax, total_without_tax, tax_amount, tax_percentage, item_name, buyer_name"
V_OK="1000000, 909091, 90909, 10, 'x', 'y'"

echo
echo "constraints"
TOTALS=invoices_totals_add_up
TRACE=invoices_issued_is_traceable
SKIPR=invoices_skip_reason_shape
VOCAB=invoices_tax_percentage_vocabulary
ZERO=invoices_zero_rate_zero_tax
EXT=invoices_external_is_not_queued

ins "a well-formed pending row is accepted"             accept  "$BASE" "$V_OK"
ins "totals that do not re-add are rejected"            "$TOTALS" "$BASE" "1000000, 909091, 1, 10, 'x', 'y'"
ins "status=issued with NO identifier is rejected"      "$TRACE"  "$BASE, status" "$V_OK, 'issued'"
ins "status=issued with an invoice number is accepted"  accept  "$BASE, status, invoice_no" "$V_OK, 'issued', 'K26TAA1'"
ins "status=issued with only a mã tra cứu is accepted"  accept  "$BASE, status, reservation_code" "$V_OK, 'issued', 'ABC123'"
ins "skipped with an empty reason is rejected"          "$SKIPR"  "$BASE, status, skip_reason" "$V_OK, 'skipped', ''"
ins "skipped with a whitespace reason is rejected"      "$SKIPR"  "$BASE, status, skip_reason" "$V_OK, 'skipped', '   '"
ins "skipped with a real reason is accepted"            accept  "$BASE, status, skip_reason" "$V_OK, 'skipped', 'zero amount'"
ins "a non-skipped row may not carry a skip reason"     "$SKIPR"  "$BASE, skip_reason" "$V_OK, 'why'"
ins "tax rate -1 (KCT) is accepted"                     accept  "$BASE" "1000000, 1000000, 0, -1, 'x', 'y'"
ins "tax rate -2 (KKKNT) is accepted"                   accept  "$BASE" "1000000, 1000000, 0, -2, 'x', 'y'"
ins "tax rate -1.5 is REJECTED (not a code, not a rate)" "$VOCAB" "$BASE" "1000000, 1000000, 0, -1.5, 'x', 'y'"
ins "tax rate -3 is rejected"                           "$VOCAB"  "$BASE" "1000000, 1000000, 0, -3, 'x', 'y'"
ins "tax rate 101 is rejected"                          "$VOCAB"  "$BASE" "1000000, 909091, 90909, 101, 'x', 'y'"
ins "tax rate 5.5 is accepted"                          accept  "$BASE" "1000000, 947867, 52133, 5.5, 'x', 'y'"
ins "a negative amount is rejected"                     invoices_total_with_tax_check "$BASE" "-1, -1, 0, 10, 'x', 'y'"
ins "an unknown status is rejected"                     invoices_status_check "$BASE, status" "$V_OK, 'nearly_issued'"
ins "an unknown origin is rejected"                     invoices_origin_check "$BASE, origin" "$V_OK, 'guesswork'"

# A rate that levies no tax must carry no tax — all three spellings of it.
ins "KCT carrying real tax is rejected"                 "$ZERO" "$BASE" "1000000, 909091, 90909, -1, 'x', 'y'"
ins "KKKNT carrying real tax is rejected"               "$ZERO" "$BASE" "1000000, 909091, 90909, -2, 'x', 'y'"
ins "0% carrying real tax is rejected"                   "$ZERO" "$BASE" "1000000, 909091, 90909, 0, 'x', 'y'"
ins "0% with no tax is accepted"                         accept "$BASE" "1000000, 1000000, 0, 0, 'x', 'y'"

# An externally-recorded invoice must never sit in a dispatchable state.
ins "external + pending is rejected"                    "$EXT" "$BASE, origin, status" "$V_OK, 'external', 'pending'"
ins "external + failed is rejected"                     "$EXT" "$BASE, origin, status" "$V_OK, 'external', 'failed'"
ins "external + in_flight is rejected"                  "$EXT" "$BASE, origin, status" "$V_OK, 'external', 'in_flight'"
ins "external + issued is accepted"                     accept "$BASE, origin, status, invoice_no" "$V_OK, 'external', 'issued', 'K26TAA9'"
ins "auto + pending is still accepted"                  accept "$BASE, origin, status" "$V_OK, 'auto', 'pending'"

echo
echo "columns and indexes"
t=$(q -c "SELECT data_type FROM information_schema.columns
          WHERE table_name='invoices' AND column_name='request_payload'")
if [ "$t" = "text" ]; then
  ok "request_payload is TEXT, so it can hold the bytes that were sent"
else
  bad "request_payload is TEXT" "got [$t] — JSONB re-serialises and loses byte identity"
fi
t=$(q -c "SELECT data_type FROM information_schema.columns
          WHERE table_name='invoices' AND column_name='response_payload'")
if [ "$t" = "jsonb" ]; then ok "response_payload is JSONB"; else bad "response_payload is JSONB" "got [$t]"; fi

t=$(q -c "SELECT count(*) FROM pg_indexes WHERE tablename='invoices'")
if [ "${t:-0}" -ge 4 ]; then ok "the invoices indexes were created ($t)"; else bad "invoices indexes" "got $t"; fi
t=$(q -c "SELECT count(*) FROM pg_indexes WHERE tablename='payments' AND indexname LIKE 'idx_payments_%'")
if [ "${t:-0}" -eq 2 ]; then ok "both payments sweep indexes were created"; else bad "payments sweep indexes" "got $t"; fi

# The whole cross-replica race guard, in one assertion.
q -c "INSERT INTO invoices (payment_id, $BASE) VALUES ($PAYMENT, $V_OK)" >/dev/null
res=$(q -c "INSERT INTO invoices (payment_id, $BASE) VALUES ($PAYMENT, $V_OK)")
case "$res" in
  *duplicate*key* | *unique*) ok "a second invoice for the same payment is refused" ;;
  *) bad "a second invoice for the same payment is refused" "got [${res:-ACCEPTED — two tax filings for one sale}]" ;;
esac

# --- self-check -------------------------------------------------------------
# Three statements that Postgres rejects for reasons that have NOTHING to do with
# any constraint. Against the previous helper all three scored as passes; each
# must now be reported as a failure, or this suite is measuring psql's opinion of
# its own SQL rather than the schema.
if [ "${1:-}" = "--self-check" ]; then
  echo
  echo "self-check: three malformed statements MUST NOT count as constraint rejections"
  before=$fail
  ins "SELF-CHECK value-count mismatch"  "$SKIPR" "$BASE, status" "$V_OK, 'skipped', ''"
  ins "SELF-CHECK nonexistent column"    "$TOTALS" "$BASE, no_such_column" "$V_OK, 'x'"
  ins "SELF-CHECK syntax error"          "$TOTALS" "$BASE" "$V_OK,,,"
  broke=$((fail - before))
  if [ "$broke" -eq 3 ]; then
    echo "  self-check: all 3 malformed statements were caught"
    fail=$before
    pass=$((pass + 3))
  else
    echo "  self-check: only $broke of 3 were caught — THE SUITE IS NOT BINDING"
    fail=$((before + 1))
  fi
fi

echo
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
