-- migrate:up
-- Run as ledger_owner so the owner holds every object (the migrating user is a
-- superuser; we never want superuser-owned business tables). Names are
-- schema-qualified because search_path belongs to the migrating session.
SET LOCAL ROLE ledger_owner;
-- ---------------------------------------------------------------- currencies
-- Lookup table, not an enum: adding a currency is an INSERT, not a schema change.
CREATE TABLE ledger.currencies (
    code ledger.currency_code PRIMARY KEY,
    name text NOT NULL,
    -- Decimal places: USD 2, UGX 0, KWD 3. Amounts are stored as integers in minor
    -- units, so this is what the app needs to display them correctly.
    minor_unit_exponent smallint NOT NULL,
    CONSTRAINT currencies_name_not_blank CHECK (length(btrim(name)) > 0),
    CONSTRAINT currencies_exponent_in_range CHECK (
        minor_unit_exponent BETWEEN 0 AND 4
    )
);
COMMENT ON TABLE ledger.currencies IS 'Supported currencies and their minor-unit exponent.';
COMMENT ON COLUMN ledger.currencies.minor_unit_exponent IS 'Decimal places of the major unit: 2 for USD (100 cents), 0 for UGX, 3 for KWD.';
INSERT INTO ledger.currencies (code, name, minor_unit_exponent)
VALUES ('USD', 'US Dollar', 2),
    ('EUR', 'Euro', 2),
    ('GBP', 'Pound Sterling', 2),
    ('UGX', 'Ugandan Shilling', 0),
    ('KES', 'Kenyan Shilling', 2),
    ('JPY', 'Japanese Yen', 0),
    ('KWD', 'Kuwaiti Dinar', 3);
-- ------------------------------------------------------------------ accounts
CREATE TABLE ledger.accounts (
    -- UUIDv7 (built into PostgreSQL 18): time-ordered, so inserts stay index-friendly
    -- (unlike random v4), and ids are safe to expose in URLs.
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    -- External user id (we have no users table; auth lives elsewhere).
    -- NULL for platform-owned accounts (cash, fees, receivables).
    owner_ref text,
    name text NOT NULL,
    type text NOT NULL,
    -- Which side INCREASES this account: D for assets/expenses, C for the rest.
    -- GENERATED means it can never disagree with `type`; no one can set it by hand.
    normal_side char(1) GENERATED ALWAYS AS (
        CASE
            WHEN type IN ('asset', 'expense') THEN 'D'
            ELSE 'C'
        END
    ) STORED,
    -- One currency per account, forever. FK to the lookup table so only known
    -- currencies exist. Also blocks changing currency once entries reference it.
    currency ledger.currency_code NOT NULL REFERENCES ledger.currencies (code),
    -- Overdraft permission. false for user wallets; true for platform accounts
    -- such as cash. Enforced by account_balances (see that migration).
    allow_negative boolean NOT NULL DEFAULT false,
    status text NOT NULL DEFAULT 'active',
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT accounts_type_valid CHECK (
        type IN (
            'asset',
            'liability',
            'equity',
            'revenue',
            'expense'
        )
    ),
    CONSTRAINT accounts_status_valid CHECK (status IN ('active', 'frozen', 'closed')),
    CONSTRAINT accounts_name_not_blank CHECK (length(btrim(name)) > 0),
    -- One account per (owner, name, currency): e.g. one "wallet" per user per currency.
    -- NULLS NOT DISTINCT (PostgreSQL 15+) makes NULL owners compare as equal, so two
    -- platform accounts with the same name and currency are also rejected. Plain UNIQUE
    -- would let unlimited duplicates through, because NULL <> NULL.
    CONSTRAINT accounts_owner_name_currency_key UNIQUE NULLS NOT DISTINCT (owner_ref, name, currency),
    -- Redundant with the primary key on purpose: they exist ONLY so other tables can
    -- reference (id, currency) and (id, allow_negative) with composite foreign keys.
    -- A foreign key may only target a unique constraint.
    CONSTRAINT accounts_id_currency_key UNIQUE (id, currency),
    CONSTRAINT accounts_id_allow_negative_key UNIQUE (id, allow_negative)
);
COMMENT ON TABLE ledger.accounts IS 'Chart of accounts. User wallets are LIABILITY accounts (the platform owes users).';
COMMENT ON COLUMN ledger.accounts.owner_ref IS 'External user id; NULL for platform accounts.';
COMMENT ON COLUMN ledger.accounts.normal_side IS 'Generated. D = debits increase the balance (asset, expense); C = credits increase it.';
COMMENT ON COLUMN ledger.accounts.allow_negative IS 'If false, the balance can never go below zero (enforced by a CHECK on account_balances).';
-- Back to the migrating user: dbmate writes to public.schema_migrations in this same
-- transaction, and that table is not ledger_owner's.
RESET ROLE;
-- migrate:down
-- DROP TABLE accounts first: it references currencies.
SET LOCAL ROLE ledger_owner;
DROP TABLE ledger.accounts;
DROP TABLE ledger.currencies;
RESET ROLE;