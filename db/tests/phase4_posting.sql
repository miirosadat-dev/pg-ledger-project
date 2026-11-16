-- Phase 4 posting tests. One transaction, rolled back at the end (database left clean).
-- Calls run as ledger_app to prove the real API role can do exactly what it should.
BEGIN;
-- ---- helpers (session-local) ------------------------------------------------------
CREATE FUNCTION pg_temp.expect_fail(p_label text, p_sql text, p_state text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_state text;
BEGIN BEGIN EXECUTE p_sql;
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
-- ---- fixtures: cash (c1), wallets A (c2) and B (c3), EUR wallet (c4), frozen wallet (c5)
INSERT INTO ledger.accounts (
        id,
        owner_ref,
        name,
        type,
        currency,
        allow_negative,
        status
    )
VALUES (
        '00000000-0000-0000-0000-0000000000c1',
        NULL,
        'cash',
        'asset',
        'USD',
        true,
        'active'
    ),
    (
        '00000000-0000-0000-0000-0000000000c2',
        'ua',
        'wallet',
        'liability',
        'USD',
        false,
        'active'
    ),
    (
        '00000000-0000-0000-0000-0000000000c3',
        'ub',
        'wallet',
        'liability',
        'USD',
        false,
        'active'
    ),
    (
        '00000000-0000-0000-0000-0000000000c4',
        'ua',
        'wallet',
        'liability',
        'EUR',
        false,
        'active'
    ),
    (
        '00000000-0000-0000-0000-0000000000c5',
        'uf',
        'wallet',
        'liability',
        'USD',
        false,
        'frozen'
    );
-- ---- deposit: posts once, replay returns the original ------------------------------
DO $$
DECLARE r1 jsonb;
r2 jsonb;
BEGIN
SET LOCAL ROLE ledger_app;
r1 := ledger.deposit(
    '00000000-0000-0000-0000-0000000000c2',
    '00000000-0000-0000-0000-0000000000c1',
    10000,
    'USD',
    'k-dep-1',
    'tester',
    'seed money'
);
r2 := ledger.deposit(
    '00000000-0000-0000-0000-0000000000c2',
    '00000000-0000-0000-0000-0000000000c1',
    10000,
    'USD',
    'k-dep-1',
    'tester',
    'seed money'
);
RESET ROLE;
IF (r1->>'replayed')::boolean THEN RAISE EXCEPTION 'FAIL - the first deposit must not be flagged as a replay';
END IF;
IF NOT (r2->>'replayed')::boolean
OR r2->>'transaction_id' <> r1->>'transaction_id' THEN RAISE EXCEPTION 'FAIL - the replay must return the original transaction id';
END IF;
RAISE NOTICE 'ok - deposit replay returns the original result';
END $$;
SELECT pg_temp.assert_eq(
        'exactly one deposit transaction exists',
        (
            SELECT count(*)
            FROM ledger.transactions
            WHERE idempotency_key = 'k-dep-1'
        ),
        1
    );
SELECT pg_temp.assert_eq(
        'wallet A = 10000 (posted once, not twice)',
        (
            SELECT balance
            FROM ledger.account_balances
            WHERE account_id = '00000000-0000-0000-0000-0000000000c2'
        ),
        10000
    );
SELECT pg_temp.assert_eq(
        'cash = 10000',
        (
            SELECT balance
            FROM ledger.account_balances
            WHERE account_id = '00000000-0000-0000-0000-0000000000c1'
        ),
        10000
    );
-- ---- transfer: moves money, replay is a no-op ----------------------------------------
DO $$
DECLARE r1 jsonb;
r2 jsonb;
BEGIN
SET LOCAL ROLE ledger_app;
r1 := ledger.transfer(
    '00000000-0000-0000-0000-0000000000c2',
    '00000000-0000-0000-0000-0000000000c3',
    2500,
    'USD',
    'k-tr-1',
    'tester',
    'rent'
);
r2 := ledger.transfer(
    '00000000-0000-0000-0000-0000000000c2',
    '00000000-0000-0000-0000-0000000000c3',
    2500,
    'USD',
    'k-tr-1',
    'tester',
    'rent'
);
RESET ROLE;
IF NOT (r2->>'replayed')::boolean
OR r2->>'transaction_id' <> r1->>'transaction_id' THEN RAISE EXCEPTION 'FAIL - transfer replay must return the original transaction';
END IF;
RAISE NOTICE 'ok - transfer replay returns the original result';
END $$;
SELECT pg_temp.assert_eq(
        'wallet A = 7500 after transfer',
        (
            SELECT balance
            FROM ledger.account_balances
            WHERE account_id = '00000000-0000-0000-0000-0000000000c2'
        ),
        7500
    );
SELECT pg_temp.assert_eq(
        'wallet B = 2500 after transfer',
        (
            SELECT balance
            FROM ledger.account_balances
            WHERE account_id = '00000000-0000-0000-0000-0000000000c3'
        ),
        2500
    );
-- ---- idempotency: same key, different payload -----------------------------------------
SELECT pg_temp.expect_fail(
        'same key with a different payload is rejected',
        $q$
        SET LOCAL ROLE ledger_app;
SELECT ledger.transfer(
        '00000000-0000-0000-0000-0000000000c2',
        '00000000-0000-0000-0000-0000000000c3',
        2600,
        'USD',
        'k-tr-1',
        'tester',
        'rent'
    ) $q$,
    'LD010'
);
-- ---- overdraft: rejected, and the failed request leaves no key behind -------------------
SELECT pg_temp.expect_fail(
        'transfer beyond the balance is rejected',
        $q$
        SET LOCAL ROLE ledger_app;
SELECT ledger.transfer(
        '00000000-0000-0000-0000-0000000000c2',
        '00000000-0000-0000-0000-0000000000c3',
        99999,
        'USD',
        'k-od',
        'tester'
    ) $q$,
    'LD022'
);
SELECT pg_temp.assert_eq(
        'a failed request does not consume its idempotency key',
        (
            SELECT count(*)
            FROM ledger.idempotency_keys
            WHERE key = 'k-od'
        ),
        0
    );
SELECT pg_temp.expect_fail(
        'withdrawal beyond the balance is rejected',
        $q$
        SET LOCAL ROLE ledger_app;
SELECT ledger.withdraw(
        '00000000-0000-0000-0000-0000000000c2',
        '00000000-0000-0000-0000-0000000000c1',
        999999,
        'USD',
        'k-od2',
        'tester'
    ) $q$,
    'LD022'
);
-- ---- input and account validation ------------------------------------------------------------
SELECT pg_temp.expect_fail(
        'currency mismatch is rejected',
        $q$
        SET LOCAL ROLE ledger_app;
SELECT ledger.transfer(
        '00000000-0000-0000-0000-0000000000c2',
        '00000000-0000-0000-0000-0000000000c4',
        100,
        'USD',
        'k-cur',
        'tester'
    ) $q$,
    'LD031'
);
SELECT pg_temp.expect_fail(
        'frozen account is rejected',
        $q$
        SET LOCAL ROLE ledger_app;
SELECT ledger.transfer(
        '00000000-0000-0000-0000-0000000000c2',
        '00000000-0000-0000-0000-0000000000c5',
        100,
        'USD',
        'k-frz',
        'tester'
    ) $q$,
    'LD021'
);
SELECT pg_temp.expect_fail(
        'unknown account is rejected',
        $q$
        SET LOCAL ROLE ledger_app;
SELECT ledger.transfer(
        '00000000-0000-0000-0000-0000000000c2',
        'ffffffff-ffff-ffff-ffff-ffffffffffff',
        100,
        'USD',
        'k-404',
        'tester'
    ) $q$,
    'LD020'
);
SELECT pg_temp.expect_fail(
        'transfer to the same account is rejected',
        $q$
        SET LOCAL ROLE ledger_app;
SELECT ledger.transfer(
        '00000000-0000-0000-0000-0000000000c2',
        '00000000-0000-0000-0000-0000000000c2',
        100,
        'USD',
        'k-same',
        'tester'
    ) $q$,
    'LD030'
);
SELECT pg_temp.expect_fail(
        'zero amount is rejected',
        $q$
        SET LOCAL ROLE ledger_app;
SELECT ledger.transfer(
        '00000000-0000-0000-0000-0000000000c2',
        '00000000-0000-0000-0000-0000000000c3',
        0,
        'USD',
        'k-zero',
        'tester'
    ) $q$,
    'LD030'
);
SELECT pg_temp.expect_fail(
        'missing idempotency key is rejected',
        $q$
        SET LOCAL ROLE ledger_app;
SELECT ledger.transfer(
        '00000000-0000-0000-0000-0000000000c2',
        '00000000-0000-0000-0000-0000000000c3',
        100,
        'USD',
        NULL,
        'tester'
    ) $q$,
    'LD030'
);
-- ---- withdraw ----------------------------------------------------------------------------------------
DO $$ BEGIN
SET LOCAL ROLE ledger_app;
PERFORM ledger.withdraw(
    '00000000-0000-0000-0000-0000000000c2',
    '00000000-0000-0000-0000-0000000000c1',
    1000,
    'USD',
    'k-wd-1',
    'tester',
    'cash out'
);
RESET ROLE;
END $$;
SELECT pg_temp.assert_eq(
        'wallet A = 6500 after withdrawal',
        (
            SELECT balance
            FROM ledger.account_balances
            WHERE account_id = '00000000-0000-0000-0000-0000000000c2'
        ),
        6500
    );
SELECT pg_temp.assert_eq(
        'cash = 9000 after withdrawal',
        (
            SELECT balance
            FROM ledger.account_balances
            WHERE account_id = '00000000-0000-0000-0000-0000000000c1'
        ),
        9000
    );
-- ---- reversal -------------------------------------------------------------------------------------------
DO $$
DECLARE v_orig uuid;
r1 jsonb;
r2 jsonb;
BEGIN
SET LOCAL ROLE ledger_app;
SELECT id INTO v_orig
FROM ledger.transactions
WHERE idempotency_key = 'k-tr-1';
r1 := ledger.reverse_transaction(v_orig, 'k-rev-1', 'tester', 'wrong recipient');
r2 := ledger.reverse_transaction(v_orig, 'k-rev-1', 'tester', 'wrong recipient');
RESET ROLE;
IF NOT (r2->>'replayed')::boolean
OR r2->>'transaction_id' <> r1->>'transaction_id' THEN RAISE EXCEPTION 'FAIL - reversal replay must return the original reversal';
END IF;
RAISE NOTICE 'ok - reversal posted and its replay returns the same result';
END $$;
SELECT pg_temp.assert_eq(
        'wallet A = 9000 after reversal',
        (
            SELECT balance
            FROM ledger.account_balances
            WHERE account_id = '00000000-0000-0000-0000-0000000000c2'
        ),
        9000
    );
SELECT pg_temp.assert_eq(
        'wallet B = 0 after reversal',
        (
            SELECT balance
            FROM ledger.account_balances
            WHERE account_id = '00000000-0000-0000-0000-0000000000c3'
        ),
        0
    );
SELECT pg_temp.expect_fail(
        'a second reversal (new key) is rejected',
        $q$
        SET LOCAL ROLE ledger_app;
SELECT ledger.reverse_transaction(
        (
            SELECT id
            FROM ledger.transactions
            WHERE idempotency_key = 'k-tr-1'
        ),
        'k-rev-2'
    ) $q$,
    'LD041'
);
SELECT pg_temp.expect_fail(
        'a reversal cannot be reversed',
        $q$
        SET LOCAL ROLE ledger_app;
SELECT ledger.reverse_transaction(
        (
            SELECT id
            FROM ledger.transactions
            WHERE type = 'reversal'
        ),
        'k-rev-3'
    ) $q$,
    'LD042'
);
SELECT pg_temp.expect_fail(
        'reversing an unknown transaction is rejected',
        $q$
        SET LOCAL ROLE ledger_app;
SELECT ledger.reverse_transaction(
        'ffffffff-ffff-ffff-ffff-ffffffffffff',
        'k-rev-4'
    ) $q$,
    'LD040'
);
-- ---- the API boundary: functions only ------------------------------------------------------------------
SELECT pg_temp.expect_fail(
        'ledger_app cannot INSERT into transactions directly',
        $q$
        SET LOCAL ROLE ledger_app;
INSERT INTO ledger.transactions (type)
VALUES ('adjustment') $q$,
    '42501'
);
SELECT pg_temp.expect_fail(
        'ledger_app cannot INSERT into entries directly',
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
        '00000000-0000-0000-0000-0000000000c1',
        'USD',
        'D',
        1
    ) $q$,
    '42501'
);
SELECT pg_temp.expect_fail(
        'ledger_app cannot call post_transaction directly',
        $q$
        SET LOCAL ROLE ledger_app;
SELECT ledger.post_transaction('k', '{}'::jsonb, 'adjustment', '[]'::jsonb) $q$,
    '42501'
);
-- ---- global invariants over everything posted above ---------------------------------------------------------
SELECT pg_temp.assert_eq(
        'total debits = total credits across all entries',
        (
            SELECT COALESCE(
                    sum(
                        CASE
                            direction
                            WHEN 'D' THEN e.amount::bigint
                            ELSE -(e.amount::bigint)
                        END
                    ),
                    0
                )::bigint
            FROM ledger.entries e
        ),
        0
    );
SELECT pg_temp.assert_eq(
        'every cached balance equals the sum of its entries (reconciliation)',
        (
            SELECT count(*)
            FROM ledger.account_balances b
                JOIN ledger.accounts a ON a.id = b.account_id
            WHERE b.balance <> COALESCE(
                    (
                        SELECT sum(
                                CASE
                                    WHEN e.direction = a.normal_side THEN e.amount::bigint
                                    ELSE -(e.amount::bigint)
                                END
                            )
                        FROM ledger.entries e
                        WHERE e.account_id = a.id
                    ),
                    0
                )
        ),
        0
    );
DO $$ BEGIN RAISE NOTICE 'ALL PHASE 4 TESTS PASSED';
END $$;
ROLLBACK;