# Running it

## Configuration

The names below are the reference set; `../templates/env.example` is the same
list ready to copy.

| Variable                            | Notes                                                         |
| ----------------------------------- | ------------------------------------------------------------- |
| `VIETTEL_INVOICE_ENABLED`           | the dark switch. Default **false**                            |
| `VIETTEL_INVOICE_BASE_URL`          | must end at `/InvoiceAPI`; https only                         |
| `VIETTEL_INVOICE_AUTH_MODE`         | `basic` (implemented) \| `token` (reject at boot until wired) |
| `VIETTEL_INVOICE_USERNAME`          | the supplier tax code, branch suffix included                 |
| `VIETTEL_INVOICE_PASSWORD`          | secret                                                        |
| `VIETTEL_INVOICE_SUPPLIER_TAX_CODE` | path parameter on createInvoice; also a form field elsewhere  |
| `VIETTEL_INVOICE_TEMPLATE_CODE`     | mẫu số, e.g. `1/001`                                          |
| `VIETTEL_INVOICE_SERIAL`            | ký hiệu, e.g. `C26TAA`                                        |
| `VIETTEL_INVOICE_TAX_RATES`         | JSON `item_type → rate`; negative values are KCT/KKKNT        |
| `VIETTEL_INVOICE_DEFAULT_TAX_RATE`  | for an item type not in the map                               |
| `VIETTEL_INVOICE_START_AT`          | RFC3339 go-live floor. **Required when enabled**              |
| `VIETTEL_INVOICE_SKIP_ZERO_AMOUNT`  | default true                                                  |
| `VIETTEL_INVOICE_TIMEOUT_SECONDS`   | default 20, bounded                                           |

Validate the whole block **at boot, and only when the feature is enabled**, so a
half-filled Secret fails the deploy rather than failing every invoice later. A
missing template code or ký hiệu is rejected by the vendor on every single call —
there is no reason to discover that one invoice at a time.

Three details that are easy to get wrong:

- **Parse the tax-rate map unconditionally**, even while the feature is dark. If
  parsing is skipped when disabled, an invalid map silently resolves every item
  type to the default rate the moment someone flips the switch. Parse always; log
  loudly and continue while dark; refuse to boot when enabled.
- **`AUTH_MODE=token` should fail validation** until the token endpoint is
  actually wired from the vendor's integration document. A guessed path fails
  every call with an error indistinguishable from a bad password.
- **`START_AT` is the value nothing else can protect you from.** Validation can
  check that it exists and parses; it cannot know that a date in the past
  back-dates a real invoice for every payment settled after it.

## The source-IP whitelist

Viettel whitelists source addresses per account, and answers a caller from an
unregistered address with a **500 whose body is the plain text `Request Fail`** —
indistinguishable from a vendor outage.

- Register the address the application **actually egresses from**: the NAT
  gateway, the forward proxy, the load balancer's egress IP — not the pod's
  address and not the laptop that ran the first test.
- If the platform already runs an egress proxy for another vendor, route this
  client through the same one and give it its own credential.
- `vinvoice egress-ip` reports what the machine running it egresses as. From
  inside the cluster, run the equivalent from a pod on the same egress path; the
  answer from a developer laptop is a different address entirely.
- Because a 500 is classified **ambiguous**, an unregistered IP does not spin the
  retry loop — it parks every invoice in `needs_review`. That is the safe
  behaviour, and it is also why a whole day's invoices can pile up quietly
  waiting for a human. Alert on the queue depth.

## Shipping dark

Enable the schema and the code well before the first invoice, with
`VIETTEL_INVOICE_ENABLED=false` making both loops complete no-ops. Then:

**Every settled payment continues to accumulate as an unissued tax obligation
while it is off.** The queue drains when the switch flips — which is the point,
and also the risk. Write it down where the operator will see it, not only in a
commit message.

Go-live order:

1. An egress path whose address is registered with Viettel.
2. Credentials in the secret store; `vinvoice check` green **from that egress
   path**.
3. Tax rates agreed with the accountant, in `VIETTEL_INVOICE_TAX_RATES`.
4. `VIETTEL_INVOICE_START_AT` set to the agreed moment — not to "now", and never
   to the epoch.
5. Flip `VIETTEL_INVOICE_ENABLED=true` and watch the first batch by hand.

Pre-integration history is cleared separately: an invoice raised by hand on the
portal is recorded as `origin='external'`, which is never dispatched.

## The operator queue

`needs_review` and `dead_letter` rows are only safe if someone can act on them.
The admin surface needs, per row: the payment, the frozen amounts and buyer, the
exact request bytes, the exact response bytes, the vendor's error text, and two
actions:

- **Retry** — resets `attempts` and sets `pending`. Only ever a human decision on
  a `needs_review` row, and only after checking the Viettel portal.
- **Record as issued** — for an invoice confirmed to exist on the vendor's side.

The check before either is always the same, and it is now one command:

```bash
vinvoice lookup <transactionUuid>     # does Viettel already hold this invoice?
```

Identifiers coming back — an invoice number, a mã tra cứu, a transaction id —
mean the create landed: record it as issued.

**A lookup that finds nothing is not permission to retry.** It is one more piece
of evidence, and a weaker one than it looks: an empty result can also mean the
uuid was never indexed under the name you searched, that the invoice landed on a
different tax code or branch suffix, or simply that the vendor's search lags its
own writes. Retrying on that alone is how the duplicate this whole design exists
to prevent gets filed by hand, by an operator following a runbook.

Only two answers authorise a retry:

- **the vendor said no** — `errorCode` set on the original create, which is a
  definite rejection with its own text; or
- **you have checked the portal** for the period and the ký hiệu and the invoice
  is not there.

Otherwise, leave the row parked and ask Viettel, quoting the transaction id. An
invoice that stays parked costs one unhappy buyer and a phone call. The other
mistake is a filing to unwind with the cơ quan thuế.

## Rolling back

**Dropping the invoices table is irreversibly lossy in a way most rollbacks are
not.** It is the only record of which payments have been reported to the cơ quan
thuế. Dropping it does not cancel those invoices — they remain filed and legally
live on the vendor's side — it makes this system forget they exist. Re-applying
the migration gives an empty table, and the reconciler will then happily issue a
**second** invoice for every payment after `START_AT`.

So the supported rollback is **image-only**: roll the deployment back and leave
the schema in place. Nothing before the migration reads the table. If the table
must really go, export it first:

```
\copy invoices TO 'invoices-backup.csv' WITH CSV HEADER
```

and drop the partial indexes the migration added to the payments table too —
they belong to a table it does not own, and leaving them keeps charging the
settle-UPDATE write cost for a feature that is gone.

## Secrets

The password is a credential for filing tax documents. Keep it in the platform's
secret store, out of the repository, and out of process arguments — `vinvoice`
passes it to curl through a config file on stdin for exactly that reason, and
`vinvoice env` prints only its length. Never paste a vendor response containing
credentials into a ticket.

The demo account shipped inside the vendor's Postman collection is a shared
sandbox credential: use it from the collection, do not copy it into a repo.
