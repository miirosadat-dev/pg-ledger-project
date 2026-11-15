-- migrate:up
-- Create the domains AS ledger_owner so the owner holds them, not the superuser
-- running this migration. SET LOCAL lasts until the end of this transaction only.
SET LOCAL ROLE ledger_owner;
-- Currency: exactly three uppercase ASCII letters (ISO 4217 style: USD, UGX, EUR).
-- Why a domain: every table that stores a currency inherits the same rule, so a
-- typo like 'usd' or 'US' is rejected everywhere, not only where someone remembered.
CREATE DOMAIN ledger.currency_code AS char(3) CONSTRAINT currency_code_format CHECK (VALUE ~ '^[A-Z]{3}$');
COMMENT ON DOMAIN ledger.currency_code IS 'ISO 4217-style currency code: 3 uppercase letters, e.g. USD, UGX.';
-- Signed money in MINOR units (cents). bigint holds up to about 9.2e18 units,
-- exact integer arithmetic, no floating point, no rounding surprises.
-- Signed because balances and signed deltas can be negative.
CREATE DOMAIN ledger.money_minor AS bigint;
COMMENT ON DOMAIN ledger.money_minor IS 'Signed amount in minor units (cents). Integer only: never floats.';
-- Strictly positive money: used for entry amounts, where direction (debit/credit)
-- carries the sign and the amount itself must always be > 0.
CREATE DOMAIN ledger.money_positive AS bigint CONSTRAINT money_positive_gt_zero CHECK (VALUE > 0);
COMMENT ON DOMAIN ledger.money_positive IS 'Strictly positive amount in minor units (cents). Zero and negatives rejected.';
-- IMPORTANT: restore the original role before the migration ends. dbmate records
-- the migration in public.schema_migrations inside this same transaction, and that
-- table belongs to the migrating (super)user, not ledger_owner.
RESET ROLE;
-- migrate:down
SET LOCAL ROLE ledger_owner;
DROP DOMAIN ledger.money_positive;
DROP DOMAIN ledger.money_minor;
DROP DOMAIN ledger.currency_code;
RESET ROLE;