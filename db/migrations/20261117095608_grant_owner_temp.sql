-- migrate:up
-- REFRESH MATERIALIZED VIEW CONCURRENTLY builds a temp table internally. Phase 1 revoked
-- every default database privilege from PUBLIC (including TEMPORARY) and re-granted only
-- CONNECT. The refresh function runs as ledger_owner (SECURITY DEFINER), so the owner
-- needs TEMPORARY. The app roles do not: they only call the function.
DO $$ BEGIN EXECUTE format(
    'GRANT TEMPORARY ON DATABASE %I TO ledger_owner',
    current_database()
);
END $$;
-- migrate:down
DO $$ BEGIN EXECUTE format(
    'REVOKE TEMPORARY ON DATABASE %I FROM ledger_owner',
    current_database()
);
END $$;