# The Viettel S-Invoice API contract

Everything here is taken from the vendor's own Postman collection and the
webservice specification, not from public write-ups, which contradict each other
on auth and on field names.

## Which document to believe

Vendors ship a folder of documents. Their authority is not equal:

1. **`Vinvoice API Collection postman.json`** — the vendor's own collection.
   Real hosts, real paths, real payloads, real auth. Highest authority: it is
   executable.
2. **`tailieu_mo_ta_webservice_hoadondientu_doitac_v2.xx`** (`.docx`) — the
   webservice specification. Per-field tables: type, required, constraints,
   enums. This is the API contract.
3. **`hdsd_web_dich_vu_hoa_don_...`** (`.doc`) — the **web portal user manual**.
   Hundreds of pages of UI walkthrough. **Not an API document.**

> ### Read this before using document 3
>
> It contains an "Ánh xạ API - bảng INVOICE" table that looks authoritative and
> is not: it maps UI labels to the **portal's own field and column names**.
> Applied to the API payload it produced three confidently-wrong renames:
>
> | Portal manual says | Actual API field         | What the portal name really is |
> | ------------------ | ------------------------ | ------------------------------ |
> | `invoiceSeri`      | **`invoiceSeries`**      | a field on the SEARCH requests |
> | `buyerAddress`     | **`buyerAddressLine`**   | a field of the search RESPONSE |
> | `buyerViewStatus`  | **`buyerNotGetInvoice`** | the portal's UI/DB column name |
>
> The same manual lists a different `selection` enum (1 = Thuế GTGT, …) that
> belongs to a CTT50 template screen. When 2 and 3 disagree, **2 wins**.

Re-extracting the documents: the Postman collection is plain JSON; a `.docx` is
a zip, so read `word/document.xml` and strip tags; a `.doc` is OLE2 — `textutil`
mangles it into tens of megabytes of binary noise, and a Word 97 piece-table
walk over the `1Table` stream is what works.

## Hosts

```
https://api-vinvoice.viettel.vn/services/einvoiceapplication/api/InvoiceAPI
```

The base URL must include everything up to and including `/InvoiceAPI`; every
path below is appended to it. A sandbox/demo host of the form
`https://demo-sinvoice.viettel.vn:8443/InvoiceAPI` is issued per account —
confirm yours with the vendor rather than assuming this one.

**`api-vinvoice` and `api-sinvoice` are not interchangeable.** Both resolve and
serve valid TLS. Probing the same path on each:

| Host                      | `POST …/InvoiceAPI/InvoiceWS/createInvoice/{taxCode}`                  |
| ------------------------- | ---------------------------------------------------------------------- |
| `api-vinvoice.viettel.vn` | **500** — the endpoint exists (500 is also the non-whitelisted answer) |
| `api-sinvoice.viettel.vn` | **404** — no such path                                                 |

All 27 requests in the vendor's collection use `api-vinvoice.viettel.vn`.

**Do not pin their certificate.** The `GlobalSign RSA OV SSL CA 2018.pem` that
ships in the doc pack is the public GlobalSign intermediate, issued by
GlobalSign Root CA - R3, which is in every standard trust store; the servers
send a complete chain and default verification accepts them. Pinning an
intermediate expires (2028-11-21) and breaks every invoice with a TLS error that
looks nothing like its cause.

## Authentication

**HTTP Basic**, with the supplier tax code as the username — the vendor's
collection sets it on every invoice endpoint. Public sources contradict each
other here; this settles it.

A token endpoint also exists, `POST https://api-vinvoice.viettel.vn/auth/login`
with `{username, password}`, and the spec accepts `Cookie: access_token` as an
alternative. Nothing in the vendor's own collection uses it for invoice calls.
If an account requires it, wire it from the vendor's integration document — do
not guess the header or the path, because a wrong guess fails every call with an
error indistinguishable from a bad password.

Supplier tax codes may carry a branch suffix: `0100109106-507`.

## Endpoints

`{base}` is the URL ending in `/InvoiceAPI`. Section numbers are the spec's.

| Purpose                               | Method + path                                                    | Body        |
| ------------------------------------- | ---------------------------------------------------------------- | ----------- |
| Login (5.5)                           | `POST https://<host>/auth/login`                                 | JSON        |
| **Create invoice (7.2)**              | `POST {base}/InvoiceWS/createInvoice/{supplierTaxCode}`          | JSON        |
| Get invoice file (7.3)                | `POST {base}/InvoiceUtilsWS/getInvoiceRepresentationFile`        | JSON        |
| Conversion invoice (7.5)              | `POST {base}/InvoiceWS/createExchangeInvoiceFile`                | form        |
| Custom fields (7.7)                   | `GET  {base}/InvoiceWS/getCustomFields?taxCode=&templateCode=`   | —           |
| Draft (7.8.1)                         | `POST {base}/InvoiceWS/createOrUpdateInvoiceDraft/{taxCode}`     | JSON        |
| Usage by range (7.11)                 | `POST {base}/InvoiceUtilsWS/getProvidesStatusUsingInvoice`       | JSON        |
| Batch create (7.12)                   | `POST {base}/InvoiceWS/createBatchInvoice/{taxCode}`             | JSON        |
| Send buyer email (7.14)               | `POST {base}/InvoiceUtilsWS/sendHtmlMailProcess`                 | JSON        |
| Update payment status (7.18)          | `POST {base}/InvoiceWS/updatePaymentStatus`                      | form        |
| Cancel payment status (7.19)          | `POST {base}/InvoiceWS/cancelPaymentStatus`                      | form        |
| Draft preview (7.20)                  | `POST {base}/InvoiceUtilsWS/createInvoiceDraftPreview/{taxCode}` | JSON        |
| **Look up by transactionUuid (7.21)** | `POST {base}/InvoiceWS/searchInvoiceByTransactionUuid`           | form        |
| Get MSBM (7.22)                       | `POST {base}/BotWS/getReservationCode/{taxCode}`                 | JSON        |
| Invoice usage stats (7.25)            | `GET  {base}/InvoiceWS/getInvoiceUsage`                          | —           |
| Explanation (7.26)                    | `PUT  {base}/InvoiceWS/update-explanation`                       | JSON        |
| Templates + serials (7.29)            | `POST {base}/InvoiceUtilsWS/getAllInvoiceTemplates`              | JSON        |
| Search by period, UTC+0 (7.35)        | `POST {base}/InvoiceUtilsWS/getAllInvoices/{taxCode}`            | JSON        |
| Re-send to CQT by uuid (7.36)         | `POST {base}/InvoiceWS/sendInvoiceByTransactionUuid`             | form        |
| **Search by period, UTC+7 (7.37)**    | `POST {base}/InvoiceUtilsWS/getInvoicesAll/{taxCode}`            | JSON        |
| ~~Cancel invoice~~                    | `POST {base}/InvoiceWS/cancelTransactionInvoice`                 | **RETIRED** |

The collection labels 7.22 "Lấy MSBM" while the path says `getReservationCode`.
Do not assume it returns the mã tra cứu that comes back on a create — it sits
under `BotWS` alongside `createInvoiceWithCode` ("phát hành hóa đơn có mã bí
mật"), so confirm what it actually yields before building on it.

USB-token signing (7.27) is a separate three-call flow
(`createInvoiceUsbTokenGetHash` → sign locally → `…InsertSignature`); it applies
only where the certificate lives on a hardware token rather than on Viettel's
side.

Two searches differ **only in timezone**: `getAllInvoices` is UTC+0 and
`getInvoicesAll` is UTC+7. Picking the wrong one shifts a day boundary by seven
hours, which at month end moves invoices between filing periods.

The vendor's non-JSON quirks: several endpoints are `form-urlencoded`, notably
the transactionUuid lookup. Sending JSON there returns a rejection that reads
like a bad parameter.

### Two bodies worth having verbatim

```jsonc
// 7.29 getAllInvoiceTemplates — the read-only call that proves auth + whitelist
{ "taxCode": "0100109106-507", "invoiceType": "all" }

// 7.37 getInvoicesAll (UTC+7)
{ "supplierTaxCode": "…", "startDate": "2026-09-01", "endDate": "2026-09-30",
  "rowPerPage": 20, "pageNum": 1, "invoiceNo": "K26TAA4" }
```

## The createInvoice payload

Top-level blocks: `generalInvoiceInfo`, `buyerInfo`, `payments`, `itemInfo`,
`taxBreakdowns`, `summarizeInfo`, `metadata`. (`sellerInfo` exists in the spec;
the vendor's own sample omits it.) A ready-to-edit body is in
`../templates/create-invoice.json`.

### generalInvoiceInfo

| Field                          | Notes                                                                                                                        |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| `invoiceType`                  | TT32 codes (`01GTKT`, …) **or** TT78 codes (`1`..`6`). Under TT78, VAT = **`"1"`**                                           |
| `templateCode`                 | mẫu số, e.g. `1/001`                                                                                                         |
| `invoiceSeries`                | ký hiệu. Required, max 25, `^[a-zA-Z0-9/]*$`                                                                                 |
| `currencyCode`, `exchangeRate` | `"VND"`, `1`                                                                                                                 |
| `adjustmentType`               | `1` gốc · `3` thay thế · `5` điều chỉnh thông tin · **`7` xóa bỏ** · `9` điều chỉnh tiền · `11` chiết khấu TM. Default `1`   |
| `paymentStatus`                | boolean — whether the invoice is already paid                                                                                |
| `invoiceIssuedDate`            | **epoch milliseconds**                                                                                                       |
| `transactionUuid`              | the idempotency handle. Derive it from your own row id                                                                       |
| `cusGetInvoiceRight`           | boolean, present in the vendor sample                                                                                        |
| `validation`                   | `0` makes Viettel accept your totals verbatim. **Do not send it** — the recomputation is a free check on your own arithmetic |

For an adjustment or a replacement the block additionally carries
`originalInvoiceId`, `originalInvoiceIssueDate` (ms), `additionalReferenceDesc`,
`additionalReferenceDate` (ms), and for `adjustmentType: 5` also
`adjustmentInvoiceType`.

### buyerInfo

`buyerName`, `buyerLegalName` (tên đơn vị), `buyerTaxCode`,
**`buyerAddressLine`**, `buyerPhoneNumber`, `buyerEmail`, `buyerIdType`,
`buyerIdNo`, `buyerCode`, `buyerDistrictName`, `buyerCityName`,
`buyerCountryCode`, `buyerBankName`, `buyerBankAccount`.

**`buyerNotGetInvoice`** — Integer, `0` = người mua CÓ lấy hóa đơn, `1` = KHÔNG
lấy; default `0`. Name _and_ polarity are quoted from the spec. Buyer name or
unit name is mandatory when it is `0`. For a retail individual with no MST this
is the correct marker; a blank tax code alone is not, and the sale is still
declared either way (Nghị định 123/2020).

### payments

`paymentMethodName` is **required**. `paymentMethod` is optional and defaults to
`5` (KHAC) when omitted — so sending the name alone mislabels every transfer.
Send both.

| Code | Name | | Code | Name |
| ---- | ---------------- | | ---- | --------------------- |
| 1 | TM | | 6 | Tiền mặt |
| 2 | **CK** | | 7 | Chuyển khoản |
| 3 | TM/CK | | 8 | Tiền mặt/Chuyển khoản |
| 4 | DTCN | | 9 | Thẻ quốc tế |
| 5 | KHAC (free text) | | | |

Two generations coexist. The vendor's own sample uses the legacy pair
`2` / `"CK"` for a bank transfer.

### itemInfo

`lineNumber`, `selection`, `itemCode`, `itemName`, `unitName`, `quantity`,
`unitPrice`, `itemTotalAmountWithoutTax`, `itemTotalAmountAfterDiscount`,
`itemTotalAmountWithTax`, `taxPercentage`, `taxAmount`, `discount`,
`itemDiscount`, `itemNote`, `isIncreaseItem`, `unitCode`.

`selection` (Integer 1..6, optional) marks the **line kind**, not a tax
character:

- `1` hàng hóa — the default; quantity and unitPrice required
- `2` ghi chú — no STT, not added to the total
- `3` chiết khấu — needs `isIncreaseItem: false`
- `4` phí khác · `5` khuyến mại · `6` hàng hóa đặc trưng (ND 70)

`isIncreaseItem` carries the direction on an adjustment line (`true` tăng,
`false` giảm).

### summarizeInfo

`sumOfTotalLineAmountWithoutTax`, `totalAmountAfterDiscount`,
`totalAmountWithoutTax`, `totalTaxAmount`, `totalAmountWithTax`,
`totalAmountWithTaxInWords`, `discountAmount`.

### taxBreakdowns

`taxPercentage`, `taxableAmount`, `taxAmount` — one entry per distinct rate. Some
accounts also accept `taxableAmountPos` / `taxAmountPos` booleans marking the
sign of each amount on an adjustment.

### metadata

An **array** of `{keyTag, stringValue, valueType, keyLabel}`, e.g.
`{"keyTag": "invoiceNote", "stringValue": "", "valueType": "text", "keyLabel": "Ghi chú"}`.

## The response

```jsonc
{ "errorCode": null, "description": null, "result": { … } }
```

Both null on success. **Any non-empty `errorCode` is a definite business
rejection** — no enumeration of the codes has been found, so treat the set as
open and store `description` verbatim.

Identifiers come back as `invoiceNo`, `transactionID` and `reservationCode`, and
the vendor is inconsistent about whether they sit at the top level or under
`result`. Read both. A 2xx carrying none of the three is **not a success**; it is
an unknown outcome.

- **`reservationCode` (mã tra cứu)** is generated by Viettel per invoice —
  uppercase letters and digits, unique system-wide, how a buyer finds their own
  invoice on the portal. It cannot be reconstructed; persist it.
- **`transactionID`** is what you quote to Viettel when asking whether an
  ambiguous create actually landed.

## Cancellation, and what replaced it

The specification heads its cancel section **"Hủy hóa đơn (Đã bỏ từ 1/6)"** —
removed as of 1 June. `cancelTransactionInvoice` appears nowhere in the current
collection. Under TT78 an invoice is voided by **issuing a hóa đơn xóa bỏ**
(`adjustmentType: 7`) through `createInvoice`, and the document's cross-reference
to that flow is stale.

The collection _does_ ship worked samples for the two neighbouring cases, which
is the best available evidence for the shape of the third:

- **thay thế** (`adjustmentType: 3`): a full invoice body plus
  `originalInvoiceId`, `originalInvoiceIssueDate`, `additionalReferenceDate`, and
  a note naming the invoice being replaced.
- **điều chỉnh** (`adjustmentType: 5`): the same references plus
  `adjustmentInvoiceType`, with each `itemInfo` line carrying `isIncreaseItem`
  and an `itemNote` such as "Điều chỉnh tăng".

Confirm `7` on the sandbox before writing the refund path. A cancellation that
guesses is worse than one that fails loudly.

Also note that after a filing period closes, Vietnamese practice answers a refund
with a hóa đơn điều chỉnh **plus a biên bản** agreed with the buyer — a business
process, not only an API call.

## Other useful facts

- **A ký hiệu carries defaults.** Fields omitted from the API input can be filled
  from the ký hiệu's configuration on the portal (documented for mã/tên cửa
  hàng). An absent field is not necessarily an empty one.
- **Buyer email** is sent by Viettel, either automatically (portal setting _Gửi
  email khi lập hóa đơn_) or explicitly via `sendHtmlMailProcess`, provided
  `buyerEmail` is on the payload. The lookup link in that mail is click-limited
  and expiring, so it is not a URL to store.
- **Purchase invoices are a different product.** `invoice-sync-tax/search-by-tax`
  lists hóa đơn đầu vào synced from `hoadondientu.gdt.gov.vn` — invoices the
  company _receives_. Irrelevant to issuing as the seller.

## Still open

Answer these on the sandbox before go-live; each is one experiment.

1. **Does a repeated `transactionUuid` dedupe a create?** Every retry path's
   safety rests on it, and the safe assumption is that it does **not**. Send the
   same uuid twice and count the invoices. Cheap to check now that
   `searchInvoiceByTransactionUuid` is known.
2. **The hóa đơn xóa bỏ (`adjustmentType: 7`) payload.** Blocks the refund path.
3. **The error-code vocabulary.** No enumeration published.
