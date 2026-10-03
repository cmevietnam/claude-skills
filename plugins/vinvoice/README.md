# vinvoice

Issue Vietnamese e-invoices through **Viettel S-Invoice / vInvoice** (hóa đơn
điện tử, TT78) from an application, without ever filing the same sale twice.

An invoice is not an API record: it is a document filed with the cơ quan thuế the
moment the vendor accepts it. A duplicate is a filing to unwind with the tax
authority, not a row to delete. This plugin carries the parts of that which are
not obvious — the verified field names, the outcomes that must never be retried,
and the arithmetic that has to reconcile to the đồng.

## Install

```bash
claude plugin marketplace add hieuvo/claude-skills
claude plugin install vinvoice@hieuvo-skills
```

Then, before writing any integration code:

```bash
vinvoice --env-file ./viettel.env check
```

`vinvoice` needs `curl`, plus `python3` for formatting. Nothing from Claude Code
— symlink `bin/vinvoice` onto `PATH` and use it as an ordinary tool; it resolves
the symlink to find its own libraries.

## What the CLI is for

One read-only call proves five things that each fail disguised as one of the
others: the base URL resolves and its path is right, TLS verifies, the
credentials are accepted, this machine's source IP is whitelisted on the account,
and the mẫu số / ký hiệu this project is configured with are among the ones the
account actually holds. `check` fails if the last one cannot be confirmed — a
wrong pair is otherwise rejected in production, one invoice at a time.

```bash
vinvoice check                     # all of the above, plus the configuration
vinvoice templates                 # the mẫu số / ký hiệu this tax code actually has
vinvoice lookup <transactionUuid>  # does the vendor already hold this invoice?
vinvoice search --from D --to D    # invoices in a period (UTC+7)
vinvoice file <invoiceNo>          # fetch the document
vinvoice egress-ip                 # the address to register with Viettel
vinvoice env                       # the resolved configuration, password masked
```

`vinvoice lookup` is the recovery tool. When a create times out, the question is
not "should I retry" — it is "does it already exist", and the vendor's own spec
calls this endpoint **bắt buộc** for exactly that reason.

Creating, replacing, adjusting and voiding are **refused**. Those file documents
with the tax authority, and they need the frozen snapshot and the deterministic
`transactionUuid` that only the application has. A CLI that could send one would
eventually send one by accident.

## The three things that cost the most

**A 500 saying `Request Fail` is your IP, not their outage.** Viettel whitelists
source addresses per account, and an unregistered caller gets a 500 that is
indistinguishable from a server error. Register the address the application
actually egresses from.

**Ambiguous is not failed.** A timeout, any 5xx, a connection reset, an
unparseable 200 — each means the invoice _may_ exist. Retrying files a second
real invoice. Only "connection refused" and "DNS failure" prove nothing was
received; everything else waits for a human. Getting this backwards is the most
expensive mistake available here.

**Two vendor documents disagree and only one is the API.** The web-portal manual
carries an "Ánh xạ API" table naming the portal's own columns — `invoiceSeri`,
`buyerAddress`, `buyerViewStatus` — where the API wants `invoiceSeries`,
`buyerAddressLine`, `buyerNotGetInvoice`. The webservice specification wins.

## Credentials, and the read-only guarantee

The password is a credential for filing tax documents. It reaches curl through a
config file on **stdin**, never as an argument, because an argument is visible in
`ps` to every other user on the machine for the life of the request — and `login`,
whose request body *is* the password, sends that body through the same config
rather than a temp file, so a SIGKILL cannot leave it on disk. `--env-file`
**parses** KEY=VALUE lines rather than sourcing them, so an `.env` holding invoice
credentials is never handed to the shell. `vinvoice env` prints the password's
length and nothing else, and a vendor response that echoes the password back is
redacted before it is printed.

"Read-only" is enforced in four places, because a refusal in the command
dispatcher is only as good as the layers under it, and two independent review
rounds each found a way through the layer above:

1. **`curl --disable` is the first argument**, so `~/.curlrc` cannot add options —
   or, through `next`, an entire second transfer — to any request this tool makes.
2. **The base URL is validated as a URL**: no line breaks, no quotes, no
   backslashes, no control characters, **no `%`, and no `?` or `#`**. The last
   three are not fussiness. `%63reateInvoice` reaches the server as
   `createInvoice` while sailing past a literal deny list, and
   `https://host/InvoiceWS/createInvoice?/InvoiceAPI` satisfies a naive
   "ends in /InvoiceAPI" check while POSTing to a write endpoint.
3. **No configuration value may contain a line break** — the URL, the username,
   the password and any request body alike. curl's config format is
   line-oriented, so one newline in a password turns into a `trace-ascii` that
   writes the Basic credential to disk.
4. **The rendered request is checked against a write-endpoint deny list**, case
   folded, before it is sent. `createInvoice`, `cancelTransactionInvoice`,
   `updatePaymentStatus` and the rest are refused with exit 90, and curl is never
   invoked.

`check` verifies the mẫu số and ký hiệu **as a pair**, not as two independent
values: an account holding `(1/001, C26TAA)` and `(2/002, C26TBB)` answers yes to
both halves of `1/001 + C26TBB`, a combination that does not exist and is
rejected on every invoice. Where the response shape does not pair them, it says
so rather than claiming the identity is proven — and when `python3` is missing it
reports that it *cannot tell*, instead of reporting the account as not holding
its own template.

## Tests

```bash
bash scripts/test-vinvoice.sh --self-check     # 162 assertions, no network
bash scripts/test-invoices-sql.sh --self-check #  36 assertions on a real Postgres
```

The CLI suite stubs `curl` on `PATH`, and the stub is created before the first
test that could reach one — after a guard that refuses to run at all if the temp
directory could not be made, since an empty path there would have turned the stub
into `/bin/curl`. stdout and stderr are captured separately so a test can prove
which stream something went to, and every behaviour test asserts an exit status.
`--self-check` breaks five assertions on purpose and fails the run unless all five
go red.

The schema suite starts a throwaway Postgres container and proves each constraint
rejects what it claims to reject. **Every rejection must name the constraint that
caused it**: an earlier revision scored any non-empty psql output as "rejected",
so a mistyped column name or a plain syntax error read as a passing test — three
deliberately malformed statements were fed to that version and all three went
green. Its `--self-check` re-runs exactly those three and fails unless all three
are now caught. It skips cleanly when docker or psql is missing.

Both suites have been run against deliberately reverted code, twice:

| Reverted to | CLI assertions red | Schema assertions red |
| ----------- | ------------------ | --------------------- |
| pre-review (round 1)  | 32 | 7 |
| post-round-1 (round 2) | 19 | 6, plus the self-check verdict |

## The skill

`skills/vinvoice/SKILL.md` is what Claude reads. The detail sits in
`references/`: the API contract field by field, the pipeline design with the
failure each rule prevents, the VAT arithmetic, operations and go-live, and how
to test all of it without calling the vendor. `templates/` holds the table, an
annotated createInvoice body, and the configuration surface.
