-- migrate:up
SET LOCAL ROLE ledger_owner;
-- Cached current balance per account (invariant 7: must always equal the sum of its
-- entries; Phase 7 ships the reconciliation query that proves it). Balance is stored on
-- the account's NORMAL side: credits - debits for liabilities, debits - credits for assets.
CREATE TABLE ledger.account_balances (
    account_id uuid PRIMARY KEY,
    -- Local copy of accounts.allow_negative. It exists so the CHECK below can see it:
    -- a CHECK cannot read other tables, but it can read its own columns.
    allow_negative boolean NOT NULL,
    balance ledger.money_minor NOT NULL DEFAULT 0,
    -- Bumped on every change; supports optimistic concurrency and auditing.
    version bigint NOT NULL DEFAULT 0,
    updated_at timestamptz NOT NULL DEFAULT now(),
    -- The copy cannot drift: it must match the real account row. ON UPDATE CASCADE means
    -- changing allow_negative on an account flows here and the CHECK re-validates.
    CONSTRAINT account_balances_account_fk FOREIGN KEY (account_id, allow_negative) REFERENCES ledger.accounts (id, allow_negative) ON UPDATE CASCADE,
    -- INVARIANT 4 (no overdraft) as a plain constraint: an account that does not allow
    -- negative balances can never hold a negative one, under any concurrency, because
    -- every writer hits this check.
    CONSTRAINT account_balances_no_overdraft CHECK (
        allow_negative
        OR balance >= 0
    )
);
COMMENT ON TABLE ledger.account_balances IS 'Cached balance per account on its normal side. Maintained in Phase 3/4; reconciled in Phase 7.';
COMMENT ON COLUMN ledger.account_balances.allow_negative IS 'Synced copy of accounts.allow_negative, so a CHECK can enforce the no-overdraft rule.';
RESET ROLE;
-- migrate:down
SET LOCAL ROLE ledger_owner;
DROP TABLE ledger.account_balances;
RESET ROLE;