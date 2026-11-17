-- migrate:up
SET LOCAL ROLE ledger_owner;
-- Index for statements: "one account, in time order"
-- Defined on the partitioned parent, so every partition gets one. Equality on
-- account_id, then the time range, then id as the tie-breaker (all entries of one
-- transaction share created_at). Phase 7B proves its value with EXPLAIN.
CREATE INDEX entries_account_created_idx ON ledger.entries (account_id, created_at, id);
-- account_statement: entries with a running balance
-- Balance sign follows the account's normal side (same convention as account_balances).
-- Rows are ordered by posting time (created_at) then id, which is deterministic.
-- The running balance starts from an OPENING balance (everything before p_from), so a
-- date-filtered statement still carries correct totals. LIMIT is applied AFTER the
-- window function, so truncating the list never distorts the running balance.
-- SECURITY INVOKER (the default): the caller needs SELECT on the tables, which both
-- ledger_app and ledger_readonly have.
CREATE FUNCTION ledger.account_statement(
    p_account uuid,
    p_from timestamptz DEFAULT NULL,
    p_to timestamptz DEFAULT NULL,
    p_limit integer DEFAULT 1000
) RETURNS TABLE (
    entry_id bigint,
    transaction_id uuid,
    posted_at timestamptz,
    effective_at timestamptz,
    txn_type text,
    description text,
    direction char(1),
    debit bigint,
    credit bigint,
    running_balance bigint
) LANGUAGE sql STABLE
SET search_path = pg_catalog,
    ledger AS $$ WITH acct AS (
        SELECT a.normal_side
        FROM ledger.accounts a
        WHERE a.id = p_account
    ),
    opening AS (
        SELECT COALESCE(
                sum(
                    CASE
                        WHEN e.direction = acct.normal_side THEN e.amount::bigint
                        ELSE -(e.amount::bigint)
                    END
                ),
                0
            ) AS bal
        FROM ledger.entries e
            CROSS JOIN acct
        WHERE p_from IS NOT NULL
            AND e.account_id = p_account
            AND e.created_at < p_from
    ),
    in_range AS (
        SELECT e.id,
            e.transaction_id,
            e.created_at,
            e.direction,
            e.amount::bigint AS amount,
            CASE
                WHEN e.direction = acct.normal_side THEN e.amount::bigint
                ELSE -(e.amount::bigint)
            END AS signed
        FROM ledger.entries e
            CROSS JOIN acct
        WHERE e.account_id = p_account
            AND (
                p_from IS NULL
                OR e.created_at >= p_from
            )
            AND (
                p_to IS NULL
                OR e.created_at < p_to
            )
    )
SELECT r.id,
    r.transaction_id,
    r.created_at,
    t.effective_at,
    t.type,
    t.description,
    r.direction,
    CASE
        WHEN r.direction = 'D' THEN r.amount
    END,
    CASE
        WHEN r.direction = 'C' THEN r.amount
    END,
    (
        o.bal + sum(r.signed) OVER (
            ORDER BY r.created_at,
                r.id
        )
    )::bigint
FROM in_range r
    JOIN ledger.transactions t ON t.id = r.transaction_id
    CROSS JOIN opening o
ORDER BY r.created_at,
    r.id
LIMIT p_limit $$;
-- reconcile: proves invariants 1 and 7. Returns ONLY discrepancies (no rows = healthy).
-- For one consistent view of a moving ledger, call it inside
-- BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY; ... COMMIT;
CREATE FUNCTION ledger.reconcile() RETURNS TABLE (
    check_name text,
    subject text,
    expected numeric,
    actual numeric
) LANGUAGE sql STABLE
SET search_path = pg_catalog,
    ledger AS $$ -- 1. Per currency, total debits equal total credits across the whole ledger.
SELECT 'currency_balanced'::text,
    e.currency::text,
    0::numeric,
    sum(
        CASE
            e.direction
            WHEN 'D' THEN e.amount::bigint
            ELSE -(e.amount::bigint)
        END
    )::numeric
FROM ledger.entries e
GROUP BY e.currency
HAVING sum(
        CASE
            e.direction
            WHEN 'D' THEN e.amount::bigint
            ELSE -(e.amount::bigint)
        END
    ) <> 0
UNION ALL
-- 2. Every transaction balances per currency.
SELECT 'transaction_balanced',
    x.transaction_id::text || '/' || x.currency::text,
    0,
    x.diff
FROM (
        SELECT e.transaction_id,
            e.currency,
            sum(
                CASE
                    e.direction
                    WHEN 'D' THEN e.amount::bigint
                    ELSE -(e.amount::bigint)
                END
            )::numeric AS diff
        FROM ledger.entries e
        GROUP BY e.transaction_id,
            e.currency
    ) x
WHERE x.diff <> 0
UNION ALL
-- 3. Every cached balance equals the sum of that account's entries.
SELECT 'balance_matches_entries',
    b.account_id::text,
    COALESCE(s.bal, 0)::numeric,
    b.balance::numeric
FROM ledger.account_balances b
    LEFT JOIN (
        SELECT e.account_id,
            sum(
                CASE
                    WHEN e.direction = a.normal_side THEN e.amount::bigint
                    ELSE -(e.amount::bigint)
                END
            ) AS bal
        FROM ledger.entries e
            JOIN ledger.accounts a ON a.id = e.account_id
        GROUP BY e.account_id
    ) s ON s.account_id = b.account_id
WHERE b.balance <> COALESCE(s.bal, 0) $$;
-- trial_balance: materialized, refreshed CONCURRENTLY
-- A trial balance lists every account's debit or credit balance; the two columns must
-- total the same. Computing it scans all entries, so it is materialized. Strategy:
-- reports tolerate staleness (refresh on a schedule or after batches); anything that
-- needs live numbers reads account_balances. REFRESH ... CONCURRENTLY swaps in the new
-- data without blocking readers (a plain REFRESH locks the view exclusively); it needs
-- the unique index below, and costs more than a plain refresh.
CREATE MATERIALIZED VIEW ledger.trial_balance AS
SELECT s.account_id,
    s.name,
    s.type,
    s.currency,
    s.total_debits,
    s.total_credits,
    GREATEST(s.total_debits - s.total_credits, 0)::bigint AS debit_balance,
    GREATEST(s.total_credits - s.total_debits, 0)::bigint AS credit_balance
FROM (
        SELECT a.id AS account_id,
            a.name,
            a.type,
            a.currency,
            COALESCE(
                sum(e.amount) FILTER (
                    WHERE e.direction = 'D'
                ),
                0
            )::bigint AS total_debits,
            COALESCE(
                sum(e.amount) FILTER (
                    WHERE e.direction = 'C'
                ),
                0
            )::bigint AS total_credits
        FROM ledger.accounts a
            LEFT JOIN ledger.entries e ON e.account_id = a.id
        GROUP BY a.id,
            a.name,
            a.type,
            a.currency
    ) s WITH DATA;
CREATE UNIQUE INDEX trial_balance_account_id_uidx ON ledger.trial_balance (account_id);
COMMENT ON MATERIALIZED VIEW ledger.trial_balance IS 'Per-account debit/credit balances. Stale between refreshes; refresh via refresh_trial_balance().';
-- SECURITY DEFINER: the app triggers a refresh without owning the view.
CREATE FUNCTION ledger.refresh_trial_balance() RETURNS void LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog,
    ledger AS $$ BEGIN REFRESH MATERIALIZED VIEW CONCURRENTLY ledger.trial_balance;
END $$;
COMMENT ON FUNCTION ledger.account_statement(uuid, timestamptz, timestamptz, integer) IS 'Entries of one account in time order with a running balance (normal-side convention).';
COMMENT ON FUNCTION ledger.reconcile() IS 'Returns discrepancies only: currency balance, per-transaction balance, cached balance vs entries.';
-- Access: reports for both roles; refreshing only for the app. Nobody writes the view.
REVOKE ALL ON FUNCTION ledger.account_statement(uuid, timestamptz, timestamptz, integer)
FROM PUBLIC;
REVOKE ALL ON FUNCTION ledger.reconcile()
FROM PUBLIC;
REVOKE ALL ON FUNCTION ledger.refresh_trial_balance()
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ledger.account_statement(uuid, timestamptz, timestamptz, integer) TO ledger_app,
    ledger_readonly;
GRANT EXECUTE ON FUNCTION ledger.reconcile() TO ledger_app,
    ledger_readonly;
GRANT EXECUTE ON FUNCTION ledger.refresh_trial_balance() TO ledger_app;
GRANT SELECT ON ledger.trial_balance TO ledger_app,
    ledger_readonly;
RESET ROLE;
-- migrate:down
SET LOCAL ROLE ledger_owner;
DROP FUNCTION ledger.refresh_trial_balance();
DROP MATERIALIZED VIEW ledger.trial_balance;
DROP FUNCTION ledger.reconcile();
DROP FUNCTION ledger.account_statement(uuid, timestamptz, timestamptz, integer);
DROP INDEX ledger.entries_account_created_idx;
RESET ROLE;