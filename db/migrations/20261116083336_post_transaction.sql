-- migrate:up
SET LOCAL ROLE ledger_owner;
-- ======================================================================
-- ledger.post_transaction: the single internal entry point for posting.
-- ======================================================================
-- SECURITY DEFINER: runs with ledger_owner's rights, so the app role needs no direct
-- INSERT on ledger tables and no UPDATE on account_balances (needed for FOR UPDATE).
-- search_path is pinned: mandatory hygiene for any SECURITY DEFINER function.
--
-- p_request   : the logical request (op, accounts, amount...). Hashed for idempotency.
-- p_entries   : jsonb array of {account_id, direction D|C, amount > 0, currency}.
-- Returns     : jsonb {transaction_id, type, reversal_of, replayed}.
--
-- ERROR CODES raised here (see docs/ERROR_CODES.md):
--   LD002 < 2 entries   LD010 key reused with different payload   LD011 key in progress
--   LD020 account missing   LD021 account not active   LD022 insufficient funds
--   LD030 malformed request   LD031 currency mismatch   LD041 already reversed
CREATE FUNCTION ledger.post_transaction(
    p_idempotency_key text,
    p_request jsonb,
    p_type text,
    p_entries jsonb,
    p_description text DEFAULT NULL,
    p_created_by text DEFAULT NULL,
    p_effective_at timestamptz DEFAULT now(),
    p_metadata jsonb DEFAULT '{}'::jsonb,
    p_reversal_of uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog,
    ledger AS $$
DECLARE v_hash char(64);
v_existing ledger.idempotency_keys %ROWTYPE;
v_ids uuid [];
v_n integer;
v_txn_id uuid;
v_response jsonb;
v_constraint text;
BEGIN -- ---- 1. Cheap validation first (no locks taken yet) ----------------------
IF p_idempotency_key IS NULL
OR length(p_idempotency_key) NOT BETWEEN 1 AND 255 THEN RAISE EXCEPTION 'an idempotency key of 1-255 characters is required' USING ERRCODE = 'LD030';
END IF;
IF p_request IS NULL
OR jsonb_typeof(p_request) <> 'object' THEN RAISE EXCEPTION 'request must be a JSON object' USING ERRCODE = 'LD030';
END IF;
IF p_entries IS NULL
OR jsonb_typeof(p_entries) <> 'array' THEN RAISE EXCEPTION 'entries must be a JSON array' USING ERRCODE = 'LD030';
END IF;
IF jsonb_array_length(p_entries) < 2 THEN RAISE EXCEPTION 'a transaction needs at least 2 entries' USING ERRCODE = 'LD002';
END IF;
-- Hash of the canonical text form of the request. jsonb normalises key order and
-- whitespace, so equal requests always hash equally, and the client cannot lie.
v_hash := encode(
    sha256(convert_to(p_request::text, 'UTF8')),
    'hex'
);
-- ---- 2. Serialise requests that share an idempotency key ------------------
-- No row exists yet to lock, so we lock a 64-bit number derived from the key.
-- Hash collisions between different keys only cause harmless extra waiting.
-- Lock order is always: advisory lock first, then account rows. A fixed order
-- across all callers is what makes deadlock impossible.
PERFORM pg_advisory_xact_lock(hashtextextended(p_idempotency_key, 0));
-- ---- 3. Idempotency check ---------------------------------------------------
SELECT * INTO v_existing
FROM ledger.idempotency_keys
WHERE key = p_idempotency_key;
IF FOUND THEN IF v_existing.request_hash <> v_hash THEN RAISE EXCEPTION 'idempotency key % was already used with a different request',
p_idempotency_key USING ERRCODE = 'LD010';
ELSIF v_existing.status = 'completed' THEN -- Replay: post nothing, hand back what the first call returned.
RETURN v_existing.response || jsonb_build_object('replayed', true);
ELSE RAISE EXCEPTION 'a request with idempotency key % is still in progress',
p_idempotency_key USING ERRCODE = 'LD011';
END IF;
END IF;
-- Register the key. If anything below fails, the whole transaction rolls back and
-- takes this row with it, so failed requests never consume a key.
INSERT INTO ledger.idempotency_keys (key, request_hash, request_payload)
VALUES (p_idempotency_key, v_hash, p_request);
-- ---- 4. Validate the entry lines (typed extraction of the JSON) ----------------
BEGIN
SELECT count(*) INTO v_n
FROM jsonb_to_recordset(p_entries) AS x(
        account_id uuid,
        direction text,
        amount bigint,
        currency text
    )
WHERE x.account_id IS NULL
    OR x.direction IS NULL
    OR x.direction NOT IN ('D', 'C')
    OR x.amount IS NULL
    OR x.amount <= 0
    OR x.currency IS NULL;
SELECT array_agg(
        DISTINCT x.account_id
        ORDER BY x.account_id
    ) INTO v_ids
FROM jsonb_to_recordset(p_entries) AS x(
        account_id uuid,
        direction text,
        amount bigint,
        currency text
    );
EXCEPTION
WHEN invalid_text_representation
OR numeric_value_out_of_range
OR invalid_parameter_value THEN -- A bad uuid, a non-integer amount, or an element that is not an object.
RAISE EXCEPTION 'malformed entries array' USING ERRCODE = 'LD030';
END;
IF v_n > 0 THEN RAISE EXCEPTION 'every entry needs account_id, direction (D or C), amount > 0 and currency' USING ERRCODE = 'LD030';
END IF;
-- ---- 5. Lock every involved balance row, in SORTED account-id order -------------
-- Two concurrent transfers A->B and B->A would otherwise lock A then B, and B then
-- A, a classic deadlock. With one global order, the second simply waits.
-- (FOR UPDATE with ORDER BY locks rows in sorted order: LockRows sits above Sort.)
PERFORM 1
FROM ledger.account_balances b
WHERE b.account_id = ANY (v_ids)
ORDER BY b.account_id FOR
UPDATE;
-- ---- 6. Business validation, now race-free because we hold the locks -------------
SELECT count(*) INTO v_n
FROM ledger.accounts a
WHERE a.id = ANY (v_ids);
IF v_n <> cardinality(v_ids) THEN RAISE EXCEPTION 'one or more accounts do not exist' USING ERRCODE = 'LD020';
END IF;
SELECT count(*) INTO v_n
FROM ledger.accounts a
WHERE a.id = ANY (v_ids)
    AND a.status <> 'active';
IF v_n > 0 THEN RAISE EXCEPTION 'one or more accounts are not active (frozen or closed)' USING ERRCODE = 'LD021';
END IF;
SELECT count(*) INTO v_n
FROM jsonb_to_recordset(p_entries) AS x(
        account_id uuid,
        direction text,
        amount bigint,
        currency text
    )
    JOIN ledger.accounts a ON a.id = x.account_id
WHERE a.currency::text <> x.currency;
IF v_n > 0 THEN RAISE EXCEPTION 'an entry currency does not match its account currency' USING ERRCODE = 'LD031';
END IF;
-- A transaction can be reversed once. Checked AFTER the account locks: any competing
-- reversal of the same transaction touches the same accounts, so it is serialised
-- behind us. UNIQUE (reversal_of) is the backstop if this check were ever bypassed.
IF p_reversal_of IS NOT NULL
AND EXISTS (
    SELECT 1
    FROM ledger.transactions t
    WHERE t.reversal_of = p_reversal_of
) THEN RAISE EXCEPTION 'transaction % has already been reversed',
p_reversal_of USING ERRCODE = 'LD041';
END IF;
-- ---- 7. Write the header, then the lines ---------------------------------------------
INSERT INTO ledger.transactions (
        type,
        description,
        effective_at,
        created_by,
        reversal_of,
        metadata,
        idempotency_key
    )
VALUES (
        p_type,
        p_description,
        COALESCE(p_effective_at, now()),
        p_created_by,
        p_reversal_of,
        COALESCE(p_metadata, '{}'::jsonb),
        p_idempotency_key
    )
RETURNING id INTO v_txn_id;
-- Insert order: lines that INCREASE an account come first, then lines that decrease
-- it, so a transaction that credits and debits the same wallet is never falsely
-- rejected by the per-line overdraft check. Each line fires the balance trigger.
BEGIN
INSERT INTO ledger.entries (
        transaction_id,
        account_id,
        currency,
        direction,
        amount
    )
SELECT v_txn_id,
    x.account_id,
    x.currency,
    x.direction,
    x.amount
FROM jsonb_to_recordset(p_entries) AS x(
        account_id uuid,
        direction text,
        amount bigint,
        currency text
    )
    JOIN ledger.accounts a ON a.id = x.account_id
ORDER BY (x.direction = a.normal_side) DESC,
    x.account_id,
    x.direction;
EXCEPTION
WHEN check_violation THEN -- Translate the no-overdraft CHECK into a friendly, API-mappable error.
-- (Cost: this BEGIN/EXCEPTION block opens a subtransaction on every call.)
GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
IF v_constraint = 'account_balances_no_overdraft' THEN RAISE EXCEPTION 'insufficient funds: the transaction would overdraw an account' USING ERRCODE = 'LD022';
END IF;
RAISE;
-- any other check violation: re-raise untouched
END;
-- Fire the DEFERRED balance trigger now, so LD001/LD002 surface from this call and
-- not later at COMMIT. The trigger still runs at commit as the final safety net.
SET CONSTRAINTS ALL IMMEDIATE;
SET CONSTRAINTS ALL DEFERRED;
-- ---- 8. Store the response so replays can return it ----------------------------------
v_response := jsonb_build_object(
    'transaction_id',
    v_txn_id,
    'type',
    p_type,
    'reversal_of',
    p_reversal_of
);
UPDATE ledger.idempotency_keys
SET status = 'completed',
    response = v_response
WHERE key = p_idempotency_key;
RETURN v_response || jsonb_build_object('replayed', false);
END $$;
COMMENT ON FUNCTION ledger.post_transaction(
    text,
    jsonb,
    text,
    jsonb,
    text,
    text,
    timestamptz,
    jsonb,
    uuid
) IS 'Internal posting engine: idempotent, deadlock-safe (sorted locks), atomic. Not granted to the app role.';
-- Not callable by anyone but the owner (and functions the owner defines).
REVOKE ALL ON FUNCTION ledger.post_transaction(
    text,
    jsonb,
    text,
    jsonb,
    text,
    text,
    timestamptz,
    jsonb,
    uuid
)
FROM PUBLIC;
RESET ROLE;
-- migrate:down
SET LOCAL ROLE ledger_owner;
DROP FUNCTION ledger.post_transaction(
    text,
    jsonb,
    text,
    jsonb,
    text,
    text,
    timestamptz,
    jsonb,
    uuid
);
RESET ROLE;