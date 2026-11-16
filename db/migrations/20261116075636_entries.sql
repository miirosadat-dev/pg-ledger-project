-- migrate:up
SET LOCAL ROLE ledger_owner;
-- One row per line of a journal entry: "this account was debited/credited this much".
-- Lines are never edited; Phase 3 makes the table immutable.
CREATE TABLE ledger.entries (
    -- Identity column: compact, strictly increasing. Cheap for the biggest table in the
    -- system. GENERATED ALWAYS stops clients from supplying their own ids.
    id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_id uuid NOT NULL REFERENCES ledger.transactions (id),
    account_id uuid NOT NULL,
    -- Copied from the account so the composite foreign key below can verify it.
    currency ledger.currency_code NOT NULL,
    direction char(1) NOT NULL,
    -- Strictly positive. Direction carries the "sign", so zero and negatives are
    -- impossible (the domain rejects them).
    amount ledger.money_positive NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT entries_direction_valid CHECK (direction IN ('D', 'C')),
    -- INVARIANT 5 (currency safety), enforced by the database with no trigger: the pair
    -- (account_id, currency) must exist in accounts. An EUR entry on a USD account
    -- cannot be inserted. Tradeoff: the app must send the currency with each line.
    CONSTRAINT entries_account_currency_fk FOREIGN KEY (account_id, currency) REFERENCES ledger.accounts (id, currency)
);
COMMENT ON TABLE ledger.entries IS 'Journal lines (debit or credit). Append-only.';
COMMENT ON COLUMN ledger.entries.direction IS 'D = debit, C = credit.';
COMMENT ON COLUMN ledger.entries.amount IS 'Minor units, strictly positive; sign comes from direction.';
-- PostgreSQL indexes referenced (PK) columns automatically, but NOT referencing ones.
-- Without this, the "load all lines of a transaction" lookup (used by our balance check
-- in Phase 3) would scan the whole table. Statement-style indexes come in Phase 7,
-- where we prove them with EXPLAIN.
CREATE INDEX entries_transaction_id_idx ON ledger.entries (transaction_id);
RESET ROLE;
-- migrate:down
SET LOCAL ROLE ledger_owner;
DROP TABLE ledger.entries;
RESET ROLE;