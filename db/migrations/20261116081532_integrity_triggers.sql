-- migrate:up
SET LOCAL ROLE ledger_owner;
-- ======================================================================
-- 1) BALANCED + MINIMUM-ENTRIES CHECK (invariants 1 and the 2-entry rule)
-- ======================================================================
-- Runs at COMMIT (deferred), once per inserted row, on both `entries` and
-- `transactions`. By then every line of the transaction exists, so we can check the
-- whole set. A normal trigger would fire after the FIRST line, when the books are
-- legitimately unbalanced.
-- Trigger on `transactions` too: a header with no entries never fires the `entries`
-- trigger, so it would otherwise slip through.
-- Cost (tradeoff): the check repeats once per row of the same transaction. Fine for
-- small journal entries; a statement-level design would be the optimisation.
-- search_path is pinned so no one can shadow objects this function touches.
CREATE FUNCTION ledger.assert_transaction_balanced() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog,
    ledger AS $$
DECLARE v_txn_id uuid;
v_count integer;
v_cur char(3);
v_diff numeric;
BEGIN -- Same function serves both triggers; find out which transaction we are checking.
IF TG_TABLE_NAME = 'transactions' THEN v_txn_id := NEW.id;
ELSE v_txn_id := NEW.transaction_id;
END IF;
SELECT count(*) INTO v_count
FROM ledger.entries
WHERE transaction_id = v_txn_id;
IF v_count < 2 THEN RAISE EXCEPTION 'transaction % has % entries; at least 2 are required',
v_txn_id,
v_count USING ERRCODE = 'LD002';
END IF;
-- Debits minus credits per currency; any currency with a non-zero difference is
-- unbalanced. Money in different currencies can never offset each other here.
SELECT currency,
    diff INTO v_cur,
    v_diff
FROM (
        SELECT currency,
            sum(
                CASE
                    direction
                    WHEN 'D' THEN amount::bigint
                    ELSE -(amount::bigint)
                END
            ) AS diff
        FROM ledger.entries
        WHERE transaction_id = v_txn_id
        GROUP BY currency
    ) per_currency
WHERE diff <> 0
LIMIT 1;
IF FOUND THEN RAISE EXCEPTION 'transaction % is unbalanced in %: debits minus credits = %',
v_txn_id,
v_cur,
v_diff USING ERRCODE = 'LD001';
END IF;
RETURN NULL;
-- return value is ignored for AFTER triggers
END $$;
CREATE CONSTRAINT TRIGGER entries_balanced_check
AFTER
INSERT ON ledger.entries DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ledger.assert_transaction_balanced();
CREATE CONSTRAINT TRIGGER transactions_balanced_check
AFTER
INSERT ON ledger.transactions DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ledger.assert_transaction_balanced();
-- ======================================================================
-- 2) BALANCE MAINTENANCE (invariant 7), trigger-based
-- ======================================================================
-- SECURITY DEFINER = runs with the OWNER's rights (ledger_owner), so the app role needs
-- no UPDATE privilege on account_balances. The app can never forge a balance; only
-- inserting an entry can move one. search_path is pinned: mandatory hygiene for
-- SECURITY DEFINER, which otherwise is a privilege-escalation hole.
CREATE FUNCTION ledger.apply_entry_to_balance() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog,
    ledger AS $$
DECLARE v_normal char(1);
v_delta bigint;
BEGIN
SELECT normal_side INTO v_normal
FROM ledger.accounts
WHERE id = NEW.account_id;
-- An entry on the account's normal side increases the balance, the other side
-- decreases it (credit to a wallet adds money; debit takes it out).
v_delta := CASE
    WHEN NEW.direction = v_normal THEN NEW.amount::bigint
    ELSE -(NEW.amount::bigint)
END;
-- Atomic read-modify-write. UPDATE takes a row lock, so two concurrent postings to
-- one account queue up; the second re-evaluates the no-overdraft CHECK against the
-- first one's result. That is how overdrafts are impossible even under concurrency.
UPDATE ledger.account_balances
SET balance = balance + v_delta,
    version = version + 1,
    updated_at = now()
WHERE account_id = NEW.account_id;
IF NOT FOUND THEN RAISE EXCEPTION 'no balance row for account %',
NEW.account_id USING ERRCODE = 'LD004';
END IF;
RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ledger.apply_entry_to_balance()
FROM PUBLIC;
-- AFTER INSERT, immediate (not deferred): the overdraft CHECK fails right at the
-- offending line. Edge case for the README: an overdraft check cannot see a later line
-- of the same transaction that would repay it, so post_transaction (Phase 4) orders lines.
CREATE TRIGGER entries_apply_balance
AFTER
INSERT ON ledger.entries FOR EACH ROW EXECUTE FUNCTION ledger.apply_entry_to_balance();
-- Every new account automatically gets its balance row (starting at 0).
CREATE FUNCTION ledger.create_balance_row() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog,
    ledger AS $$ BEGIN
INSERT INTO ledger.account_balances (account_id, allow_negative)
VALUES (NEW.id, NEW.allow_negative);
RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION ledger.create_balance_row()
FROM PUBLIC;
CREATE TRIGGER accounts_create_balance
AFTER
INSERT ON ledger.accounts FOR EACH ROW EXECUTE FUNCTION ledger.create_balance_row();
COMMENT ON FUNCTION ledger.assert_transaction_balanced() IS 'Deferred check: >= 2 entries and debits = credits per currency (SQLSTATE LD002 / LD001).';
COMMENT ON FUNCTION ledger.apply_entry_to_balance() IS 'Moves account_balances for each entry. SECURITY DEFINER so the app cannot write balances.';
RESET ROLE;
-- migrate:down
SET LOCAL ROLE ledger_owner;
DROP TRIGGER accounts_create_balance ON ledger.accounts;
DROP FUNCTION ledger.create_balance_row();
DROP TRIGGER entries_apply_balance ON ledger.entries;
DROP FUNCTION ledger.apply_entry_to_balance();
DROP TRIGGER transactions_balanced_check ON ledger.transactions;
DROP TRIGGER entries_balanced_check ON ledger.entries;
DROP FUNCTION ledger.assert_transaction_balanced();
RESET ROLE;