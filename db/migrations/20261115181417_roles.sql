-- migrate:up
-- ROLES ARE CLUSTER-WIDE in PostgreSQL (shared by every database on the server),
-- not per-database. CREATE ROLE has no IF NOT EXISTS, so we guard with a DO block;
-- that makes this migration safe to re-run on a server that already has the roles.
--
-- No passwords are set here ON PURPOSE: migrations are committed to a public repo.
-- Passwords are set out-of-band with \password (see the step instructions).
-- A role with LOGIN but no password cannot authenticate over password auth,
-- so this is safe by default.
--
-- Every role gets the minimum attributes: no superuser, no createdb, no createrole,
-- no replication, and NOBYPASSRLS so Row-Level Security (Phase 13) can't be skipped.
DO $$ BEGIN -- Owns the schema and every object in it; used to run migrations.
IF NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = 'ledger_owner'
) THEN CREATE ROLE ledger_owner LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
END IF;
-- Used by the API at runtime. Gets only explicit, per-table grants later.
IF NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = 'ledger_app'
) THEN CREATE ROLE ledger_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
END IF;
-- Used by reporting/dashboards. SELECT only.
IF NOT EXISTS (
    SELECT 1
    FROM pg_roles
    WHERE rolname = 'ledger_readonly'
) THEN CREATE ROLE ledger_readonly LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
END IF;
END $$;
-- By default PostgreSQL lets EVERY role connect to every database (CONNECT is granted
-- to the pseudo-role PUBLIC). We remove that and grant it only to our three roles.
-- current_database() keeps this migration portable (local "ledger_dev", Neon, CI),
-- and format(%I) quotes the identifier safely.
DO $$ BEGIN EXECUTE format(
    'REVOKE ALL ON DATABASE %I FROM PUBLIC',
    current_database()
);
EXECUTE format(
    'GRANT CONNECT ON DATABASE %I TO ledger_owner, ledger_app, ledger_readonly',
    current_database()
);
END $$;
-- migrate:down
-- Restore the default (PUBLIC may connect) and drop the roles.
-- DROP ROLE fails if the role still owns objects; that's why the schema migration
-- is rolled back first (migrations roll back in reverse order).
DO $$ BEGIN EXECUTE format(
    'GRANT CONNECT ON DATABASE %I TO PUBLIC',
    current_database()
);
EXECUTE format(
    'REVOKE CONNECT ON DATABASE %I FROM ledger_owner, ledger_app, ledger_readonly',
    current_database()
);
END $$;
DROP ROLE IF EXISTS ledger_readonly;
DROP ROLE IF EXISTS ledger_app;
DROP ROLE IF EXISTS ledger_owner;