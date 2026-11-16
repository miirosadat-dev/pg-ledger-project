-- Phase 3 invariant tests (plain SQL; pgTAP comes in CI later).
-- Everything runs inside ONE transaction that is rolled back at the end, so the
-- database is left untouched. Any failed expectation aborts the script (ON_ERROR_STOP).
BEGIN;
-- ---- helpers (pg_temp = visible only to this session, gone afterwards) --------
-- expect_fail: run a statement, force deferred triggers to fire NOW, require that it
-- raises exactly the expected SQLSTATE. The inner BEGIN..EXCEPTION block is a
-- subtransaction, so the failed attempt's rows are rolled back automatically.
CREATE FUNCTION pg_temp.expect_fail(p_label text, p_sql text, p_state text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_state text;
BEGIN BEGIN EXECUTE p_sql;
SET CONSTRAINTS ALL IMMEDIATE;
-- fire the deferred triggers here
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
-- expect_ok: run a statement that must succeed, including its deferred checks.
CREATE FUNCTION pg_temp.expect_ok(p_label text, p_sql text) RETURNS void LANGUAGE plpgsql AS $$ BEGIN EXECUTE p_sql;
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
-- restore normal behaviour
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
-- ---- fixtures: a platform cash account, a USD wallet and a EUR wallet ----------
INSERT INTO ledger.accounts (
        id,
        owner_ref,
        name,
        type,
        currency,
        allow_negative
    )
VALUES (
        '00000000-0000-0000-0000-0000000000a1',
        NULL,
        'test cash',
        'asset',
        'USD',
        true
    ),
    (
        '00000000-0000-0000-0000-0000000000a2',
        'u1',
        'test wallet',
        'liability',
        'USD',
        false
    ),
    (
        '00000000-0000-0000-0000-0000000000a3',
        'u1',
        'test wallet eur',
        'liability',
        'EUR',
        false
    );
SELECT pg_temp.assert_eq(
        'new accounts automatically get a balance row',
        (
            SELECT count(*)
            FROM ledger.account_balances
            WHERE account_id IN (
                    '00000000-0000-0000-0000-0000000000a1',
                    '00000000-0000-0000-0000-0000000000a2',
                    '00000000-0000-0000-0000-0000000000a3'
                )
        ),
        3
    );
-- ---- invariant 1 / 2-entry rule: balance ----------------------------------------
SELECT pg_temp.expect_fail(
        'unbalanced transaction is rejected',
        $q$
        INSERT INTO ledger.transactions (id, type)
        VALUES (
                '00000000-0000-0000-0000-0000000000b1',
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
        '00000000-0000-0000-0000-0000000000b1',
        '00000000-0000-0000-0000-0000000000a1',
        'USD',
        'D',
        100
    ),
    (
        '00000000-0000-0000-0000-0000000000b1',
        '00000000-0000-0000-0000-0000000000a2',
        'USD',
        'C',
        90
    );
$q$,
'LD001'
);
SELECT pg_temp.expect_fail(
        'single-entry transaction is rejected',
        $q$
        INSERT INTO ledger.transactions (id, type)
        VALUES (
                '00000000-0000-0000-0000-0000000000b2',
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
        '00000000-0000-0000-0000-0000000000b2',
        '00000000-0000-0000-0000-0000000000a1',
        'USD',
        'D',
        100
    );
$q$,
'LD002'
);
SELECT pg_temp.expect_fail(
        'transaction header with no entries is rejected',
        $q$
        INSERT INTO ledger.transactions (id, type)
        VALUES (
                '00000000-0000-0000-0000-0000000000b3',
                'adjustment'
            );
$q$,
'LD002'
);
SELECT pg_temp.expect_fail(
        'USD debit cannot be offset by a EUR credit (balanced per currency)',
        $q$
        INSERT INTO ledger.transactions (id, type)
        VALUES (
                '00000000-0000-0000-0000-0000000000b4',
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
        '00000000-0000-0000-0000-0000000000b4',
        '00000000-0000-0000-0000-0000000000a1',
        'USD',
        'D',
        100
    ),
    (
        '00000000-0000-0000-0000-0000000000b4',
        '00000000-0000-0000-0000-0000000000a3',
        'EUR',
        'C',
        100
    );
$q$,
'LD001'
);
-- ---- invariant 5: currency safety (composite FK) and positive amounts ------------
SELECT pg_temp.expect_fail(
        'entry currency must match account currency',
        $q$
        INSERT INTO ledger.transactions (id, type)
        VALUES (
                '00000000-0000-0000-0000-0000000000b7',
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
        '00000000-0000-0000-0000-0000000000b7',
        '00000000-0000-0000-0000-0000000000a1',
        'EUR',
        'D',
        100
    );
$q$,
'23503'
);
SELECT pg_temp.expect_fail(
        'zero amount is rejected',
        $q$
        INSERT INTO ledger.transactions (id, type)
        VALUES (
                '00000000-0000-0000-0000-0000000000b8',
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
        '00000000-0000-0000-0000-0000000000b8',
        '00000000-0000-0000-0000-0000000000a1',
        'USD',
        'D',
        0
    );
$q$,
'23514'
);
-- ---- happy path + balance maintenance (invariant 7) ------------------------------
SELECT pg_temp.expect_ok(
        'balanced deposit is accepted',
        $q$
        INSERT INTO ledger.transactions (id, type)
        VALUES (
                '00000000-0000-0000-0000-0000000000b5',
                'deposit'
            );
INSERT INTO ledger.entries (
        transaction_id,
        account_id,
        currency,
        direction,
        amount
    )
VALUES (
        '00000000-0000-0000-0000-0000000000b5',
        '00000000-0000-0000-0000-0000000000a1',
        'USD',
        'D',
        1000
    ),
    (
        '00000000-0000-0000-0000-0000000000b5',
        '00000000-0000-0000-0000-0000000000a2',
        'USD',
        'C',
        1000
    );
$q$
);
SELECT pg_temp.assert_eq(
        'cash (asset, debit-normal) balance = 1000',
        (
            SELECT balance
            FROM ledger.account_balances
            WHERE account_id = '00000000-0000-0000-0000-0000000000a1'
        ),
        1000
    );
SELECT pg_temp.assert_eq(
        'wallet (liability, credit-normal) balance = 1000',
        (
            SELECT balance
            FROM ledger.account_balances
            WHERE account_id = '00000000-0000-0000-0000-0000000000a2'
        ),
        1000
    );
-- ---- invariant 4: no overdraft ----------------------------------------------------
SELECT pg_temp.expect_fail(
        'overdraft on a non-overdraftable wallet is rejected',
        $q$
        INSERT INTO ledger.transactions (id, type)
        VALUES (
                '00000000-0000-0000-0000-0000000000b9',
                'withdrawal'
            );
INSERT INTO ledger.entries (
        transaction_id,
        account_id,
        currency,
        direction,
        amount
    )
VALUES (
        '00000000-0000-0000-0000-0000000000b9',
        '00000000-0000-0000-0000-0000000000a2',
        'USD',
        'D',
        5000
    ),
    (
        '00000000-0000-0000-0000-0000000000b9',
        '00000000-0000-0000-0000-0000000000a1',
        'USD',
        'C',
        5000
    );
$q$,
'23514'
);
-- ---- invariant 2: immutability (triggers fire even for the superuser) -------------
SELECT pg_temp.expect_fail(
        'UPDATE on entries is rejected',
        $q$
        UPDATE ledger.entries
        SET amount = 1 $q$,
            'LD003'
    );
SELECT pg_temp.expect_fail(
        'DELETE on entries is rejected',
        $q$
        DELETE FROM ledger.entries $q$,
            'LD003'
    );
SELECT pg_temp.expect_fail(
        'TRUNCATE on entries is rejected',
        $q$ TRUNCATE ledger.entries $q$,
        'LD003'
    );
SELECT pg_temp.expect_fail(
        'UPDATE on transactions is rejected',
        $q$
        UPDATE ledger.transactions
        SET description = 'x' $q$,
            'LD003'
    );
SELECT pg_temp.expect_fail(
        'DELETE on transactions is rejected',
        $q$
        DELETE FROM ledger.transactions $q$,
            'LD003'
    );
SELECT pg_temp.expect_fail(
        'TRUNCATE on transactions+entries is rejected',
        $q$ TRUNCATE ledger.entries,
        ledger.transactions $q$,
        'LD003'
    );
-- ---- least privilege: ledger_app is stopped BEFORE any trigger runs (42501) -------
SELECT pg_temp.expect_fail(
        'ledger_app cannot UPDATE entries',
        $q$
        SET LOCAL ROLE ledger_app;
UPDATE ledger.entries
SET amount = 1 $q$,
    '42501'
);
SELECT pg_temp.expect_fail(
        'ledger_app cannot DELETE transactions',
        $q$
        SET LOCAL ROLE ledger_app;
DELETE FROM ledger.transactions $q$,
    '42501'
);
SELECT pg_temp.expect_fail(
        'ledger_app cannot write balances directly',
        $q$
        SET LOCAL ROLE ledger_app;
UPDATE ledger.account_balances
SET balance = 999999 $q$,
    '42501'
);
SELECT pg_temp.expect_fail(
        'ledger_app cannot change account allow_negative',
        $q$
        SET LOCAL ROLE ledger_app;
UPDATE ledger.accounts
SET allow_negative = true $q$,
    '42501'
);
DO $$ BEGIN RAISE NOTICE 'ALL PHASE 3 TESTS PASSED';
END $$;
-- Leave no trace.
ROLLBACK;