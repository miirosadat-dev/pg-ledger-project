-- migrate:up
SET LOCAL ROLE ledger_owner;
-- All four public functions are thin: validate the obvious, build the lines, delegate to
-- post_transaction. SECURITY DEFINER + pinned search_path, as explained there.
-- Convention: wallets are LIABILITY accounts, platform cash is an ASSET.
--   transfer : debit sender wallet,  credit receiver wallet
--   deposit  : debit platform cash,  credit user wallet   (platform now owes the user more)
--   withdraw : debit user wallet,    credit platform cash
-- ---------------------------------------------------------------- transfer
CREATE FUNCTION ledger.transfer(
    p_from uuid,
    p_to uuid,
    p_amount bigint,
    p_currency text,
    p_idempotency_key text,
    p_created_by text DEFAULT NULL,
    p_description text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog,
    ledger AS $$ BEGIN IF p_from IS NULL
    OR p_to IS NULL
    OR p_from = p_to THEN RAISE EXCEPTION 'a transfer needs two different accounts' USING ERRCODE = 'LD030';
END IF;
IF p_amount IS NULL
OR p_amount <= 0 THEN RAISE EXCEPTION 'amount must be greater than zero' USING ERRCODE = 'LD030';
END IF;
RETURN ledger.post_transaction(
    p_idempotency_key,
    jsonb_build_object(
        'op',
        'transfer',
        'from',
        p_from,
        'to',
        p_to,
        'amount',
        p_amount,
        'currency',
        p_currency,
        'description',
        p_description
    ),
    'transfer',
    jsonb_build_array(
        jsonb_build_object(
            'account_id',
            p_from,
            'direction',
            'D',
            'amount',
            p_amount,
            'currency',
            p_currency
        ),
        jsonb_build_object(
            'account_id',
            p_to,
            'direction',
            'C',
            'amount',
            p_amount,
            'currency',
            p_currency
        )
    ),
    p_description => p_description,
    p_created_by => p_created_by
);
END $$;
-- ---------------------------------------------------------------- deposit
CREATE FUNCTION ledger.deposit(
    p_wallet uuid,
    p_cash uuid,
    p_amount bigint,
    p_currency text,
    p_idempotency_key text,
    p_created_by text DEFAULT NULL,
    p_description text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog,
    ledger AS $$ BEGIN IF p_wallet IS NULL
    OR p_cash IS NULL
    OR p_wallet = p_cash THEN RAISE EXCEPTION 'a deposit needs a wallet and a different cash account' USING ERRCODE = 'LD030';
END IF;
IF p_amount IS NULL
OR p_amount <= 0 THEN RAISE EXCEPTION 'amount must be greater than zero' USING ERRCODE = 'LD030';
END IF;
RETURN ledger.post_transaction(
    p_idempotency_key,
    jsonb_build_object(
        'op',
        'deposit',
        'wallet',
        p_wallet,
        'cash',
        p_cash,
        'amount',
        p_amount,
        'currency',
        p_currency,
        'description',
        p_description
    ),
    'deposit',
    jsonb_build_array(
        jsonb_build_object(
            'account_id',
            p_cash,
            'direction',
            'D',
            'amount',
            p_amount,
            'currency',
            p_currency
        ),
        jsonb_build_object(
            'account_id',
            p_wallet,
            'direction',
            'C',
            'amount',
            p_amount,
            'currency',
            p_currency
        )
    ),
    p_description => p_description,
    p_created_by => p_created_by
);
END $$;
-- ---------------------------------------------------------------- withdraw
CREATE FUNCTION ledger.withdraw(
    p_wallet uuid,
    p_cash uuid,
    p_amount bigint,
    p_currency text,
    p_idempotency_key text,
    p_created_by text DEFAULT NULL,
    p_description text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog,
    ledger AS $$ BEGIN IF p_wallet IS NULL
    OR p_cash IS NULL
    OR p_wallet = p_cash THEN RAISE EXCEPTION 'a withdrawal needs a wallet and a different cash account' USING ERRCODE = 'LD030';
END IF;
IF p_amount IS NULL
OR p_amount <= 0 THEN RAISE EXCEPTION 'amount must be greater than zero' USING ERRCODE = 'LD030';
END IF;
RETURN ledger.post_transaction(
    p_idempotency_key,
    jsonb_build_object(
        'op',
        'withdraw',
        'wallet',
        p_wallet,
        'cash',
        p_cash,
        'amount',
        p_amount,
        'currency',
        p_currency,
        'description',
        p_description
    ),
    'withdrawal',
    jsonb_build_array(
        jsonb_build_object(
            'account_id',
            p_wallet,
            'direction',
            'D',
            'amount',
            p_amount,
            'currency',
            p_currency
        ),
        jsonb_build_object(
            'account_id',
            p_cash,
            'direction',
            'C',
            'amount',
            p_amount,
            'currency',
            p_currency
        )
    ),
    p_description => p_description,
    p_created_by => p_created_by
);
END $$;
-- ------------------------------------------------------ reverse_transaction
-- Posts the exact opposite of an existing transaction, linked through reversal_of.
-- History is never edited: the original stays, and the reversal cancels its effect.
CREATE FUNCTION ledger.reverse_transaction(
    p_transaction_id uuid,
    p_idempotency_key text,
    p_created_by text DEFAULT NULL,
    p_reason text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog,
    ledger AS $$
DECLARE v_orig ledger.transactions %ROWTYPE;
v_entries jsonb;
BEGIN
SELECT * INTO v_orig
FROM ledger.transactions
WHERE id = p_transaction_id;
IF NOT FOUND THEN RAISE EXCEPTION 'transaction % not found',
p_transaction_id USING ERRCODE = 'LD040';
END IF;
IF v_orig.type = 'reversal' THEN RAISE EXCEPTION 'a reversal cannot itself be reversed; post a new transaction instead' USING ERRCODE = 'LD042';
END IF;
-- Flip every line: D becomes C and C becomes D, same amounts and currencies.
SELECT jsonb_agg(
        jsonb_build_object(
            'account_id',
            e.account_id,
            'direction',
            CASE
                e.direction
                WHEN 'D' THEN 'C'
                ELSE 'D'
            END,
            'amount',
            e.amount,
            'currency',
            e.currency
        )
        ORDER BY e.id
    ) INTO v_entries
FROM ledger.entries e
WHERE e.transaction_id = p_transaction_id;
-- The "already reversed" check happens inside post_transaction, after the account
-- locks are held (race-free). Reversing can still fail with LD022 if the money has
-- since been spent: reversal does not override the no-overdraft rule.
RETURN ledger.post_transaction(
    p_idempotency_key,
    jsonb_build_object(
        'op',
        'reverse',
        'transaction_id',
        p_transaction_id,
        'reason',
        p_reason
    ),
    'reversal',
    v_entries,
    p_description => COALESCE(
        p_reason,
        'Reversal of ' || p_transaction_id::text
    ),
    p_created_by => p_created_by,
    p_reversal_of => p_transaction_id
);
END $$;
COMMENT ON FUNCTION ledger.transfer(uuid, uuid, bigint, text, text, text, text) IS 'Wallet-to-wallet transfer. Atomic and idempotent.';
COMMENT ON FUNCTION ledger.deposit(uuid, uuid, bigint, text, text, text, text) IS 'Cash in: debit platform cash, credit user wallet. Atomic and idempotent.';
COMMENT ON FUNCTION ledger.withdraw(uuid, uuid, bigint, text, text, text, text) IS 'Cash out: debit user wallet, credit platform cash. Atomic and idempotent.';
COMMENT ON FUNCTION ledger.reverse_transaction(uuid, text, text, text) IS 'Posts the opposite of a transaction, linked by reversal_of. At most once per transaction.';
-- THE API BOUNDARY: functions only
-- New functions are executable by PUBLIC by default; remove that, then grant exactly the
-- four public entry points to the app role.
REVOKE ALL ON FUNCTION ledger.transfer(uuid, uuid, bigint, text, text, text, text)
FROM PUBLIC;
REVOKE ALL ON FUNCTION ledger.deposit(uuid, uuid, bigint, text, text, text, text)
FROM PUBLIC;
REVOKE ALL ON FUNCTION ledger.withdraw(uuid, uuid, bigint, text, text, text, text)
FROM PUBLIC;
REVOKE ALL ON FUNCTION ledger.reverse_transaction(uuid, text, text, text)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ledger.transfer(uuid, uuid, bigint, text, text, text, text) TO ledger_app;
GRANT EXECUTE ON FUNCTION ledger.deposit(uuid, uuid, bigint, text, text, text, text) TO ledger_app;
GRANT EXECUTE ON FUNCTION ledger.withdraw(uuid, uuid, bigint, text, text, text, text) TO ledger_app;
GRANT EXECUTE ON FUNCTION ledger.reverse_transaction(uuid, text, text, text) TO ledger_app;
-- Now that posting goes through the functions, the app no longer needs (or gets) direct
-- write access to the ledger tables. It keeps SELECT for statements and reports, and
-- DELETE on idempotency_keys so a cleanup job can purge expired keys.
REVOKE
INSERT ON ledger.transactions,
    ledger.entries,
    ledger.idempotency_keys
FROM ledger_app;
REVOKE
UPDATE (status, response) ON ledger.idempotency_keys
FROM ledger_app;
RESET ROLE;
-- migrate:down
SET LOCAL ROLE ledger_owner;
GRANT INSERT ON ledger.transactions,
    ledger.entries,
    ledger.idempotency_keys TO ledger_app;
GRANT UPDATE (status, response) ON ledger.idempotency_keys TO ledger_app;
DROP FUNCTION ledger.reverse_transaction(uuid, text, text, text);
DROP FUNCTION ledger.withdraw(uuid, uuid, bigint, text, text, text, text);
DROP FUNCTION ledger.deposit(uuid, uuid, bigint, text, text, text, text);
DROP FUNCTION ledger.transfer(uuid, uuid, bigint, text, text, text, text);
RESET ROLE;