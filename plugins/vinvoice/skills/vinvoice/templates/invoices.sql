-- Viettel S-Invoice issuance: one row per payment that must produce a tax
-- invoice, doubling as the delivery queue.
--
-- Adapt: `payments` is whatever table records settled money in this project, and
-- `uuid_generate_v7()` is whatever id default it uses. Everything else is the
-- shape, and each constraint below exists because its absence has a specific
-- failure — see ../references/pipeline.md.
--
-- If the migration runner wraps each file in a transaction (it should), do not
-- add BEGIN/COMMIT here, and note that CREATE INDEX CONCURRENTLY is illegal
-- inside a transaction block. Plain CREATE INDEX takes a SHARE lock on the
-- payments table: reads continue, writes block until the build finishes. Fine
-- for a small table; build out-of-band if it is not.

CREATE TABLE IF NOT EXISTS invoices (
    id                     UUID PRIMARY KEY DEFAULT uuid_generate_v7(),

    -- THE CROSS-REPLICA RACE GUARD, not a tidiness constraint. The reconciler
    -- selects candidates with NOT EXISTS; every replica runs one, so without
    -- UNIQUE two pods sweeping in the same instant both insert and TWO REAL TAX
    -- INVOICES are issued for one sale. It also means exactly one invoice per
    -- payment forever, including after a cancellation: re-issuing is an operator
    -- action. If a true hóa đơn thay thế chain is ever needed, add supersedes_id
    -- and relax this to a partial unique index at that point.
    payment_id             UUID NOT NULL UNIQUE REFERENCES payments(id),

    -- How the row was born. 'external' records an invoice raised by hand on the
    -- Viettel portal and must never be dispatched — that is how a mixed
    -- pre-integration history is cleared without double-issuing.
    origin                 TEXT NOT NULL DEFAULT 'auto'
                           CHECK (origin IN ('auto','backfill','external')),

    -- A refund flips an issued row to ('cancel','pending') rather than creating a
    -- second row, which is what lets payment_id stay unconditionally UNIQUE.
    action                 TEXT NOT NULL DEFAULT 'issue'
                           CHECK (action IN ('issue','cancel')),

    status                 TEXT NOT NULL DEFAULT 'pending'
                           CHECK (status IN ('pending','in_flight','issued','failed',
                                             'needs_review','dead_letter','cancelled','skipped')),
    skip_reason            TEXT,

    -- FROZEN money and tax. total_with_tax is what the buyer actually paid, net
    -- of any voucher. Never re-derived: an invoice must keep reporting what was
    -- true when it was filed, so an operator editing the tax-rate map cannot
    -- rewrite documents already filed with the cơ quan thuế.
    --
    -- tax_percentage is NUMERIC(5,2) and SIGNED on purpose: KCT (-1) and KKKNT
    -- (-2) are codes, not rates, and 5.5% needs the decimals.
    total_with_tax         BIGINT NOT NULL CHECK (total_with_tax >= 0),
    total_without_tax      BIGINT NOT NULL CHECK (total_without_tax >= 0),
    tax_amount             BIGINT NOT NULL CHECK (tax_amount >= 0),
    tax_percentage         NUMERIC(5,2) NOT NULL,
    item_name              TEXT NOT NULL,

    -- FROZEN buyer identity, for the same reason.
    buyer_is_org           BOOLEAN NOT NULL DEFAULT FALSE,
    buyer_name             TEXT NOT NULL,
    buyer_tax_code         TEXT,
    buyer_address          TEXT,
    buyer_email            TEXT,
    buyer_phone            TEXT,

    -- Vendor identifiers, NULL until the create succeeds. reservation_code is the
    -- mã tra cứu a buyer needs to find their own invoice on the portal, and
    -- viettel_transaction_id is what you quote to Viettel when asking whether an
    -- ambiguous create landed. Losing either makes an issued invoice unreachable,
    -- so both are persisted even though neither is read on the happy path.
    template_code          TEXT,
    invoice_serial         TEXT,
    invoice_no             TEXT,
    supplier_tax_code      TEXT,
    viettel_transaction_id TEXT,
    reservation_code       TEXT,
    issued_at              TIMESTAMPTZ,
    cancelled_at           TIMESTAMPTZ,

    -- Queue mechanics.
    --
    -- `attempts` drives the RETRY LADDER and an operator's retry resets it, so
    -- the row gets a fresh ladder rather than the 6-hour step it died on.
    --
    -- `claim_seq` is the CLAIM IDENTITY, and the two must not be the same number.
    -- Every result write is fenced on "the row is still the claim I was issued";
    -- using attempts for that is defeated by its own reset, letting a stalled
    -- worker's write match a claim that was not its own. Nothing resets this one.
    attempts               INT NOT NULL DEFAULT 0,
    claim_seq              BIGINT NOT NULL DEFAULT 0,
    last_error             TEXT,
    next_attempt_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Exactly what was sent and exactly what came back: the only forensic record
    -- of an ambiguous call, and what an operator compares against the portal.
    --
    -- ⚠️ request_payload is TEXT, not JSONB, and that is the point. JSONB parses
    -- and re-serialises: it sorts object keys, drops insignificant whitespace and
    -- normalises numbers, so what comes back out is EQUIVALENT to what went in
    -- and not identical to it. This column's whole job is to be the bytes that
    -- were sent, so it stores them as bytes. (A jsonb_typeof-style check is not
    -- worth adding either — an unparseable value here would be evidence too.)
    --
    -- response_payload stays JSONB because it is read and filtered by operators,
    -- but whatever writes it must make a non-JSON vendor body storable first
    -- ("Request Fail" is plain text, an intermediary's 502 is HTML) — a failing
    -- write leaves the row claimable and defeats the ambiguity guard.
    request_payload        TEXT,
    response_payload       JSONB,

    created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- The totals must re-add. Enforced here because the alternative is a rounding
    -- bug that surfaces as a vendor rejection on a live sale.
    CONSTRAINT invoices_totals_add_up CHECK (total_without_tax + tax_amount = total_with_tax),

    -- A skipped row is terminal and must say why; nothing else may claim a reason.
    -- The reason must be non-EMPTY, not merely non-NULL: '' satisfies IS NOT NULL
    -- and tells the operator reading the queue exactly nothing about why a
    -- payment was retired without a tax invoice.
    CONSTRAINT invoices_skip_reason_shape CHECK (
        (status = 'skipped' AND skip_reason IS NOT NULL AND length(btrim(skip_reason)) > 0) OR
        (status <> 'skipped' AND skip_reason IS NULL)
    ),

    -- 'issued' asserts that a tax document EXISTS. Without this, the row could
    -- claim that in a terminal state carrying no way to find the document — the
    -- exact failure the client-side check exists to prevent, arriving instead
    -- through a repair script or a hand-written UPDATE. Terminal states are
    -- excluded from every sweep, so nothing would ever look at it again.
    CONSTRAINT invoices_issued_is_traceable CHECK (
        status <> 'issued' OR
        invoice_no IS NOT NULL OR
        viettel_transaction_id IS NOT NULL OR
        reservation_code IS NOT NULL
    ),

    -- Only two negative rates exist, and they are codes rather than rates:
    -- -1 KCT and -2 KKKNT. A stray -1.5 would be arithmetically zero-tax, fit the
    -- column, and mean nothing on a filing.
    CONSTRAINT invoices_tax_percentage_vocabulary CHECK (
        tax_percentage IN (-1, -2) OR (tax_percentage >= 0 AND tax_percentage <= 100)
    ),

    -- A rate that levies no tax must carry no tax. KCT (-1), KKKNT (-2) and 0%
    -- are all "the whole amount is net"; a row claiming one of them while holding
    -- a positive tax_amount still satisfies invoices_totals_add_up, and would be
    -- filed as an exempt sale that nonetheless charged VAT.
    CONSTRAINT invoices_zero_rate_zero_tax CHECK (
        tax_percentage > 0 OR tax_amount = 0
    ),

    -- An 'external' row records an invoice raised BY HAND on the Viettel portal.
    -- Dispatching one creates a second document for a sale that already has one.
    -- The worker excludes them and the claim query excludes them again, but both
    -- of those are application discipline: an operator pressing "retry" sets
    -- status='pending' like any other row, and a repair script does not read the
    -- worker at all. This makes it an invariant of the data instead.
    CONSTRAINT invoices_external_is_not_queued CHECK (
        origin <> 'external' OR status NOT IN ('pending','in_flight','failed')
    )
);

-- ⚠️ KNOWN GAP: one row cannot describe two documents.
--
-- Under TT78 an invoice is voided by ISSUING a hóa đơn xóa bỏ (adjustmentType 7),
-- which is a SECOND document with its own invoice number, mã tra cứu and
-- transaction id. This table has one set of those columns, so a cancellation
-- either overwrites the original's identifiers — losing the record of what was
-- filed — or reuses its transaction identity for a different filing.
--
-- Nothing here needs it yet, because the cancel path does not work end to end
-- (the vendor retired the endpoint and the replacement flow is unconfirmed). When
-- it does, add a `voided_by_id UUID REFERENCES invoices(id)` and relax
-- `payment_id UNIQUE` to a partial unique index over the non-void rows, rather
-- than widening what a single row means.

-- Polled by every replica on every tick. PARTIAL on the two dispatchable states
-- so the scan never touches issued/cancelled/skipped rows — which is all of them
-- in steady state.
CREATE INDEX IF NOT EXISTS idx_invoices_dispatch
    ON invoices (next_attempt_at, id) WHERE status IN ('pending','failed');

-- The reaper runs in every replica on every tick whether or not there is anything
-- to reap, which is almost always. Without this it is a full scan of a table that
-- grows by one row per sale, forever.
CREATE INDEX IF NOT EXISTS idx_invoices_in_flight
    ON invoices (updated_at) WHERE status = 'in_flight';

-- The operator queue opens on the rows a human has to deal with.
CREATE INDEX IF NOT EXISTS idx_invoices_attention
    ON invoices (created_at DESC) WHERE status IN ('needs_review','dead_letter','failed');

-- Reconciler candidates. PARTIAL, which is what keeps them off the checkout write
-- path: a freshly inserted payment is 'pending' and enters neither index.
--
-- ⚠️ THE PREDICATE MUST MATCH THE SWEEP'S OWN WHERE CLAUSE IN MEANING. Postgres
-- uses a partial index only when it can prove the query predicate IMPLIES the
-- index predicate, and `status IN ('paid','refunded')` does not imply
-- `status = 'paid'`. Indexing only 'paid' while the sweep reads both made the
-- index unusable and the sweep a sequential scan — measured on 200k rows: 79 ms
-- against 7.95 ms.
CREATE INDEX IF NOT EXISTS idx_payments_settled_sweep
    ON payments (paid_at) WHERE status IN ('paid','refunded');

CREATE INDEX IF NOT EXISTS idx_payments_refunded
    ON payments (id) WHERE status = 'refunded';

COMMENT ON TABLE invoices IS
    'Viettel S-Invoice issuance: one row per payment, doubling as the delivery queue. Money/tax/buyer columns are FROZEN snapshots — never re-derive them.';
COMMENT ON COLUMN invoices.payment_id IS
    'UNIQUE. Makes the reconciler''s NOT EXISTS race-proof across replicas — without it two pods issue two tax invoices for one sale.';
COMMENT ON COLUMN invoices.tax_percentage IS
    'Signed. KCT/KKKNT are encoded as negative rates (-1/-2), which are NOT the same as 0%.';
COMMENT ON COLUMN invoices.status IS
    'needs_review = ambiguous vendor outcome, never auto-retried (a retry may duplicate a tax filing). skipped = must never be invoiced; it is a ROW so the sweep stops re-examining it.';
COMMENT ON COLUMN invoices.claim_seq IS
    'Claim identity. Only ever increases; nothing resets it. Fences every result write against a stale claim.';
