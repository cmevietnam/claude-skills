---
name: vinvoice
description: Issue Vietnamese e-invoices through Viettel S-Invoice / vInvoice (hóa đơn điện tử, TT78) from an application. Use when integrating the Viettel invoice API, when a createInvoice call is rejected or times out, when a payment must produce a tax invoice, when deciding what to retry after a vendor error, when computing VAT for an invoice line, or when a mẫu số / ký hiệu / mã tra cứu / transactionUuid needs explaining.
---

# Issuing hóa đơn điện tử through Viettel

An invoice here is not an API record. It is a document filed with the cơ quan
thuế the moment the vendor accepts it, and the platform's copy is the only thing
that knows it exists. That single fact decides every design choice below: a
duplicate is a filing to unwind with the tax authority, not a row to delete.

Start with `vinvoice check` (in this plugin's `bin/`). It proves the base URL,
the credentials, the source-IP whitelist and the registered mẫu số / ký hiệu in
one read-only call, and each of those fails disguised as one of the others.

## The rule that matters most

**An ambiguous outcome is not a failure. Never retry it.**

A timeout, a 5xx, a connection reset, an unparseable 200 — each means Viettel
_may_ hold an invoice you have no record of. Viettel's behaviour on a repeated
`transactionUuid` is undocumented, so a retry can file a second real invoice.
Park those for a human; retry only what is _provably_ not filed.

Only two _transport_ failures prove nothing was received. Beyond them, what makes
an outcome definite is **the vendor's own `errorCode`, at any status** — a
business rejection comes back on a 200 as readily as on a 4xx, and a bare 4xx
with no `errorCode` came from a middlebox that does not know what the vendor did
with the request. Everything else is not definite:

| Outcome                                | Verdict                                     |
| -------------------------------------- | ------------------------------------------- |
| connection refused                     | definite — nothing accepted the bytes       |
| DNS failure                            | definite — no connection was ever attempted |
| any status carrying a vendor `errorCode` | definite — the vendor rejected it in its own words |
| **everything else, including any 5xx and any bare 4xx** | **ambiguous — stop, do not retry** |

The asymmetry is deliberate: a needless review costs an operator a minute, and
the other mistake costs a filing to unwind. Getting this backwards — treating
only timeouts as ambiguous — is the most expensive mistake in this integration,
because an HTTP client returns a _plain_ error for a reset that happened after
the vendor already processed the request.

Recovery is now cheap and must be used before any manual decision:
`searchInvoiceByTransactionUuid` asks Viettel whether the invoice exists. The
vendor's own spec calls that endpoint **bắt buộc** for exactly this reason.
`vinvoice lookup <uuid>` is that call.

## The four traps

1. **A 500 saying `Request Fail` is your IP, not their outage.** Viettel
   whitelists source addresses per account. Every call from an unregistered
   address fails this way. Register the _egress_ address the application
   actually leaves from — a proxy or NAT gateway, not the pod.
2. **Two vendor documents disagree, and only one is the API.** The web-portal
   user manual carries an "Ánh xạ API" table naming the portal's own UI and
   column names: `invoiceSeri`, `buyerAddress`, `buyerViewStatus`. The API wants
   `invoiceSeries`, `buyerAddressLine`, `buyerNotGetInvoice`. When they
   disagree, the **webservice specification wins**.
3. **The cancel endpoint is retired** ("Đã bỏ từ 1/6"). Under TT78 an invoice is
   voided by _issuing_ a hóa đơn xóa bỏ (`adjustmentType: 7`), not by calling a
   cancel API. Do not guess that flow's shape; confirm it on the sandbox.
4. **`invoiceIssuedDate` is epoch milliseconds.** Seconds date every invoice to
   1970 — a difference only the tax authority notices.

## The shape that works

One row per payment, in a table that is also the delivery queue:

- **A reconciler sweeps settled payments**; call sites never enqueue. Eight code
  paths mark a payment paid today and there will be more, and a missed one is a
  silently missing tax invoice.
- **`payment_id` is UNIQUE.** That constraint, not application logic, is what
  stops two replicas issuing two invoices for one sale.
- **Money, tax rate and buyer identity are frozen at enqueue time.** An invoice
  must keep reporting what was true when it was filed, so nothing is re-derived
  from the payment or the user afterwards.
- **The `transactionUuid` is derived from the row id**, never from a clock or a
  random source, so a retry is recognisable to the vendor as the same request.
- **Build the payload once, store it, then send those exact bytes.** For a row
  that ends up needing review, it is the only record of what was asked for — so
  store it in a column that keeps bytes (`TEXT`), not one that re-serialises them
  (`JSONB` sorts keys and drops whitespace).
- **Fence every result write on a claim sequence** that nothing resets — not on
  the attempt count, which an operator's retry sets back to zero.

Details, with the failure each rule prevents: `references/pipeline.md`.

## Do not

- Retry an ambiguous outcome. (Read that table again; it is the whole feature.)
- Send `validation: 0`. It makes Viettel accept your totals verbatim instead of
  recomputing them, discarding a free check that your arithmetic matches theirs.
- Compute VAT by rounding both parts. Tax is the **remainder**, or the two sides
  disagree by a đồng and the invoice is rejected mid-sale — see
  `references/vat.md`.
- Normalise a negative tax rate to zero. `-1` (KCT) and `-2` (KKKNT) are codes,
  not rates, and they are legally distinct from 0% on the filing.
- Pin the vendor's TLS certificate. The exported `GlobalSign …pem` in their doc
  pack is a public intermediate that every trust store already has; pinning it
  buys nothing and expires in 2028.
- Treat a 2xx with no invoice number, transaction id or mã tra cứu as success.
  It is an unknown outcome wearing a success code.
- Write a vendor response into a JSONB column without making it valid JSON
  first. The column type is right; passing the body through unchecked is not.
  Their failure bodies are plain text and an intermediary's are HTML, so the
  write fails, the row stays claimable, and the ambiguity guard is defeated from
  behind. Wrap anything unparseable as a JSON string.
- Ship it live on day one. The feature belongs behind a flag with a go-live
  timestamp, or the first deploy back-dates an invoice for every payment the
  platform ever took.

## References

| File                            | What is in it                                                              |
| ------------------------------- | -------------------------------------------------------------------------- |
| `references/api-contract.md`    | hosts, auth, every endpoint, the createInvoice payload field by field      |
| `references/pipeline.md`        | the queue, the state machine, claim fencing, ambiguity classification      |
| `references/vat.md`             | rate vocabulary and the arithmetic that reconciles to the đồng             |
| `references/operations.md`      | configuration, IP whitelisting, shipping dark, go-live, the operator queue |
| `references/testing.md`         | how to test all of it without ever calling the vendor                      |
| `templates/invoices.sql`        | the table, its constraints and its indexes                                 |
| `templates/create-invoice.json` | an annotated createInvoice body                                            |
| `templates/env.example`         | the configuration surface                                                  |

## The CLI

```bash
vinvoice check                     # configuration + one read-only call that proves it all
vinvoice templates                 # the mẫu số / ký hiệu registered for this tax code
vinvoice lookup <transactionUuid>  # does the vendor hold this invoice? (the recovery call)
vinvoice search --from D --to D    # invoices in a period (UTC+7)
vinvoice file <invoiceNo>          # fetch the document
vinvoice egress-ip                 # the address to register on the account
```

It is read-only on purpose. Issuing, replacing, adjusting and voiding are
refused: they need the frozen snapshot and the deterministic uuid that only the
application has.
