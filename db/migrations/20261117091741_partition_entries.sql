-- migrate:up
SET LOCAL ROLE ledger_owner;
-- 1. Move the old table aside. Renaming a table does NOT rename its indexes or
--    sequences, so free up the names we want to reuse.
ALTER TABLE ledger.entries
    RENAME TO entries_old;
ALTER INDEX ledger.entries_pkey
RENAME TO entries_old_pkey;
ALTER INDEX ledger.entries_transaction_id_idx
RENAME TO entries_old_transaction_id_idx;
-- 2. The partitioned replacement, split by month of created_at (the posting time).
--    The primary key MUST contain the partition column, so it is (id, created_at):
--    PostgreSQL can only enforce uniqueness inside one partition. id stays unique in
--    practice (single sequence) but the database no longer proves it globally.
--    Identity columns do not combine cleanly with partitioning, so id is a plain
--    sequence default. The app cannot insert directly anyway (Phase 4).
CREATE SEQUENCE ledger.entry_id_seq AS bigint;
CREATE TABLE ledger.entries (
    id bigint NOT NULL DEFAULT nextval('ledger.entry_id_seq'),
    transaction_id uuid NOT NULL,
    account_id uuid NOT NULL,
    currency ledger.currency_code NOT NULL,
    direction char(1) NOT NULL,
    amount ledger.money_positive NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT entries_pkey PRIMARY KEY (id, created_at),
    CONSTRAINT entries_direction_valid CHECK (direction IN ('D', 'C')),
    CONSTRAINT entries_transaction_fk FOREIGN KEY (transaction_id) REFERENCES ledger.transactions (id),
    -- Currency safety (invariant 5) still enforced by the composite FK.
    CONSTRAINT entries_account_currency_fk FOREIGN KEY (account_id, currency) REFERENCES ledger.accounts (id, currency)
) PARTITION BY RANGE (created_at);
ALTER SEQUENCE ledger.entry_id_seq OWNED BY ledger.entries.id;
COMMENT ON TABLE ledger.entries IS 'Journal lines (debit or credit). Append-only. Partitioned by month of created_at.';
COMMENT ON COLUMN ledger.entries.direction IS 'D = debit, C = credit.';
COMMENT ON COLUMN ledger.entries.amount IS 'Minor units, strictly positive; sign comes from direction.';
-- 3. Helpers. Owned by ledger_owner, NOT granted to the app.
-- Attaches the four ledger guards to ONE partition. Row-level triggers are created
-- per partition (not on the parent) so every partition is guarded by construction,
-- and a TRUNCATE aimed directly at a partition cannot slip past a parent-only guard.
CREATE FUNCTION ledger.attach_entries_guards(p_table name) RETURNS void LANGUAGE plpgsql
SET search_path = pg_catalog,
    ledger AS $$ BEGIN EXECUTE format(
        'CREATE CONSTRAINT TRIGGER entries_balanced_check AFTER INSERT ON ledger.%I
                    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW
                    EXECUTE FUNCTION ledger.assert_transaction_balanced()',
        p_table
    );
EXECUTE format(
    'CREATE TRIGGER entries_apply_balance AFTER INSERT ON ledger.%I
                    FOR EACH ROW EXECUTE FUNCTION ledger.apply_entry_to_balance()',
    p_table
);
EXECUTE format(
    'CREATE TRIGGER entries_immutable BEFORE UPDATE OR DELETE ON ledger.%I
                    FOR EACH ROW EXECUTE FUNCTION ledger.reject_mutation()',
    p_table
);
EXECUTE format(
    'CREATE TRIGGER entries_no_truncate BEFORE TRUNCATE ON ledger.%I
                    FOR EACH STATEMENT EXECUTE FUNCTION ledger.reject_mutation()',
    p_table
);
END $$;
-- Creates the partition for the month containing p_month (idempotent). Month
-- boundaries are UTC. The bounds are formatted WITH their UTC offset so they never
-- depend on the session TimeZone. Returns the partition name.
CREATE FUNCTION ledger.create_entries_partition(
    p_month date,
    p_attach_guards boolean DEFAULT true
) RETURNS text LANGUAGE plpgsql
SET search_path = pg_catalog,
    ledger AS $$
DECLARE v_first timestamp := date_trunc('month', p_month::timestamp);
v_start timestamptz;
v_end timestamptz;
v_name text;
BEGIN v_start := v_first AT TIME ZONE 'UTC';
v_end := (v_first + interval '1 month') AT TIME ZONE 'UTC';
v_name := 'entries_' || to_char(v_first, 'YYYY_MM');
IF to_regclass(format('ledger.%I', v_name)) IS NULL THEN EXECUTE format(
    'CREATE TABLE ledger.%I PARTITION OF ledger.entries
                        FOR VALUES FROM (%L) TO (%L)',
    v_name,
    v_start,
    v_end
);
IF p_attach_guards THEN PERFORM ledger.attach_entries_guards(v_name);
END IF;
END IF;
RETURN v_name;
END $$;
-- Creates the current month plus p_months_ahead future months. Returns how many were
-- NEW. Meant to run on a schedule (pg_cron in Phase 13) or at API start-up.
CREATE FUNCTION ledger.ensure_entries_partitions(p_months_ahead integer DEFAULT 3) RETURNS integer LANGUAGE plpgsql
SET search_path = pg_catalog,
    ledger AS $$
DECLARE i integer;
v_month date;
v_created integer := 0;
BEGIN FOR i IN 0..p_months_ahead LOOP v_month := (
    date_trunc('month', timezone('UTC', now())) + make_interval(months => i)
)::date;
IF to_regclass(
    format(
        'ledger.%I',
        'entries_' || to_char(v_month, 'YYYY_MM')
    )
) IS NULL THEN PERFORM ledger.create_entries_partition(v_month);
v_created := v_created + 1;
END IF;
END LOOP;
RETURN v_created;
END $$;
REVOKE ALL ON FUNCTION ledger.attach_entries_guards(name)
FROM PUBLIC;
REVOKE ALL ON FUNCTION ledger.create_entries_partition(date, boolean)
FROM PUBLIC;
REVOKE ALL ON FUNCTION ledger.ensure_entries_partitions(integer)
FROM PUBLIC;
-- 4. Create partitions for all existing data (no guards yet: the copy below must NOT
--    fire the balance trigger, or balances would be counted twice), then copy.
CREATE TABLE ledger.entries_default PARTITION OF ledger.entries DEFAULT;
DO $$
DECLARE v_m date;
v_last date;
BEGIN
SELECT date_trunc(
        'month',
        timezone('UTC', COALESCE(min(created_at), now()))
    )::date INTO v_m
FROM ledger.entries_old;
v_last := (
    date_trunc('month', timezone('UTC', now())) + interval '3 months'
)::date;
WHILE v_m <= v_last LOOP PERFORM ledger.create_entries_partition(v_m, false);
v_m := (v_m + interval '1 month')::date;
END LOOP;
END $$;
INSERT INTO ledger.entries (
        id,
        transaction_id,
        account_id,
        currency,
        direction,
        amount,
        created_at
    )
SELECT id,
    transaction_id,
    account_id,
    currency,
    direction,
    amount,
    created_at
FROM ledger.entries_old
ORDER BY id;
SELECT setval(
        'ledger.entry_id_seq',
        COALESCE(
            (
                SELECT max(id)
                FROM ledger.entries
            ),
            0
        ) + 1,
        false
    );
DROP TABLE ledger.entries_old;
-- 5. Guards on every partition (default included) and a TRUNCATE guard on the parent.
DO $$
DECLARE r record;
BEGIN FOR r IN
SELECT c.relname
FROM pg_inherits i
    JOIN pg_class c ON c.oid = i.inhrelid
WHERE i.inhparent = 'ledger.entries'::regclass LOOP PERFORM ledger.attach_entries_guards(r.relname);
END LOOP;
END $$;
CREATE TRIGGER entries_no_truncate BEFORE TRUNCATE ON ledger.entries FOR EACH STATEMENT EXECUTE FUNCTION ledger.reject_mutation();
-- FK-referencing column index, defined on the parent: PostgreSQL builds it on every
-- partition and automatically on partitions created later.
CREATE INDEX entries_transaction_id_idx ON ledger.entries (transaction_id);
-- The app may read entries. It still cannot write them (functions only).
GRANT SELECT ON ledger.entries TO ledger_app;
RESET ROLE;
-- migrate:down
-- Restores the original single table with all its data and guards.
SET LOCAL ROLE ledger_owner;
CREATE TABLE ledger.entries_flat (
    id bigint GENERATED ALWAYS AS IDENTITY,
    transaction_id uuid NOT NULL,
    account_id uuid NOT NULL,
    currency ledger.currency_code NOT NULL,
    direction char(1) NOT NULL,
    amount ledger.money_positive NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT entries_flat_pkey PRIMARY KEY (id),
    CONSTRAINT entries_direction_valid CHECK (direction IN ('D', 'C')),
    CONSTRAINT entries_transaction_id_fkey FOREIGN KEY (transaction_id) REFERENCES ledger.transactions (id),
    CONSTRAINT entries_account_currency_fk FOREIGN KEY (account_id, currency) REFERENCES ledger.accounts (id, currency)
);
INSERT INTO ledger.entries_flat (
        id,
        transaction_id,
        account_id,
        currency,
        direction,
        amount,
        created_at
    ) OVERRIDING SYSTEM VALUE
SELECT id,
    transaction_id,
    account_id,
    currency,
    direction,
    amount,
    created_at
FROM ledger.entries;
SELECT setval(
        pg_get_serial_sequence('ledger.entries_flat', 'id'),
        COALESCE(
            (
                SELECT max(id)
                FROM ledger.entries_flat
            ),
            0
        ) + 1,
        false
    );
DROP TABLE ledger.entries;
-- drops every partition; drop is not blocked by our guards
ALTER TABLE ledger.entries_flat
    RENAME TO entries;
ALTER INDEX ledger.entries_flat_pkey
RENAME TO entries_pkey;
CREATE INDEX entries_transaction_id_idx ON ledger.entries (transaction_id);
CREATE CONSTRAINT TRIGGER entries_balanced_check
AFTER
INSERT ON ledger.entries DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ledger.assert_transaction_balanced();
CREATE TRIGGER entries_apply_balance
AFTER
INSERT ON ledger.entries FOR EACH ROW EXECUTE FUNCTION ledger.apply_entry_to_balance();
CREATE TRIGGER entries_immutable BEFORE
UPDATE
    OR DELETE ON ledger.entries FOR EACH ROW EXECUTE FUNCTION ledger.reject_mutation();
CREATE TRIGGER entries_no_truncate BEFORE TRUNCATE ON ledger.entries FOR EACH STATEMENT EXECUTE FUNCTION ledger.reject_mutation();
GRANT SELECT ON ledger.entries TO ledger_app;
DROP FUNCTION ledger.ensure_entries_partitions(integer);
DROP FUNCTION ledger.create_entries_partition(date, boolean);
DROP FUNCTION ledger.attach_entries_guards(name);
RESET ROLE;