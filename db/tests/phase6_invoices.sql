-- Phase 6 invoice tests. One transaction, rolled back at the end. Fixture accounts have
-- test-specific names so they cannot collide with real data.
BEGIN;
CREATE FUNCTION pg_temp.expect_fail(p_label text, p_sql text, p_state text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_state text;
BEGIN BEGIN EXECUTE p_sql;
SET CONSTRAINTS ALL IMMEDIATE;
-- fire deferred triggers now
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
-- e1 cash (asset), e2 customer wallet (liability), e3 receivable (asset, no overdraft),
-- e4 revenue (revenue, may go negative after credit notes)
INSERT INTO ledger.accounts (
        id,
        owner_ref,
        name,
        type,
        currency,
        allow_negative
    )
VALUES (
        '00000000-0000-0000-0000-0000000000e1',
        NULL,
        'test-inv-cash',
        'asset',
        'USD',
        true
    ),
    (
        '00000000-0000-0000-0000-0000000000e2',
        'test-cust',
        'test-inv-wallet',
        'liability',
        'USD',
        false
    ),
    (
        '00000000-0000-0000-0000-0000000000e3',
        NULL,
        'test-inv-receivable',
        'asset',
        'USD',
        false
    ),
    (
        '00000000-0000-0000-0000-0000000000e4',
        NULL,
        'test-inv-revenue',
        'revenue',
        'USD',
        true
    );
-- Fund the wallet with 10000.
DO $$ BEGIN
SET LOCAL ROLE ledger_app;
PERFORM ledger.deposit(
    '00000000-0000-0000-0000-0000000000e2',
    '00000000-0000-0000-0000-0000000000e1',
    10000,
    'USD',
    'inv-fund',
    'tester'
);
RESET ROLE;
END $$;
-- ---- create invoice 1 (total 5000 = 2 x 1500 + 1 x 2000) and replay it -------------
DO $$
DECLARE r1 jsonb;
r2 jsonb;
BEGIN
SET LOCAL ROLE ledger_app;
r1 := ledger.create_invoice(
    '00000000-0000-0000-0000-0000000000e2',
    '00000000-0000-0000-0000-0000000000e3',
    '00000000-0000-0000-0000-0000000000e4',
    'USD',
    '[{"description":"Widget","quantity":2,"unit_amount":1500},{"description":"Setup","quantity":1,"unit_amount":2000}]'::jsonb,
    'inv-create-1',
    NULL,
    'tester'
);
r2 := ledger.create_invoice(
    '00000000-0000-0000-0000-0000000000e2',
    '00000000-0000-0000-0000-0000000000e3',
    '00000000-0000-0000-0000-0000000000e4',
    'USD',
    '[{"description":"Widget","quantity":2,"unit_amount":1500},{"description":"Setup","quantity":1,"unit_amount":2000}]'::jsonb,
    'inv-create-1',
    NULL,
    'tester'
);
RESET ROLE;
IF (r1->>'replayed')::boolean
OR NOT (r2->>'replayed')::boolean
OR r2->>'invoice_id' <> r1->>'invoice_id' THEN RAISE EXCEPTION 'FAIL - create_invoice replay must return the original invoice';
END IF;
RAISE NOTICE 'ok - create_invoice replay returns the original invoice';
END $$;
SELECT pg_temp.assert_eq(
        'exactly one invoice of 5000 exists, status issued',
        (
            SELECT count(*)
            FROM ledger.invoices
            WHERE customer_account_id = '00000000-0000-0000-0000-0000000000e2'
                AND total_amount = 5000
                AND status = 'issued'
                AND number ~ '^INV-[0-9]{6}$'
        ),
        1
    );
SELECT pg_temp.assert_eq(
        'invoice has 2 lines totalling 5000',
        (
            SELECT sum(l.line_total)::bigint
            FROM ledger.invoice_lines l
                JOIN ledger.invoices i ON i.id = l.invoice_id
            WHERE i.customer_account_id = '00000000-0000-0000-0000-0000000000e2'
                AND i.total_amount = 5000
        ),
        5000
    );
SELECT pg_temp.assert_eq(
        'receivable = 5000 after issue',
        (
            SELECT balance
            FROM ledger.account_balances
            WHERE account_id = '00000000-0000-0000-0000-0000000000e3'
        ),
        5000
    );
SELECT pg_temp.assert_eq(
        'revenue = 5000 after issue',
        (
            SELECT balance
            FROM ledger.account_balances
            WHERE account_id = '00000000-0000-0000-0000-0000000000e4'
        ),
        5000
    );
-- ---- partial payment ----------------------------------------------------------------
DO $$
DECLARE r jsonb;
BEGIN
SET LOCAL ROLE ledger_app;
r := ledger.record_invoice_payment(
    (
        SELECT id
        FROM ledger.invoices
        WHERE customer_account_id = '00000000-0000-0000-0000-0000000000e2'
            AND total_amount = 5000
    ),
    2000,
    'inv-pay-1',
    'tester'
);
RESET ROLE;
IF r->>'status' <> 'partially_paid'
OR (r->>'amount_paid')::bigint <> 2000 THEN RAISE EXCEPTION 'FAIL - expected partially_paid with 2000 paid, got %',
r;
END IF;
RAISE NOTICE 'ok - partial payment moves the invoice to partially_paid';
END $$;
SELECT pg_temp.assert_eq(
        'wallet = 8000 after partial payment',
        (
            SELECT balance
            FROM ledger.account_balances
            WHERE account_id = '00000000-0000-0000-0000-0000000000e2'
        ),
        8000
    );
SELECT pg_temp.assert_eq(
        'receivable = 3000 after partial payment',
        (
            SELECT balance
            FROM ledger.account_balances
            WHERE account_id = '00000000-0000-0000-0000-0000000000e3'
        ),
        3000
    );
-- ---- overpayment, paying the rest, replay of the final payment ----------------------------
SELECT pg_temp.expect_fail(
        'overpayment is rejected',
        $q$
        SET LOCAL ROLE ledger_app;
SELECT ledger.record_invoice_payment(
        (
            SELECT id
            FROM ledger.invoices
            WHERE customer_account_id = '00000000-0000-0000-0000-0000000000e2'
                AND total_amount = 5000
        ),
        3001,
        'inv-pay-over',
        'tester'
    ) $q$,
    'LD050'
);
DO $$
DECLARE r1 jsonb;
r2 jsonb;
BEGIN
SET LOCAL ROLE ledger_app;
r1 := ledger.record_invoice_payment(
    (
        SELECT id
        FROM ledger.invoices
        WHERE customer_account_id = '00000000-0000-0000-0000-0000000000e2'
            AND total_amount = 5000
    ),
    3000,
    'inv-pay-2',
    'tester'
);
-- Same key again, now that the invoice is PAID: must replay, not fail with LD053.
r2 := ledger.record_invoice_payment(
    (
        SELECT id
        FROM ledger.invoices
        WHERE customer_account_id = '00000000-0000-0000-0000-0000000000e2'
            AND total_amount = 5000
    ),
    3000,
    'inv-pay-2',
    'tester'
);
RESET ROLE;
IF r1->>'status' <> 'paid'
OR NOT (r2->>'replayed')::boolean
OR r2->>'transaction_id' <> r1->>'transaction_id' THEN RAISE EXCEPTION 'FAIL - final payment must mark paid and replay cleanly, got % / %',
r1,
r2;
END IF;
RAISE NOTICE 'ok - final payment marks the invoice paid and its replay is idempotent';
END $$;
SELECT pg_temp.assert_eq(
        'wallet = 5000 after full payment',
        (
            SELECT balance
            FROM ledger.account_balances
            WHERE account_id = '00000000-0000-0000-0000-0000000000e2'
        ),
        5000
    );
SELECT pg_temp.assert_eq(
        'receivable = 0 after full payment',
        (
            SELECT balance
            FROM ledger.account_balances
            WHERE account_id = '00000000-0000-0000-0000-0000000000e3'
        ),
        0
    );
SELECT pg_temp.assert_eq(
        'two payment rows recorded',
        (
            SELECT count(*)
            FROM ledger.invoice_payments p
                JOIN ledger.invoices i ON i.id = p.invoice_id
            WHERE i.customer_account_id = '00000000-0000-0000-0000-0000000000e2'
                AND i.total_amount = 5000
        ),
        2
    );
SELECT pg_temp.expect_fail(
        'paying a paid invoice is rejected',
        $q$
        SET LOCAL ROLE ledger_app;
SELECT ledger.record_invoice_payment(
        (
            SELECT id
            FROM ledger.invoices
            WHERE customer_account_id = '00000000-0000-0000-0000-0000000000e2'
                AND total_amount = 5000
        ),
        1,
        'inv-pay-3',
        'tester'
    ) $q$,
    'LD053'
);
SELECT pg_temp.expect_fail(
        'a paid invoice cannot be voided',
        $q$
        SET LOCAL ROLE ledger_app;
SELECT ledger.void_invoice(
        (
            SELECT id
            FROM ledger.invoices
            WHERE customer_account_id = '00000000-0000-0000-0000-0000000000e2'
                AND total_amount = 5000
        ),
        'inv-void-paid',
        'tester'
    ) $q$,
    'LD053'
);
SELECT pg_temp.expect_fail(
        'invoice ledger transactions cannot be reversed directly',
        $q$
        SET LOCAL ROLE ledger_app;
SELECT ledger.reverse_transaction(
        (
            SELECT issue_transaction_id
            FROM ledger.invoices
            WHERE customer_account_id = '00000000-0000-0000-0000-0000000000e2'
                AND total_amount = 5000
        ),
        'inv-rev-direct',
        'tester'
    ) $q$,
    'LD043'
);
-- ---- invoice 2 (20000): wallet cannot cover it, then void it --------------------------------
DO $$ BEGIN
SET LOCAL ROLE ledger_app;
PERFORM ledger.create_invoice(
    '00000000-0000-0000-0000-0000000000e2',
    '00000000-0000-0000-0000-0000000000e3',
    '00000000-0000-0000-0000-0000000000e4',
    'USD',
    '[{"description":"Big order","quantity":1,"unit_amount":20000}]'::jsonb,
    'inv-create-2',
    NULL,
    'tester'
);
RESET ROLE;
END $$;
SELECT pg_temp.expect_fail(
        'payment beyond the wallet balance is rejected (no overdraft)',
        $q$
        SET LOCAL ROLE ledger_app;
SELECT ledger.record_invoice_payment(
        (
            SELECT id
            FROM ledger.invoices
            WHERE customer_account_id = '00000000-0000-0000-0000-0000000000e2'
                AND total_amount = 20000
        ),
        15000,
        'inv-pay-od',
        'tester'
    ) $q$,
    'LD022'
);
DO $$
DECLARE r1 jsonb;
r2 jsonb;
BEGIN
SET LOCAL ROLE ledger_app;
r1 := ledger.void_invoice(
    (
        SELECT id
        FROM ledger.invoices
        WHERE customer_account_id = '00000000-0000-0000-0000-0000000000e2'
            AND total_amount = 20000
    ),
    'inv-void-1',
    'tester',
    'customer cancelled'
);
r2 := ledger.void_invoice(
    (
        SELECT id
        FROM ledger.invoices
        WHERE customer_account_id = '00000000-0000-0000-0000-0000000000e2'
            AND total_amount = 20000
    ),
    'inv-void-1',
    'tester',
    'customer cancelled'
);
RESET ROLE;
IF r1->>'status' <> 'void'
OR (r1->>'replayed')::boolean
OR NOT (r2->>'replayed')::boolean
OR r2->>'transaction_id' <> r1->>'transaction_id' THEN RAISE EXCEPTION 'FAIL - void must work once and replay cleanly, got % / %',
r1,
r2;
END IF;
RAISE NOTICE 'ok - void_invoice voids once and its replay is idempotent';
END $$;
SELECT pg_temp.assert_eq(
        'receivable back to 0 after void',
        (
            SELECT balance
            FROM ledger.account_balances
            WHERE account_id = '00000000-0000-0000-0000-0000000000e3'
        ),
        0
    );
SELECT pg_temp.assert_eq(
        'revenue back to 5000 after void (only invoice 1 remains)',
        (
            SELECT balance
            FROM ledger.account_balances
            WHERE account_id = '00000000-0000-0000-0000-0000000000e4'
        ),
        5000
    );
SELECT pg_temp.expect_fail(
        'a voided invoice cannot be voided again',
        $q$
        SET LOCAL ROLE ledger_app;
SELECT ledger.void_invoice(
        (
            SELECT id
            FROM ledger.invoices
            WHERE customer_account_id = '00000000-0000-0000-0000-0000000000e2'
                AND total_amount = 20000
        ),
        'inv-void-2',
        'tester'
    ) $q$,
    'LD053'
);
SELECT pg_temp.expect_fail(
        'a voided invoice cannot take payments',
        $q$
        SET LOCAL ROLE ledger_app;
SELECT ledger.record_invoice_payment(
        (
            SELECT id
            FROM ledger.invoices
            WHERE customer_account_id = '00000000-0000-0000-0000-0000000000e2'
                AND total_amount = 20000
        ),
        100,
        'inv-pay-void',
        'tester'
    ) $q$,
    'LD053'
);
-- ---- input validation ---------------------------------------------------------------------------
SELECT pg_temp.expect_fail(
        'wrong account roles are rejected',
        $q$
        SET LOCAL ROLE ledger_app;
SELECT ledger.create_invoice(
        '00000000-0000-0000-0000-0000000000e2',
        '00000000-0000-0000-0000-0000000000e2',
        '00000000-0000-0000-0000-0000000000e4',
        'USD',
        '[{"description":"x","quantity":1,"unit_amount":100}]'::jsonb,
        'inv-bad-roles'
    ) $q$,
    'LD051'
);
SELECT pg_temp.expect_fail(
        'currency not matching the accounts is rejected',
        $q$
        SET LOCAL ROLE ledger_app;
SELECT ledger.create_invoice(
        '00000000-0000-0000-0000-0000000000e2',
        '00000000-0000-0000-0000-0000000000e3',
        '00000000-0000-0000-0000-0000000000e4',
        'EUR',
        '[{"description":"x","quantity":1,"unit_amount":100}]'::jsonb,
        'inv-bad-cur'
    ) $q$,
    'LD031'
);
SELECT pg_temp.expect_fail(
        'zero quantity is rejected',
        $q$
        SET LOCAL ROLE ledger_app;
SELECT ledger.create_invoice(
        '00000000-0000-0000-0000-0000000000e2',
        '00000000-0000-0000-0000-0000000000e3',
        '00000000-0000-0000-0000-0000000000e4',
        'USD',
        '[{"description":"x","quantity":0,"unit_amount":100}]'::jsonb,
        'inv-bad-qty'
    ) $q$,
    'LD030'
);
SELECT pg_temp.expect_fail(
        'empty line list is rejected',
        $q$
        SET LOCAL ROLE ledger_app;
SELECT ledger.create_invoice(
        '00000000-0000-0000-0000-0000000000e2',
        '00000000-0000-0000-0000-0000000000e3',
        '00000000-0000-0000-0000-0000000000e4',
        'USD',
        '[]'::jsonb,
        'inv-no-lines'
    ) $q$,
    'LD030'
);
SELECT pg_temp.expect_fail(
        'unknown invoice is rejected',
        $q$
        SET LOCAL ROLE ledger_app;
SELECT ledger.record_invoice_payment(
        'ffffffff-ffff-ffff-ffff-ffffffffffff',
        100,
        'inv-404',
        'tester'
    ) $q$,
    'LD052'
);
-- ---- state machine, immutability, total check, privileges (run as superuser unless noted) ---------
SELECT pg_temp.expect_fail(
        'a void invoice cannot be reopened',
        $q$
        UPDATE ledger.invoices
        SET status = 'issued'
        WHERE customer_account_id = '00000000-0000-0000-0000-0000000000e2'
            AND total_amount = 20000 $q$,
            'LD054'
    );
SELECT pg_temp.expect_fail(
        'invoice totals are immutable',
        $q$
        UPDATE ledger.invoices
        SET total_amount = 1
        WHERE customer_account_id = '00000000-0000-0000-0000-0000000000e2'
            AND total_amount = 5000 $q$,
            'LD054'
    );
SELECT pg_temp.expect_fail(
        'invoice lines cannot be updated',
        $q$
        UPDATE ledger.invoice_lines
        SET quantity = 9 $q$,
            'LD003'
    );
SELECT pg_temp.expect_fail(
        'invoice payments cannot be deleted',
        $q$
        DELETE FROM ledger.invoice_payments $q$,
            'LD003'
    );
SELECT pg_temp.expect_fail(
        'invoices cannot be deleted',
        $q$
        DELETE FROM ledger.invoices $q$,
            'LD003'
    );
SELECT pg_temp.expect_fail(
        'invoice tables cannot be truncated',
        $q$ TRUNCATE ledger.invoices,
        ledger.invoice_lines,
        ledger.invoice_payments $q$,
        'LD003'
    );
SELECT pg_temp.expect_fail(
        'an invoice whose total differs from its lines is rejected at commit',
        $q$
        INSERT INTO ledger.invoices (
                customer_account_id,
                receivable_account_id,
                revenue_account_id,
                currency,
                total_amount,
                issue_transaction_id
            )
        VALUES (
                '00000000-0000-0000-0000-0000000000e2',
                '00000000-0000-0000-0000-0000000000e3',
                '00000000-0000-0000-0000-0000000000e4',
                'USD',
                100,
                (
                    SELECT id
                    FROM ledger.transactions
                    WHERE idempotency_key = 'inv-fund'
                )
            ) $q$,
            'LD056'
    );
SELECT pg_temp.expect_fail(
        'ledger_app cannot write invoices directly',
        $q$
        SET LOCAL ROLE ledger_app;
INSERT INTO ledger.invoices (
        customer_account_id,
        receivable_account_id,
        revenue_account_id,
        currency,
        total_amount,
        issue_transaction_id
    )
VALUES (
        '00000000-0000-0000-0000-0000000000e2',
        '00000000-0000-0000-0000-0000000000e3',
        '00000000-0000-0000-0000-0000000000e4',
        'USD',
        100,
        gen_random_uuid()
    ) $q$,
    '42501'
);
-- ---- global invariants still hold after all of the above ---------------------------------------------
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
DO $$ BEGIN RAISE NOTICE 'ALL PHASE 6 TESTS PASSED';
END $$;
ROLLBACK;