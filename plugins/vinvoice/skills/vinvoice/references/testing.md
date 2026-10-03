# Testing it without ever calling the vendor

You cannot test this feature by issuing invoices. Every successful test would be
a real document filed with the cơ quan thuế. So the seams have to carry the
whole load, and the tests have to be adversarial: the interesting cases are all
failures, and most of them are failures that _look_ like something else.

## The two seams

1. **The client interface**, defined in terms of your own frozen row rather than
   the vendor's wire format. The worker's tests then substitute a client that
   returns a chosen outcome — including `ErrAmbiguous` — with no HTTP at all.
2. **The store interface**, narrow, so every branch of the worker runs without a
   database. Keep it narrow on purpose: one fat interface lets a method added for
   the worker silently widen what the reconciler can reach.

Behind those, two more layers that must be tested for real:

- the **SQL** — claim/fence/reap semantics only exist in Postgres. Test them
  against a real database, concurrently.
- the **payload bytes** — a golden test that pins the exact JSON, so a rename
  from a document that turns out to be the portal manual shows up as a diff.

## The cases that must exist

Every one of these came from something that actually broke.

**Classification**

- A timeout → ambiguous, parked, **not** retried.
- A 5xx → ambiguous. Assert the row's status, not just the error text.
- A connection reset that is _not_ a timeout → ambiguous. (The bug this catches:
  treating only timeouts as ambiguous.)
- Connection refused, DNS failure → definite, retried.
- 401/403 → definite, and the message mentions IP whitelisting.
- A 2xx whose body will not parse → ambiguous.
- A 2xx with `errorCode` → definite rejection carrying the vendor's text.
- **A 2xx with no invoiceNo, transactionID or reservationCode → ambiguous, never
  `issued`.**
- A plain-text `Request Fail` body and an HTML 502 body → both storable in the
  response column; assert the row was written, because the failure mode is a
  failed write that leaves the row claimable.

**Concurrency and fencing**

- Two workers claiming the same batch → each row goes to exactly one.
- A result write from a stale claim (`claim_seq` behind) → rejected, and the
  rejection is _reported_, not swallowed.
- An operator retry resetting `attempts` while a stalled worker holds the row →
  the stalled write still does not match.
- A reap of an `in_flight` row **with** a stored payload → `needs_review`;
  **without** one → `failed`. Both, or the discriminator is untested.
- The claim UPDATE clears `request_payload` → assert it, or the second attempt
  onward misclassifies every crash.
- Cancellation of the context mid-dispatch → the result is still recorded.

**Enqueue**

- Two reconcilers inserting for one payment → one row, one unique violation
  handled.
- A zero-amount payment → a terminal `skipped` row, not a filter.
- A payment refunded between the sweep and the send → withheld, not issued.
- A payment settled before `START_AT` → never enqueued.
- `origin='external'` → never dispatched, even after an operator retry.

**Arithmetic** — see `vat.md` for the values; the rejections (`NaN`, out-of-range
rate, negative amount, over the safe bound) matter as much as the sums.

## Assertion discipline

A green suite proves only what it tested. Three rules, each of which has hidden a
real bug in this kind of code:

**Silence is never a pass.** An assertion phrased as an absence ("the output does
not contain the error") cannot tell a passing run from a run that never happened.
Demand a specific string that only appears when the code under test executed, and
treat empty output as a hard failure.

**Check the environment the suite needs is actually present.** A harness that
boots the real binary under six bad configs proved nothing when `timeout` was
missing on macOS: every invocation returned "command not found" with empty
stdout, and the negative assertions read that silence as success. It reported
`1 passed / 5 failed`, and the one pass was a harness that had run nothing.

**Confirm the check reaches the code it names.** In the same suite, config
loading died on an unrelated missing variable _before_ the validation under test
ran, so no case had ever exercised it. Assert a marker proving execution got past
the earlier stages.

And when a review lands a batch of findings, **prove the new tests go red**:
stage the pre-fix tree, run the new suite against it, and count the failures. A
suite written after the fix, never seen failing, proves the code passes its own
tests and nothing more.

## A local mock

For the HTTP layer, a `httptest`-style server that returns each of the
classification cases above is enough — and it is what makes the "does it retry?"
question answerable. Point `VIETTEL_INVOICE_BASE_URL` at
`http://localhost:PORT/InvoiceAPI`; validation should allow plain http on
loopback for exactly this, and nothing else.

The one thing a mock cannot tell you is what the real vendor does with a repeated
`transactionUuid`. That needs one sandbox experiment — send the same uuid twice,
then `vinvoice lookup <uuid>` and count the invoices — and until it is done, the
code must assume a retry duplicates.

## Before go-live

- `vinvoice check` green **from the production egress path**, not a laptop.
- `vinvoice templates` returns the exact mẫu số and ký hiệu that are configured.
- One invoice issued on the sandbox, then `vinvoice lookup` finds it by the uuid
  the application generated.
- The `needs_review` path exercised end to end, including the operator's retry.
- `START_AT` checked against the payments table: how many rows would the first
  tick pick up?
