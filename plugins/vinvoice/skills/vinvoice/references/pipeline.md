# The issuance pipeline

Language-neutral: the rules are about states and ordering, not about a framework.
The snippets are Go, from the reference implementation, where a snippet is
shorter than the sentence describing it.

## Where invoice rows come from

**A reconciler sweeps settled payments on a timer. Call sites never enqueue.**

The tempting design is to create the invoice where the payment is marked paid.
Do not: in a real codebase that place is not one place. A platform typically
settles payments from a webhook, an admin action, a wallet transfer, a voucher
redemption, a retry job — and every path added later that forgets to enqueue is a
tax invoice that is silently never filed.

```sql
-- the sweep: payments whose money moved, with no invoice row yet
SELECT … FROM payments p
WHERE p.status IN ('paid','refunded')
  AND p.paid_at >= $1                       -- the go-live floor, required
  AND NOT EXISTS (SELECT 1 FROM invoices i WHERE i.payment_id = p.id)
ORDER BY p.paid_at
LIMIT $2
```

Costs: nothing on the checkout write path, up to one tick of latency, and it
covers item types that do not exist yet. The index behind it must be partial and
its predicate must match this WHERE **in meaning**, or Postgres cannot use it —
`status IN ('paid','refunded')` does not imply `status = 'paid'`, and that
mismatch turned a 7.95 ms lookup into a 79 ms sequential scan once a minute in
every replica.

`since` — the go-live floor — is a required argument with no default. With a zero
value the first deploy back-dates a real invoice for every payment the platform
has ever taken.

## One table, both the record and the queue

They would always be 1:1, always be read together, and splitting them invites the
exact failure the design exists to prevent: a queue row without its record, or
two queue rows racing to issue one invoice.

**`payment_id UNIQUE` is the entire concurrency story.** Replicas each run their
own reconciler; without it, two pods sweeping in the same instant both see "no
row" and both insert. UNIQUE turns that race into one winner and one unique
violation the loser ignores. It also means one invoice per payment forever,
including after a cancellation — re-issuing is deliberately an operator action.

The full schema, with the reasoning attached to each column, is
`../templates/invoices.sql`.

### Freeze everything at enqueue time

Money, tax rate, tax percentage, item name, buyer name, tax code, address, email,
phone: all snapshot columns, never joins. An invoice must keep reporting what was
true when it was filed. Derive them at read time and an admin fixing a learner's
name — or an operator editing the tax-rate map — silently rewrites documents
already filed with the cơ quan thuế.

The same property is what makes a retry hours later send byte-identical content
to the first attempt, which is what makes any vendor-side duplicate detection
meaningful at all.

## The states

```
                 ┌── reconciler ──┐
                 ▼                ▼
  amount = 0 → skipped        pending ──claim──► in_flight ──ok──► issued
                                 ▲                   │
                       backoff   │                   ├─ definite error ──► failed ──(max attempts)──► dead_letter
                                 └───────────────────┤
                                                     └─ AMBIGUOUS ──────► needs_review   (never auto-retried)

  refund of an issued invoice → action='cancel', status='pending'
  refund of an undispatched row → retired (skipped/cancelled), never dispatched
```

| Status         | Meaning                                                              |
| -------------- | -------------------------------------------------------------------- |
| `pending`      | due for dispatch                                                     |
| `in_flight`    | claimed by a worker                                                  |
| `issued`       | the vendor returned an identifier — terminal                         |
| `failed`       | a definite rejection; retries on a backoff ladder                    |
| `needs_review` | **ambiguous** — a human decides; never picked up again automatically |
| `dead_letter`  | gave up after max attempts; visible in the operator queue            |
| `cancelled`    | voided                                                               |
| `skipped`      | must never be invoiced (amount 0) — terminal, and carries a reason   |

**`skipped` is a row, not a filter.** Excluding zero-amount payments in the
candidate query leaves them matching `NOT EXISTS` forever, so every tick
re-examines every free enrolment the platform has ever recorded. One insert
retires it permanently.

**`needs_review` is the whole point of the design.** See below.

## Claiming, and the fence

```sql
-- inside a transaction. On the pool, autocommit releases the row locks the
-- instant the query returns, which makes SKIP LOCKED useless and lets two
-- replicas dispatch the same invoice.
SELECT … FROM invoices i
WHERE i.status IN ('pending','failed')
  AND i.origin <> 'external'
  AND i.next_attempt_at <= NOW()
  AND (i.action <> 'issue' OR EXISTS (
        SELECT 1 FROM payments p WHERE p.id = i.payment_id AND p.status = 'paid'))
ORDER BY i.next_attempt_at, i.id
LIMIT $1
FOR UPDATE OF i SKIP LOCKED;

UPDATE invoices
SET status='in_flight', attempts = attempts + 1, claim_seq = claim_seq + 1,
    request_payload = NULL, updated_at = NOW()
WHERE id = $1
RETURNING attempts, claim_seq;
```

Four things in there are load-bearing:

1. **The SELECT and the UPDATE must commit together.** Own the transaction inside
   the claim function so no caller can split them.
2. **`origin <> 'external'`** withholds rows that record an invoice raised by hand
   on the portal. Dispatching one creates a second document for a sale that
   already has one.
3. **An `issue` row is withheld once its payment is no longer `paid`.** A `cancel`
   row is deliberately not, since a refunded payment is the reason it exists.
4. **`claim_seq` is not `attempts`.** Every result write is fenced on "this row is
   still the claim I was issued":

   ```sql
   UPDATE invoices SET … WHERE id = $1 AND status = 'in_flight' AND claim_seq = $2
   ```

   Using the attempt count for that fence is defeated by its own reset: a stalled
   worker holding attempt 1, a reaper release, an operator retry back to 0, and
   the next claim is attempt 1 again — so the stalled worker's write matches a
   claim that is not its own. `claim_seq` only ever increases and nothing resets
   it. `attempts` sizes the backoff ladder and decides `dead_letter`, and an
   operator's retry resets it on purpose.

**A fenced UPDATE that matches no row must be reported, never swallowed.** Zero
rows affected means the result was lost; returning success there makes the worker
log an outcome that never happened, and an operator chasing a missing invoice
finds no trace of the attempt.

## Dispatching one row

Order matters more than anything else in this function.

1. **Re-check that the payment is still payable**, immediately before sending.
   The claim query's status filter ran once for the whole batch, and this row may
   have waited behind nine vendor calls. A refund inside that window needs no
   crash and no race — it is an admin pressing a button — and sending anyway
   files a real invoice for money already returned, answerable only by a cancel
   endpoint the vendor has retired.
2. **Build the payload once and store it before sending.** For a row that ends in
   `needs_review` this is the only record of what the vendor was asked to create,
   and it is what an operator compares against the portal. It must be the same
   bytes, not an equivalent rebuild — a rebuild differs at least in its
   timestamp and, across midnight, in the calendar date on the document.
3. **If storing it fails, do not send.** "We may have filed something, contents
   unknown" is the one state with no recovery.
4. **If the claim was lost while building, abandon silently.** Another replica
   owns the row now; writing a failure would overwrite its work with a verdict
   from a stale attempt.
5. Send exactly those bytes, then classify.

```go
type Client interface {
    // Sends EXACTLY the payload bytes the caller obtained from BuildRequestPayload.
    CreateInvoice(ctx context.Context, row DispatchRow, payload []byte) (IssueResult, []byte, error)
    CancelInvoice(ctx context.Context, row DispatchRow) ([]byte, error)
    BuildRequestPayload(row DispatchRow) ([]byte, error)
}
```

Defining the interface in terms of your own frozen row, not the vendor's wire
format, is what lets the worker's tests run without a vendor at all.

## Classifying the outcome

This is the security-critical part. **Default to ambiguous.**

```go
// Only two failures are PROVABLY pre-transmission.
func isDefinitelyPreTransmission(err error) bool {
    if errors.Is(err, syscall.ECONNREFUSED) { return true }
    var dnsErr *net.DNSError
    return errors.As(err, &dnsErr)
}
```

An earlier revision of the reference implementation inverted this — only timeouts
were ambiguous, everything else "safe to retry" — which is wrong for the most
ordinary vendor failure there is: an HTTP client returns a plain, non-timeout
error for an EOF or a connection reset that happens **after** the request reached
the vendor and was processed. Retrying those files a duplicate.

| Signal                                         | Verdict       | Why                                                                        |
| ---------------------------------------------- | ------------- | -------------------------------------------------------------------------- |
| connection refused, DNS failure                | definite fail | nothing was ever delivered                                                 |
| any other transport error, incl. timeout       | **ambiguous** | the request may have been processed                                        |
| HTTP ≥ 500                                     | **ambiguous** | may be raised after the invoice was written; also the IP-whitelist answer  |
| HTTP 401 / 403                                 | definite fail | rejected at the door — but say "check credentials **and IP whitelisting**" |
| 4xx carrying a vendor `errorCode`              | definite fail | the vendor rejected it in its own words                                    |
| a bare 4xx with no vendor error (408, 429, an HTML page) | **ambiguous** | that answer came from a gateway, and a gateway does not know what the vendor did with the request |
| 2xx, body will not parse                       | **ambiguous** | the invoice may exist behind a response you don't understand               |
| 2xx, `errorCode` non-empty                     | definite fail | a business rejection                                                       |
| 2xx, no invoiceNo / transactionID / mã tra cứu | **ambiguous** | a terminal "issued" with nothing to look it up by is worse than a park     |

The 4xx split matters more than it looks. A rejection the **vendor** wrote is
proof it declined; a bare status from **something in between** — a 408 whose
request may well have been forwarded, a 429 from an edge proxy, an HTML error
page with a 4xx on it — proves only that you got an answer from a middlebox. The
test is not the status class, it is whether the body carries the vendor's own
`errorCode`.

That last row deserves its own warning. An earlier revision accepted it and wrote
`issued` with empty strings: a terminal state asserting a tax document exists,
with no identifier and no evidence it was created. Because terminal states are
excluded from every sweep, the sale would then be silently un-invoiced forever —
and a later automatic cancellation would send blank identifiers.

Cap what you read from the vendor (1 MiB is generous) — a 502 from an
intermediary can be a whole HTML page, and it gets stored.

## Recording the result

**Write the outcome on a context that cannot be cancelled.** Every one of these
writes happens after the vendor call has already gone out, so the outcome is
known and must be recorded — and the moment it matters most is exactly the moment
the parent context is dead:

```
SIGTERM → cancel() → the in-flight CreateInvoice returns context.Canceled
        → correctly classified AMBIGUOUS → MarkNeedsReview on the cancelled context
        → the driver refuses to execute → the row stays in_flight
        → the reaper releases it → the next tick SENDS IT AGAIN
```

A rolling deploy across three replicas makes that the ordinary case, not an edge
case.

```go
func recordCtx(ctx context.Context) (context.Context, context.CancelFunc) {
    return context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)
}
```

Also wait for the workers before the process exits.

**Make the vendor's response safe for its column.** If `response_payload` is
JSONB, a plain-text `Request Fail` or an HTML 502 will fail the write — which
leaves the row `in_flight`, which the reaper releases, which another worker sends
again, defeating the ambiguity guard through the very state that enforces it.
Store valid JSON as-is and wrap anything else as a JSON string, so the operator
still reads the vendor's exact words.

## The reaper

A pod that dies mid-dispatch leaves its row `in_flight`, where the claim query
cannot see it — without a reaper the invoice is silently never filed. Reap
**first** on every tick, before claiming.

And **split the reaped rows**, because a pod dying mid-dispatch is ambiguous by
definition:

```sql
UPDATE invoices
SET status = CASE WHEN request_payload IS NOT NULL THEN 'needs_review' ELSE 'failed' END,
    last_error = CASE WHEN request_payload IS NOT NULL
        THEN 'worker died after the request was sent — the invoice may exist; check the portal before retrying'
        ELSE 'in_flight timeout: worker crashed or restarted before sending' END,
    next_attempt_at = CASE WHEN request_payload IS NOT NULL
        THEN NOW() + INTERVAL '100 years' ELSE NOW() END,
    updated_at = NOW()
WHERE status = 'in_flight' AND updated_at < NOW() - $1::interval;
```

`request_payload` is a CONSERVATIVE discriminator, and it is worth being precise
about which way it errs. The worker refuses to dispatch unless the payload was
stored, so `payload absent` really does prove nothing was sent. The other
direction is one-sided: a pod that died between the store and the socket is
parked as possibly-filed even though nothing left the process. That costs an
operator one lookup. Calling it "exact" would invite someone to invert it later
and hand those rows back to the retry loop, which is the expensive mistake. Which is also why the claim UPDATE
must **clear** it: without that, from the second attempt onward a pod dying
_before_ sending is parked as `needs_review` carrying "died after the request was
sent", sending an operator to hunt the portal for a request that never left the
process.

Pushing the parked rows' `next_attempt_at` far into the future is a second belt:
no future code path can accidentally treat them as due.

## Backoff and giving up

Only **unambiguous** failures retry. 1-indexed on the post-increment attempt
count: `30s, 2m, 10m, 1h, 6h…`, and at `max_attempts` the row becomes
`dead_letter` rather than retrying forever. Both `dead_letter` and `needs_review`
belong in the operator queue; only `dead_letter` got there by exhausting a
ladder.

## Refunds

Two opposite answers, on the same sweep:

- **Already issued** → flip the row to `action='cancel', status='pending'`. It
  keeps its identity; no second row is created, which is what lets `payment_id`
  stay unconditionally UNIQUE.
- **Not yet dispatched** → retire it so it can never become a document.

Cancelling needs the vendor's own handle. A row that reached `issued` without an
invoice number or transaction id is a data problem: park it immediately rather
than burning every attempt on a call that cannot work.

⚠️ **This queues a call that is currently expected to fail, and that is the
deliberate choice — but do not ship it as if refunds work.** Viettel retired the
cancel endpoint, so every `cancel` row exhausts its ladder and lands in
`dead_letter` carrying the vendor's own words: contained, visible, never mistaken
for a successful void. What it does NOT do is void the invoice. Until the hóa đơn
xóa bỏ flow (`adjustmentType: 7`) is confirmed on the sandbox, a refund against an
issued invoice is a **manual** procedure on the portal, and the queue row is
there to make sure nobody forgets one. Guessing the replacement payload would be
worse than failing loudly. See `api-contract.md`.

## The operator surface

`needs_review` and `dead_letter` are only safe if a person can act on them.
The queue needs, per row: the payment, the frozen amounts, the exact request
bytes, the exact response bytes, the vendor's error text, and two actions —
**retry** (resets `attempts`, sets `pending`) and **record as issued** (for an
invoice the operator confirmed on the portal, or raised there by hand, which is
what `origin='external'` is for).

## A working implementation to read

The reference this was distilled from is the CME platform's `invoice` package
(Go + Postgres + pgx), where the pieces map one to one:

| Here                        | There                                                     |
| --------------------------- | --------------------------------------------------------- |
| the vendor client           | `api/internal/invoice/viettel_client.go`                   |
| the client/store interfaces | `api/internal/invoice/dispatch.go`                         |
| the worker and its states   | `api/internal/invoice/worker.go`                           |
| the sweep                   | `api/internal/invoice/reconciler.go`                       |
| the VAT arithmetic          | `api/internal/invoice/tax.go`                              |
| claim, fence, reap SQL      | `api/internal/repository/invoice_dispatch_repo.go`         |
| the schema                  | `api/db/migrations/130_create_invoices.up.sql`             |
| the vendor's own API notes   | `docs/viettel-einvoice-api-notes.md`                       |

Read it for the shape, not as a spec — this file is the spec, and it already
carries the corrections that implementation went through.
