-- migrate:up
SET LOCAL ROLE ledger_owner;
-- Human-readable invoice numbers. A sequence is fast and concurrency-safe, but it can
-- leave GAPS when a creating transaction rolls back. Fine for a demo; legally gapless
-- numbering would need a dedicated counter row locked per issuing entity.
CREATE SEQUENCE ledger.invoice_number_seq;
-- ------------------------------------------------------------------ invoices
CREATE TABLE ledger.invoices (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    number text NOT NULL DEFAULT 'INV-' || lpad(
        nextval('ledger.invoice_number_seq')::text,
        6,
        '0'
    ),
    -- The three ledger accounts an invoice touches. Each reference carries the invoice
    -- currency through a composite FK, so an invoice can never mix currencies with its
    -- accounts (same technique as entries.account_currency_fk).
    customer_account_id uuid NOT NULL,
    -- the payer's wallet (liability)
    receivable_account_id uuid NOT NULL,
    -- accounts receivable (asset)
    revenue_account_id uuid NOT NULL,
    -- revenue
    currency ledger.currency_code NOT NULL,
    total_amount ledger.money_positive NOT NULL,
    amount_paid ledger.money_minor NOT NULL DEFAULT 0,
    status text NOT NULL DEFAULT 'issued',
    -- The ledger transactions that issued and (optionally) voided this invoice.
    issue_transaction_id uuid NOT NULL UNIQUE REFERENCES ledger.transactions (id),
    void_transaction_id uuid UNIQUE REFERENCES ledger.transactions (id),
    due_at timestamptz,
    issued_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT invoices_number_key UNIQUE (number),
    CONSTRAINT invoices_customer_currency_fk FOREIGN KEY (customer_account_id, currency) REFERENCES ledger.accounts (id, currency),
    CONSTRAINT invoices_receivable_currency_fk FOREIGN KEY (receivable_account_id, currency) REFERENCES ledger.accounts (id, currency),
    CONSTRAINT invoices_revenue_currency_fk FOREIGN KEY (revenue_account_id, currency) REFERENCES ledger.accounts (id, currency),
    CONSTRAINT invoices_status_valid CHECK (
        status IN ('issued', 'partially_paid', 'paid', 'void')
    ),
    -- Overpayment is impossible at the storage level.
    CONSTRAINT invoices_amount_paid_range CHECK (
        amount_paid >= 0
        AND amount_paid <= total_amount
    ),
    -- A status is only valid together with a matching paid amount: the "state" half of
    -- the state machine. (The trigger in the next migration guards the transitions.)
    CONSTRAINT invoices_status_matches_amounts CHECK (
        (
            status = 'issued'
            AND amount_paid = 0
        )
        OR (
            status = 'partially_paid'
            AND amount_paid > 0
            AND amount_paid < total_amount
        )
        OR (
            status = 'paid'
            AND amount_paid = total_amount
        )
        OR (
            status = 'void'
            AND amount_paid = 0
        )
    ),
    -- A void invoice must reference its voiding transaction, and only a void one may.
    CONSTRAINT invoices_void_link CHECK (
        (status = 'void') = (void_transaction_id IS NOT NULL)
    )
);
COMMENT ON TABLE ledger.invoices IS 'Invoices. Issue posts receivable/revenue entries; payments post wallet/receivable entries.';
COMMENT ON COLUMN ledger.invoices.status IS 'issued -> partially_paid -> paid, or issued -> void. paid and void are terminal.';
CREATE INDEX invoices_customer_idx ON ledger.invoices (customer_account_id);
-- ------------------------------------------------------------- invoice_lines
CREATE TABLE ledger.invoice_lines (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_id uuid NOT NULL REFERENCES ledger.invoices (id),
    description text NOT NULL,
    quantity integer NOT NULL,
    unit_amount ledger.money_positive NOT NULL,
    -- Generated: the line total can never disagree with quantity * unit_amount.
    line_total ledger.money_positive GENERATED ALWAYS AS (quantity::bigint * unit_amount::bigint) STORED,
    CONSTRAINT invoice_lines_description_not_blank CHECK (length(btrim(description)) > 0),
    CONSTRAINT invoice_lines_quantity_positive CHECK (quantity > 0)
);
COMMENT ON TABLE ledger.invoice_lines IS 'Invoice line items. Immutable once written.';
CREATE INDEX invoice_lines_invoice_idx ON ledger.invoice_lines (invoice_id);
-- ---------------------------------------------------------- invoice_payments
CREATE TABLE ledger.invoice_payments (
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    invoice_id uuid NOT NULL REFERENCES ledger.invoices (id),
    -- The ledger transaction that moved the money; one payment row per transaction.
    transaction_id uuid NOT NULL UNIQUE REFERENCES ledger.transactions (id),
    amount ledger.money_positive NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE ledger.invoice_payments IS 'Payments applied to invoices. Immutable once written.';
CREATE INDEX invoice_payments_invoice_idx ON ledger.invoice_payments (invoice_id);
-- ledger_readonly gets SELECT automatically (default privileges from Phase 1). The app
-- may read these tables; every write goes through the SECURITY DEFINER functions.
GRANT SELECT ON ledger.invoices,
    ledger.invoice_lines,
    ledger.invoice_payments TO ledger_app;
RESET ROLE;
-- migrate:down
SET LOCAL ROLE ledger_owner;
DROP TABLE ledger.invoice_payments;
DROP TABLE ledger.invoice_lines;
DROP TABLE ledger.invoices;
DROP SEQUENCE ledger.invoice_number_seq;
RESET ROLE;