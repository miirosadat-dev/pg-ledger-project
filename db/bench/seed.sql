-- Bulk-loads synthetic data into the throwaway ledger_bench database.
-- Run by scripts/bench.mjs with:  -v n_accounts=1000 -v n_txns=500000
\ timing on -- Bulk-load mode: skips ALL ordinary triggers and FK checks (superuser only). We use it
-- because firing the balance trigger and deferred balance check per row would take
-- minutes. Safe here because every transaction below is balanced by construction, and
-- balances are recomputed afterwards.
SET session_replication_role = replica;
-- 1. Accounts. allow_negative = true so random transfers can never trip the overdraft rule.
INSERT INTO ledger.accounts (owner_ref, name, type, currency, allow_negative)
SELECT 'bench',
    'bench-wallet-' || lpad(g::text, 5, '0'),
    'liability',
    'USD',
    true
FROM generate_series(1, :n_accounts) g;
-- Triggers are off, so create the balance rows by hand.
INSERT INTO ledger.account_balances (account_id, allow_negative)
SELECT id,
    true
FROM ledger.accounts
WHERE owner_ref = 'bench';
-- Number accounts 1..n; the pgbench scripts pick accounts by this number.
CREATE TABLE public.bench_accounts AS
SELECT row_number() OVER (
        ORDER BY name
    )::int AS n,
    id
FROM ledger.accounts
WHERE owner_ref = 'bench';
ALTER TABLE public.bench_accounts
ADD PRIMARY KEY (n);
-- 2. Partitions for the last 13 months (the migration only created the current month
--    and the next three). Guards are attached but dormant while replica mode is on.
SELECT ledger.create_entries_partition(
        (
            date_trunc('month', timezone('UTC', now())) - make_interval(months => i)
        )::date
    )
FROM generate_series(0, 12) AS i;
-- 3. The transfers: random pair of DIFFERENT accounts, amount 100..9999, a random
--    timestamp within the last 360 days. The inner SELECT is not flattened because it
--    contains volatile functions, so each value is generated once per row.
CREATE TEMP TABLE seed_txn AS
SELECT s.id,
    s.ts,
    s.amt,
    s.a_idx,
    ((s.a_idx - 1 + s.off) % :n_accounts) + 1 AS b_idx
FROM (
        SELECT uuidv7() AS id,
            now() - (random() * interval '360 days') AS ts,
            (100 + floor(random() * 9900))::bigint AS amt,
            (1 + floor(random() * :n_accounts))::int AS a_idx,
            (1 + floor(random() * (:n_accounts - 1)))::int AS off
        FROM generate_series(1, :n_txns)
    ) s;
CREATE TEMP TABLE seed_acct AS
SELECT n,
    id
FROM public.bench_accounts;
ALTER TABLE seed_acct
ADD PRIMARY KEY (n);
INSERT INTO ledger.transactions (
        id,
        type,
        description,
        effective_at,
        created_at,
        created_by
    )
SELECT id,
    'transfer',
    'bench transfer',
    ts,
    ts,
    'bench'
FROM seed_txn;
-- Debit the sender, credit the receiver, same amount: every transaction balances.
INSERT INTO ledger.entries (
        transaction_id,
        account_id,
        currency,
        direction,
        amount,
        created_at
    )
SELECT t.id,
    a.id,
    'USD',
    'D',
    t.amt,
    t.ts
FROM seed_txn t
    JOIN seed_acct a ON a.n = t.a_idx
UNION ALL
SELECT t.id,
    b.id,
    'USD',
    'C',
    t.amt,
    t.ts
FROM seed_txn t
    JOIN seed_acct b ON b.n = t.b_idx;
-- 4. Recompute cached balances from the entries (liability = credits - debits).
UPDATE ledger.account_balances b
SET balance = s.bal,
    version = 1
FROM (
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
    ) s
WHERE b.account_id = s.account_id;
RESET session_replication_role;
-- 5. Fresh statistics so the planner makes honest choices.
ANALYZE ledger.entries;
ANALYZE ledger.transactions;
ANALYZE ledger.account_balances;