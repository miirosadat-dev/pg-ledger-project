-- migrate:up
-- A dedicated schema keeps our objects separate from `public` and gives us one clear
-- place to manage permissions. AUTHORIZATION makes ledger_owner the owner from birth,
-- so no object here is ever owned by the superuser we happen to run migrations as.
CREATE SCHEMA ledger AUTHORIZATION ledger_owner;
COMMENT ON SCHEMA ledger IS 'pg-ledger: double-entry ledger engine. All business objects live here.';
-- New schemas start with no privileges for anyone but the owner. We open exactly
-- the access each role needs: USAGE lets a role *see into* the schema; it does NOT
-- grant access to tables (those grants come per table, later).
GRANT USAGE ON SCHEMA ledger TO ledger_app,
    ledger_readonly;
-- SEARCH_PATH HARDENING. The search_path decides which schema an unqualified name
-- like "accounts" resolves to. We pin it per role: ledger first, public last.
-- Never put a schema writable by untrusted roles BEFORE ledger, or someone could
-- shadow our objects with look-alikes (a classic privilege-escalation trick).
-- Applies to NEW sessions of each role.
ALTER ROLE ledger_owner
SET search_path = ledger,
    public;
ALTER ROLE ledger_app
SET search_path = ledger,
    public;
ALTER ROLE ledger_readonly
SET search_path = ledger,
    public;
-- Nobody but owners should create objects in `public` (PostgreSQL 15+ already does
-- this by default; we state it explicitly so the intent is documented and the
-- guarantee holds on any server version).
REVOKE CREATE ON SCHEMA public
FROM PUBLIC;
-- Any table ledger_owner creates in this schema automatically becomes readable by
-- ledger_readonly. We deliberately do NOT do this for ledger_app: the app gets
-- explicit grants per table (least privilege, and it lets us withhold
-- UPDATE/DELETE on immutable tables in Phase 3).
ALTER DEFAULT PRIVILEGES FOR ROLE ledger_owner IN SCHEMA ledger
GRANT SELECT ON TABLES TO ledger_readonly;
-- btree_gist: lets GiST indexes (and EXCLUDE constraints) handle plain equality
-- on ordinary types alongside ranges. Installed in `public`, the conventional
-- spot, so every role's search_path finds its operator classes.
CREATE EXTENSION IF NOT EXISTS btree_gist;
-- migrate:down
DROP EXTENSION IF EXISTS btree_gist;
ALTER DEFAULT PRIVILEGES FOR ROLE ledger_owner IN SCHEMA ledger REVOKE
SELECT ON TABLES
FROM ledger_readonly;
ALTER ROLE ledger_owner RESET search_path;
ALTER ROLE ledger_app RESET search_path;
ALTER ROLE ledger_readonly RESET search_path;
-- Note: we do not re-grant CREATE on public to PUBLIC. That default is unsafe and
-- was already off in PostgreSQL 15+, so "undoing" it would be a downgrade.
DROP SCHEMA ledger;