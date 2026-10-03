# VAT arithmetic for an invoice line

The whole contract: **`without_tax + tax == the gross the buyer actually paid`**,
exactly, in đồng. Everything else follows from it, and a database CHECK should
enforce it so a rounding bug cannot reach the vendor.

## The rate vocabulary

Viettel's rates are not all numbers:

| Value               | Meaning                                                          |
| ------------------- | ---------------------------------------------------------------- |
| `10`, `8`, `5`, `0` | ordinary VAT rates, as percentages                               |
| `-1`                | **KCT** — không chịu thuế GTGT (not subject to VAT)              |
| `-2`                | **KKKNT** — không kê khai nộp thuế (no VAT declaration required) |

The two negatives are **codes, not rates**. Arithmetically they behave like 0%,
but they are legally distinct on the filing, so carry them through as themselves
and never normalise them to zero. That has two consequences:

- the stored column must be **signed** and have decimals — `NUMERIC(5,2)`, because
  5.5% exists and an unsigned integer erases both the decimals and the codes;
- the rate the caller passed in is what gets recorded, even when the tax it
  produced is 0.

Rates are per item type and belong in configuration (`{"course":10,"ip_fee":8}`
with a default), agreed with an accountant — never hardcoded, and never derived
from a price.

## Always decompose from the gross

The input is the money actually collected. There is no tax-exclusive mode: an
invoice must reconcile to the cash received, and even where a business quotes
prices excluding VAT, checkout charges price + VAT, so the recorded amount is
still the gross.

```
net = round_half_up(gross * 10000 / (10000 + rate*100))
tax = gross - net                       ← the REMAINDER, never a second rounding
```

Two choices in there are load-bearing.

**The division rounds half up, in integer arithmetic.** The obvious
`int64(float64(amount) / (1 + rate/100))` **truncates**, landing a đồng low on
about half of ordinary VND amounts — measured here, 101 of 208 sample values
across 5% / 8% / 10% / 5.5% — and each of those is a rejected invoice. Integer
arithmetic is then chosen over a rounded float because it is exactly auditable:
a correctly rounded float happens to agree across the whole realistic range, but
"happens to agree" is not a property to rest a tax filing on.

**Tax is the remainder.** Compute one side and subtract; never round both sides
independently. Rounding both with truncation breaks the sum constantly (the same
measurement above). Rounding both half-up happens to reconcile at the rates in
use — for `net` and `tax` to both round up, both fractional parts would have to
be exactly ½, which the arithmetic of 5 / 8 / 10 / 5.5% never produces — but that
is a property of those particular denominators, not of the method, and it stops
being true as soon as someone adds a rate. Subtraction cannot break at any rate,
which is why the invariant is expressed that way rather than checked.

Scale of 10 000 = 100% in hundredths of a percent, so a `NUMERIC(5,2)` rate such
as `5.50` is handled without leaving integers.

```go
func SplitVAT(amountWithTax int64, ratePercent float64) (VATSplit, error) {
    if amountWithTax < 0 { return VATSplit{}, fmt.Errorf("negative amount %d", amountWithTax) }
    if amountWithTax > maxSafeAmount { return VATSplit{}, fmt.Errorf("amount %d exceeds the safe limit", amountWithTax) }
    // A negative value is a CODE, and only two exist. A range check alone admits
    // -1.5: arithmetically zero tax, comfortably inside NUMERIC(5,2), and
    // meaningless on a filing. Check the vocabulary, not the interval.
    if math.IsNaN(ratePercent) || ratePercent > 100 ||
        (ratePercent < 0 && ratePercent != RateKCT && ratePercent != RateKKKNT) {
        return VATSplit{}, fmt.Errorf("tax rate %v is not a rate this vendor accepts", ratePercent)
    }
    // KCT / KKKNT / 0% all put the whole amount in the net column. The CALLER
    // still records the rate it passed, so the three stay distinguishable.
    if ratePercent <= 0 {
        return VATSplit{WithoutTax: amountWithTax, Tax: 0}, nil
    }
    // math.Round before the cast: 5.5 is not exactly representable, and a bare
    // truncation of 5.5*100 could silently become 549.
    rateScaled := int64(math.Round(ratePercent * 100))
    denom := 10000 + rateScaled
    without := (amountWithTax*10000 + denom/2) / denom
    if without > amountWithTax { without = amountWithTax } // unreachable; the contract must hold anyway
    return VATSplit{WithoutTax: without, Tax: amountWithTax - without}, nil
}
```

## The overflow bound

`maxSafeAmount` must account for the **rounding addition**, not only the
multiplication:

```go
maxDenom      = 10000 + 100*100
maxSafeAmount = (math.MaxInt64 - maxDenom/2) / 10000
```

A bound of `MaxInt64/scale` admits an amount whose `amount*scale` fits but whose
`+ denom/2` then wraps — at rate 100 that returns a **negative** net, silently
violating the one contract the function has. It can only fire on corrupt input:
real VND amounts here are millions, twelve orders of magnitude below the limit.
That is exactly when returning an error beats returning a wrapped number.

## What the invoice carries

For a single-line invoice at rate `r` on gross `G` with net `N` and tax `T`:

| Block           | Field                                                     | Value            |
| --------------- | --------------------------------------------------------- | ---------------- |
| `itemInfo[0]`   | `unitPrice`, `itemTotalAmountWithoutTax`                  | `N` (quantity 1) |
|                 | `itemTotalAmountWithTax`                                  | `G`              |
|                 | `taxPercentage`, `taxAmount`                              | `r`, `T`         |
| `summarizeInfo` | `sumOfTotalLineAmountWithoutTax`, `totalAmountWithoutTax` | `N`              |
|                 | `totalTaxAmount`                                          | `T`              |
|                 | `totalAmountWithTax`                                      | `G`              |
|                 | `discountAmount`                                          | `0`              |
| `taxBreakdowns` | `taxPercentage`, `taxableAmount`, `taxAmount`             | `r`, `N`, `T`    |

With more than one rate on an invoice, `taxBreakdowns` carries one entry per
distinct rate and the `summarizeInfo` totals are the sums.

Let Viettel recompute all of it — do **not** send `validation: 0`. Their
recomputation is a free assertion that your arithmetic agrees with the
authority's.

## Worked examples

| Gross     | Rate | Net       | Tax     | What truncation would have produced             |
| --------- | ---- | --------- | ------- | ----------------------------------------------- |
| 100 000   | 10   | 90 909    | 9 091   | the same — this one is safe either way          |
| 99 999    | 8    | 92 592    | 7 407   | 92 591: a đồng low, rejected                    |
| 1 500 000 | 8    | 1 388 889 | 111 111 | 1 388 888: a đồng low, rejected                 |
| 500 000   | 5.5  | 473 934   | 26 066  | 473 933: decimals survive only the integer path |
| 250 000   | -1   | 250 000   | 0       | KCT: the whole amount is net, rate stays -1     |

Turn each of these into a test, plus: a zero gross, the maximum safe amount, one
đồng above it, `NaN`, rate 100, rate 101, rate -3 — and **rate -1.5**, which is
the one a plain range check lets through.

The database has to carry the same vocabulary, or the check only holds for rows
this code wrote: see `invoices_tax_percentage_vocabulary` in
`../templates/invoices.sql`.
