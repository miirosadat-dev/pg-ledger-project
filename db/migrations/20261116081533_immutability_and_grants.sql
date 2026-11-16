-- migrate:up
SET LOCAL ROLE ledger_owner;
-- ======================================================================
-- IMMUTABILITY (invariant 2), defence in depth: triggers AND privileges
-- ======================================================================
-- Layer 1: triggers. They fire for EVERY role, superusers included, so even a mistaken
-- admin session cannot edit history by accident. Corrections are reversal transactions.
CREATE FUNCTION ledger.reject_mutation() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog,
    ledger AS $$ BEGIN RAISE EXCEPTION '% on ledger.% is forbidden: ledger rows are immutable (post a reversal instead)',
    TG_OP,
    TG_TABLE_NAME USING ERRCODE = 'LD003';
END $$;
-- Row-level for UPDATE/DELETE.
CREATE TRIGGER entries_immutable BEFORE
UPDATE
    OR DELETE ON ledger.entries FOR EACH ROW EXECUTE FUNCTION ledger.reject_mutation();
CREATE TRIGGER transactions_immutable BEFORE
UPDATE
    OR DELETE ON ledger.transactions FOR EACH ROW EXECUTE FUNCTION ledger.reject_mutation();
-- TRUNCATE never fires row triggers, so it needs its own statement-level trigger.
CREATE TRIGGER entries_no_truncate BEFORE TRUNCATE ON ledger.entries FOR EACH STATEMENT EXECUTE FUNCTION ledger.reject_mutation();
CREATE TRIGGER transactions_no_truncate BEFORE TRUNCATE ON ledger.transactions FOR EACH STATEMENT EXECUTE FUNCTION ledger.reject_mutation();
-- Layer 2: privileges. Anyone who cannot even attempt UPDATE/DELETE/TRUNCATE is stopped
-- before a trigger runs. Caveat for the README: a table OWNER could still ALTER TABLE ...
-- DISABLE TRIGGER, which is why ledger_owner is used only for migrations, never by the app.
REVOKE
UPDATE,
    DELETE,
    TRUNCATE ON ledger.entries,
    ledger.transactions
FROM PUBLIC,
    ledger_app;
-- ======================================================================
-- LEAST-PRIVILEGE GRANTS FOR THE API ROLE
-- ======================================================================
-- ledger_readonly already gets SELECT on every table via the default privileges set in
-- Phase 1. ledger_app gets only what it genuinely needs:
GRANT SELECT ON ledger.currencies TO ledger_app;
GRANT SELECT,
    INSERT ON ledger.accounts TO ledger_app;
-- Column-level privilege: the app may change an account's status and nothing else (it
-- cannot rename it, retype it, or flip allow_negative).
GRANT UPDATE (status) ON ledger.accounts TO ledger_app;
-- Read-only: balances move only through the SECURITY DEFINER trigger.
GRANT SELECT ON ledger.account_balances TO ledger_app;
GRANT SELECT,
    INSERT ON ledger.transactions TO ledger_app;
GRANT SELECT,
    INSERT ON ledger.entries TO ledger_app;
-- Idempotency keys are operational data: complete them and purge expired ones.
GRANT SELECT,
    INSERT,
    DELETE ON ledger.idempotency_keys TO ledger_app;
GRANT UPDATE (status, response) ON ledger.idempotency_keys TO ledger_app;
COMMENT ON FUNCTION ledger.reject_mutation() IS 'Blocks UPDATE/DELETE/TRUNCATE on ledger tables (SQLSTATE LD003).';
RESET ROLE;
-- migrate:down
SET LOCAL ROLE ledger_owner;
REVOKE ALL ON ledger.currencies,
ledger.accounts,
ledger.account_balances,
ledger.transactions,
ledger.entries,
ledger.idempotency_keys
FROM ledger_app;
DROP TRIGGER transactions_no_truncate ON ledger.transactions;
DROP TRIGGER entries_no_truncate ON ledger.entries;
DROP TRIGGER transactions_immutable ON ledger.transactions;
DROP TRIGGER entries_immutable ON ledger.entries;
DROP FUNCTION ledger.reject_mutation();
RESET ROLE;