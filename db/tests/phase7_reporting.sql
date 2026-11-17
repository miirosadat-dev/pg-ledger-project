-- Phase 7A tests: partitioning, statements, trial balance, reconciliation.
-- One transaction, rolled back at the end.
BEGIN;
CREATE FUNCTION pg_temp.expect_fail(p_label text, p_sql text, p_state text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_state text;
BEGIN BEGIN EXECUTE p_sql;
SET CONSTRAINTS ALL IMMEDIATE;
v_state := NULL;
EXCEPTION
WHEN OTHERS THEN v_state := SQLSTATE;
END;
IF v_state IS NULL THEN RAISE EXCEPTION 'FAIL - %: no error was raised',
p_label;
ELSIF v_state <> p_state THEN RAISE EXCEPTION 'FAIL - %: expected SQLSTATE %, got %',
p_label,
p_state,
v_state;
END IF;
RAISE NOTICE 'ok - %',
p_label;
END $$;
CREATE FUNCTION pg_temp.assert_eq(p_label text, p_actual bigint, p_expected bigint) RETURNS void LANGUAGE plpgsql AS $$ BEGIN IF p_actual IS DISTINCT
FROM p_expected THEN RAISE EXCEPTION 'FAIL - %: expected %, got %',
    p_label,
    p_expected,
    p_actual;
END IF;
RAISE NOTICE 'ok - %',
p_label;
END $$;
CREATE FUNCTION pg_temp.assert_text(p_label text, p_actual text, p_expected text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN IF p_actual IS DISTINCT
FROM p_expected THEN RAISE EXCEPTION 'FAIL - %: expected %, got %',
    p_label,
    p_expected,
    p_actual;
END IF;
RAISE NOTICE 'ok - %',
p_label;
END $$;
-- f1 cash, f2 wallet (statement tests); f3 cash, f4 wallet (partition tests)
INSERT INTO ledger.accounts (
        id,
        owner_ref,
        name,
        type,
        currency,
        allow_negative
    )
VALUES (
        '00000000-0000-0000-0000-0000000000f1',
        NULL,
        'test-rep-cash',
        'asset',
        'USD',
        true
    ),
    (
        '00000000-0000-0000-0000-0000000000f2',
        'test-rep',
        'test-rep-wallet',
        'liability',
        'USD',
        false
    ),
    (
        '00000000-0000-0000-0000-0000000000f3',
        NULL,
        'test-rep-cash2',
        'asset',
        'USD',
        true
    ),
    (
        '00000000-0000-0000-0000-0000000000f4',
        'test-rep',
        'test-rep-wallet2',
        'liability',
        'USD',
        false
    );
-- ---- partition structure ------------------------------------------------------------
SELECT pg_temp.assert_eq(
        'entries is a partitioned table',
        (
            SELECT count(*)
            FROM pg_partitioned_table
            WHERE partrelid = 'ledger.entries'::regclass
        ),
        1
    );
SELECT pg_temp.assert_eq(
        'a default partition exists',
        (
            SELECT (
                    to_regclass('ledger.entries_default') IS NOT NULL
                )::int
        ),
        1
    );
SELECT pg_temp.assert_eq(
        'the current month already has a partition',
        (
            SELECT count(*)
            FROM pg_inherits i
                JOIN pg_class c ON c.oid = i.inhrelid
            WHERE i.inhparent = 'ledger.entries'::regclass
                AND c.relname = 'entries_' || to_char(timezone('UTC', now()), 'YYYY_MM')
        ),
        1
    );
-- ---- statement with a running balance ---------------------------------------------------
-- A back-dated entry (month start) plus three postings through the real functions.
INSERT INTO ledger.transactions (id, type)
VALUES (
        '00000000-0000-0000-0000-00000000aa01',
        'deposit'
    );
INSERT INTO ledger.entries (
        transaction_id,
        account_id,
        currency,
        direction,
        amount,
        created_at
    )
VALUES (
        '00000000-0000-0000-0000-00000000aa01',
        '00000000-0000-0000-0000-0000000000f1',
        'USD',
        'D',
        2000,
        date_trunc('month', now())
    ),
    (
        '00000000-0000-0000-0000-00000000aa01',
        '00000000-0000-0000-0000-0000000000f2',
        'USD',
        'C',
        2000,
        date_trunc('month', now())
    );
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
DO $$ BEGIN
SET LOCAL ROLE ledger_app;
PERFORM ledger.deposit (
    '00000000-0000-0000-0000-0000000000f2',
    '00000000-0000-0000-0000-0000000000f1',
    10000,
    'USD',
    'rep-d1',
    'tester'
);
PERFORM ledger.withdraw(
    '00000000-0000-0000-0000-0000000000f2',
    '00000000-0000-0000-0000-0000000000f1',
    3000,
    'USD',
    'rep-w1',
    'tester'
);
PERFORM ledger.deposit (
    '00000000-0000-0000-0000-0000000000f2',
    '00000000-0000-0000-0000-0000000000f1',
    500,
    'USD',
    'rep-d2',
    'tester'
);
RESET ROLE;
END $$;
SELECT pg_temp.assert_text(
        'full statement running balances',
        (
            SELECT string_agg(
                    running_balance::text,
                    ','
                    ORDER BY posted_at,
                        entry_id
                )
            FROM ledger.account_statement('00000000-0000-0000-0000-0000000000f2')
        ),
        '2000,12000,9000,9500'
    );
SELECT pg_temp.assert_text(
        'statement from a later date starts from the opening balance',
        (
            SELECT string_agg(
                    running_balance::text,
                    ','
                    ORDER BY posted_at,
                        entry_id
                )
            FROM ledger.account_statement(
                    '00000000-0000-0000-0000-0000000000f2',
                    date_trunc('month', now()) + interval '1 microsecond'
                )
        ),
        '12000,9000,9500'
    );
SELECT pg_temp.assert_text(
        'LIMIT does not distort the running balance',
        (
            SELECT string_agg(
                    running_balance::text,
                    ','
                    ORDER BY posted_at,
                        entry_id
                )
            FROM ledger.account_statement(
                    '00000000-0000-0000-0000-0000000000f2',
                    NULL,
                    NULL,
                    2
                )
        ),
        '2000,12000'
    );
SELECT pg_temp.assert_eq(
        'statement debit column sums to the withdrawal (3000)',
        (
            SELECT sum(debit)::bigint
            FROM ledger.account_statement('00000000-0000-0000-0000-0000000000f2')
        ),
        3000
    );
SELECT pg_temp.assert_eq(
        'statement credit column sums to all deposits (12500)',
        (
            SELECT sum(credit)::bigint
            FROM ledger.account_statement('00000000-0000-0000-0000-0000000000f2')
        ),
        12500
    );
SELECT pg_temp.assert_eq(
        'statement of an unknown account is empty',
        (
            SELECT count(*)
            FROM ledger.account_statement('ffffffff-ffff-ffff-ffff-ffffffffffff')
        ),
        0
    );
-- ---- partition helpers and routing ---------------------------------------------------------
SELECT pg_temp.assert_text(
        'create_entries_partition returns the partition name',
        ledger.create_entries_partition('2031-02-15'),
        'entries_2031_02'
    );
SELECT pg_temp.assert_text(
        'create_entries_partition is idempotent',
        ledger.create_entries_partition('2031-02-01'),
        'entries_2031_02'
    );
SELECT pg_temp.assert_eq(
        'new partitions receive the four ledger guards',
        (
            SELECT count(*)
            FROM pg_trigger
            WHERE tgrelid = 'ledger.entries_2031_02'::regclass
                AND NOT tgisinternal
        ),
        4
    );
INSERT INTO ledger.transactions (id, type)
VALUES (
        '00000000-0000-0000-0000-00000000aa02',
        'deposit'
    );
INSERT INTO ledger.entries (
        transaction_id,
        account_id,
        currency,
        direction,
        amount,
        created_at
    )
VALUES (
        '00000000-0000-0000-0000-00000000aa02',
        '00000000-0000-0000-0000-0000000000f3',
        'USD',
        'D',
        100,
        '2031-02-10 12:00:00+00'
    ),
    (
        '00000000-0000-0000-0000-00000000aa02',
        '00000000-0000-0000-0000-0000000000f4',
        'USD',
        'C',
        100,
        '2031-02-10 12:00:00+00'
    );
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
SELECT pg_temp.assert_eq(
        'rows are routed into the matching partition',
        (
            SELECT count(*)
            FROM ledger.entries_2031_02
        ),
        2
    );
SELECT pg_temp.assert_eq(
        'ensure_entries_partitions creates nothing twice',
        (
            SELECT ledger.ensure_entries_partitions(2) - ledger.ensure_entries_partitions(2) + ledger.ensure_entries_partitions(2)
        ),
        0
    );
-- ---- guards still hold on partitions -----------------------------------------------------------
SELECT pg_temp.expect_fail(
        'unbalanced entries in a partition are rejected',
        $q$
        INSERT INTO ledger.transactions (id, type)
        VALUES (
                '00000000-0000-0000-0000-00000000aa03',
                'transfer'
            );
INSERT INTO ledger.entries (
        transaction_id,
        account_id,
        currency,
        direction,
        amount,
        created_at
    )
VALUES (
        '00000000-0000-0000-0000-00000000aa03',
        '00000000-0000-0000-0000-0000000000f3',
        'USD',
        'D',
        100,
        '2031-02-11 00:00:00+00'
    ),
    (
        '00000000-0000-0000-0000-00000000aa03',
        '00000000-0000-0000-0000-0000000000f4',
        'USD',
        'C',
        90,
        '2031-02-11 00:00:00+00'
    ) $q$,
    'LD001'
);
SELECT pg_temp.expect_fail(
        'currency mismatch is still rejected',
        $q$
        INSERT INTO ledger.transactions (id, type)
        VALUES (
                '00000000-0000-0000-0000-00000000aa04',
                'transfer'
            );
INSERT INTO ledger.entries (
        transaction_id,
        account_id,
        currency,
        direction,
        amount
    )
VALUES (
        '00000000-0000-0000-0000-00000000aa04',
        '00000000-0000-0000-0000-0000000000f3',
        'EUR',
        'D',
        100
    ) $q$,
    '23503'
);
SELECT pg_temp.expect_fail(
        'UPDATE through the parent is rejected',
        $q$
        UPDATE ledger.entries
        SET amount = 1 $q$,
            'LD003'
    );
SELECT pg_temp.expect_fail(
        'DELETE through the parent is rejected',
        $q$
        DELETE FROM ledger.entries $q$,
            'LD003'
    );
SELECT pg_temp.expect_fail(
        'TRUNCATE of the parent is rejected',
        $q$ TRUNCATE ledger.entries $q$,
        'LD003'
    );
SELECT pg_temp.expect_fail(
        'TRUNCATE aimed at one partition is rejected',
        $q$ TRUNCATE ledger.entries_2031_02 $q$,
        'LD003'
    );
SELECT pg_temp.expect_fail(
        'ledger_app still cannot insert entries directly',
        $q$
        SET LOCAL ROLE ledger_app;
INSERT INTO ledger.entries (
        transaction_id,
        account_id,
        currency,
        direction,
        amount
    )
VALUES (
        gen_random_uuid(),
        '00000000-0000-0000-0000-0000000000f1',
        'USD',
        'D',
        1
    ) $q$,
    '42501'
);
-- ---- trial balance --------------------------------------------------------------------------------------
DO $$ BEGIN
SET LOCAL ROLE ledger_app;
PERFORM ledger.refresh_trial_balance();
-- the app may refresh the view
RESET ROLE;
END $$;
SELECT pg_temp.assert_eq(
        'trial balance shows the wallet credit balance (9500)',
        (
            SELECT credit_balance
            FROM ledger.trial_balance
            WHERE account_id = '00000000-0000-0000-0000-0000000000f2'
        ),
        9500
    );
SELECT pg_temp.assert_eq(
        'trial balance: total debit balances = total credit balances (USD)',
        (
            SELECT sum(debit_balance) - sum(credit_balance)
            FROM ledger.trial_balance
            WHERE currency = 'USD'
        )::bigint,
        0
    );
SELECT pg_temp.expect_fail(
        'ledger_app cannot write the trial balance',
        $q$
        SET LOCAL ROLE ledger_app;
DELETE FROM ledger.trial_balance $q$,
    '42501'
);
SELECT pg_temp.expect_fail(
        'ledger_readonly cannot refresh the trial balance',
        $q$
        SET LOCAL ROLE ledger_readonly;
SELECT ledger.refresh_trial_balance() $q$,
    '42501'
);
-- ---- read-only role can run reports ------------------------------------------------------------------------
DO $$
DECLARE n integer;
BEGIN
SET LOCAL ROLE ledger_readonly;
SELECT count(*) INTO n
FROM ledger.account_statement('00000000-0000-0000-0000-0000000000f2');
IF n <> 4 THEN RAISE EXCEPTION 'FAIL - ledger_readonly statement returned % rows, expected 4',
n;
END IF;
PERFORM count(*)
FROM ledger.reconcile();
RESET ROLE;
RAISE NOTICE 'ok - ledger_readonly can run statements and reconciliation';
END $$;
-- ---- reconciliation: healthy, then deliberately corrupted ---------------------------------------------------
SELECT pg_temp.assert_eq(
        'reconcile() reports no discrepancies on a healthy ledger',
        (
            SELECT count(*)
            FROM ledger.reconcile()
        ),
        0
    );
-- Corrupt a cached balance directly (possible only as a superuser) and watch it get caught.
UPDATE ledger.account_balances
SET balance = balance + 1
WHERE account_id = '00000000-0000-0000-0000-0000000000f2';
SELECT pg_temp.assert_eq(
        'reconcile() catches a tampered cached balance',
        (
            SELECT count(*)
            FROM ledger.reconcile()
            WHERE check_name = 'balance_matches_entries'
                AND subject = '00000000-0000-0000-0000-0000000000f2'
        ),
        1
    );
DO $$ BEGIN RAISE NOTICE 'ALL PHASE 7A TESTS PASSED';
END $$;
ROLLBACK;