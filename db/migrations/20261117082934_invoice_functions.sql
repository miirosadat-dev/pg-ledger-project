-- migrate:up
SET LOCAL ROLE ledger_owner;
-- All three functions follow one pattern: (1) cheap validation, (2) an UNLOCKED probe of
-- the invoice that is skipped when the idempotency key already exists (so a retry of a
-- successful call replays instead of tripping over the invoice's new state),
-- (3) post to the ledger via post_transaction, (4) lock the invoice row LAST and
-- re-validate. Locks are therefore always taken in the order advisory key -> accounts
-- -> invoice, everywhere, so these functions cannot deadlock with each other.
-- Any RAISE after posting rolls back the whole function, ledger entries included.
--
-- Error codes: LD050 overpayment, LD051 wrong account types, LD052 invoice not found,
-- LD053 invoice not in a state that allows this, LD054 illegal change (trigger),
-- LD056 total <> lines (trigger), LD043 direct reversal of invoice transactions.
-- ------------------------------------------------------------ create_invoice
CREATE FUNCTION ledger.create_invoice(
    p_customer uuid,
    p_receivable uuid,
    p_revenue uuid,
    p_currency text,
    p_lines jsonb,
    p_idempotency_key text,
    p_due_at timestamptz DEFAULT NULL,
    p_created_by text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog,
    ledger AS $$
DECLARE v_bad integer;
v_total bigint;
v_n integer;
v_invoice_id uuid;
v_number text;
v_post jsonb;
v_txn uuid;
v_existing record;
BEGIN -- Lines: a non-empty array of {description, quantity, unit_amount}.
IF p_lines IS NULL
OR jsonb_typeof(p_lines) <> 'array'
OR jsonb_array_length(p_lines) = 0 THEN RAISE EXCEPTION 'an invoice needs at least one line' USING ERRCODE = 'LD030';
END IF;
BEGIN
SELECT count(*) FILTER (
        WHERE x.description IS NULL
            OR length(btrim(x.description)) = 0
            OR x.quantity IS NULL
            OR x.quantity <= 0
            OR x.unit_amount IS NULL
            OR x.unit_amount <= 0
    ),
    sum(x.quantity::bigint * x.unit_amount) INTO v_bad,
    v_total
FROM jsonb_to_recordset(p_lines) AS x(
        description text,
        quantity integer,
        unit_amount bigint
    );
EXCEPTION
WHEN invalid_text_representation
OR numeric_value_out_of_range
OR invalid_parameter_value THEN RAISE EXCEPTION 'malformed invoice lines' USING ERRCODE = 'LD030';
END;
IF v_bad > 0 THEN RAISE EXCEPTION 'every line needs a description, quantity > 0 and unit_amount > 0' USING ERRCODE = 'LD030';
END IF;
-- Account roles: customer = liability wallet, receivable = asset, revenue = revenue.
-- (Missing accounts also fail this check.) Currency is verified separately.
SELECT count(*) INTO v_n
FROM ledger.accounts a
WHERE (
        a.id = p_customer
        AND a.type = 'liability'
    )
    OR (
        a.id = p_receivable
        AND a.type = 'asset'
    )
    OR (
        a.id = p_revenue
        AND a.type = 'revenue'
    );
IF v_n <> 3 THEN RAISE EXCEPTION 'an invoice needs a liability customer account, an asset receivable account and a revenue account' USING ERRCODE = 'LD051';
END IF;
SELECT count(*) INTO v_n
FROM ledger.accounts a
WHERE a.id IN (p_customer, p_receivable, p_revenue)
    AND a.currency::text = p_currency;
IF v_n <> 3 THEN RAISE EXCEPTION 'all invoice accounts must be in the invoice currency' USING ERRCODE = 'LD031';
END IF;
-- The invoice id is generated up front and stored as transaction metadata. It is
-- NOT part of the hashed request, so replays of the same request hash identically.
v_invoice_id := uuidv7();
v_post := ledger.post_transaction(
    p_idempotency_key,
    jsonb_build_object(
        'op',
        'create_invoice',
        'customer',
        p_customer,
        'receivable',
        p_receivable,
        'revenue',
        p_revenue,
        'currency',
        p_currency,
        'lines',
        p_lines,
        'due_at',
        to_jsonb(p_due_at AT TIME ZONE 'UTC')
    ),
    'invoice_issue',
    jsonb_build_array(
        jsonb_build_object(
            'account_id',
            p_receivable,
            'direction',
            'D',
            'amount',
            v_total,
            'currency',
            p_currency
        ),
        jsonb_build_object(
            'account_id',
            p_revenue,
            'direction',
            'C',
            'amount',
            v_total,
            'currency',
            p_currency
        )
    ),
    p_description => 'Invoice issued',
    p_created_by => p_created_by,
    p_metadata => jsonb_build_object('invoice_id', v_invoice_id)
);
v_txn := (v_post->>'transaction_id')::uuid;
IF (v_post->>'replayed')::boolean THEN
SELECT i.id,
    i.number,
    i.status INTO v_existing
FROM ledger.invoices i
WHERE i.issue_transaction_id = v_txn;
RETURN jsonb_build_object(
    'invoice_id',
    v_existing.id,
    'number',
    v_existing.number,
    'status',
    v_existing.status,
    'transaction_id',
    v_txn,
    'replayed',
    true
);
END IF;
INSERT INTO ledger.invoices (
        id,
        customer_account_id,
        receivable_account_id,
        revenue_account_id,
        currency,
        total_amount,
        due_at,
        issue_transaction_id
    )
VALUES (
        v_invoice_id,
        p_customer,
        p_receivable,
        p_revenue,
        p_currency,
        v_total,
        p_due_at,
        v_txn
    )
RETURNING number INTO v_number;
INSERT INTO ledger.invoice_lines (invoice_id, description, quantity, unit_amount)
SELECT v_invoice_id,
    btrim(x.description),
    x.quantity,
    x.unit_amount
FROM jsonb_to_recordset(p_lines) AS x(
        description text,
        quantity integer,
        unit_amount bigint
    );
RETURN jsonb_build_object(
    'invoice_id',
    v_invoice_id,
    'number',
    v_number,
    'status',
    'issued',
    'total_amount',
    v_total,
    'transaction_id',
    v_txn,
    'replayed',
    false
);
END $$;
-- ------------------------------------------------------ record_invoice_payment
CREATE FUNCTION ledger.record_invoice_payment(
    p_invoice_id uuid,
    p_amount bigint,
    p_idempotency_key text,
    p_created_by text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog,
    ledger AS $$
DECLARE v_inv ledger.invoices %ROWTYPE;
v_post jsonb;
v_txn uuid;
BEGIN IF p_invoice_id IS NULL
OR p_amount IS NULL
OR p_amount <= 0 THEN RAISE EXCEPTION 'an invoice id and an amount greater than zero are required' USING ERRCODE = 'LD030';
END IF;
SELECT * INTO v_inv
FROM ledger.invoices
WHERE id = p_invoice_id;
-- unlocked probe
IF NOT FOUND THEN RAISE EXCEPTION 'invoice % not found',
p_invoice_id USING ERRCODE = 'LD052';
END IF;
-- Skipped when the key is known: post_transaction then decides replay vs mismatch.
IF NOT EXISTS (
    SELECT 1
    FROM ledger.idempotency_keys k
    WHERE k.key = p_idempotency_key
) THEN IF v_inv.status NOT IN ('issued', 'partially_paid') THEN RAISE EXCEPTION 'invoice % is % and cannot take payments',
v_inv.id,
v_inv.status USING ERRCODE = 'LD053';
END IF;
IF p_amount > v_inv.total_amount - v_inv.amount_paid THEN RAISE EXCEPTION 'payment % exceeds the remaining balance %',
p_amount,
v_inv.total_amount - v_inv.amount_paid USING ERRCODE = 'LD050';
END IF;
END IF;
-- Customer wallet pays (debit: liability decreases; the no-overdraft rule applies),
-- receivable is settled (credit: asset decreases).
v_post := ledger.post_transaction(
    p_idempotency_key,
    jsonb_build_object(
        'op',
        'invoice_payment',
        'invoice_id',
        p_invoice_id,
        'amount',
        p_amount
    ),
    'invoice_payment',
    jsonb_build_array(
        jsonb_build_object(
            'account_id',
            v_inv.customer_account_id,
            'direction',
            'D',
            'amount',
            p_amount,
            'currency',
            v_inv.currency
        ),
        jsonb_build_object(
            'account_id',
            v_inv.receivable_account_id,
            'direction',
            'C',
            'amount',
            p_amount,
            'currency',
            v_inv.currency
        )
    ),
    p_description => 'Payment for invoice ' || v_inv.number,
    p_created_by => p_created_by,
    p_metadata => jsonb_build_object('invoice_id', p_invoice_id)
);
v_txn := (v_post->>'transaction_id')::uuid;
IF (v_post->>'replayed')::boolean THEN
SELECT * INTO v_inv
FROM ledger.invoices
WHERE id = p_invoice_id;
RETURN jsonb_build_object(
    'invoice_id',
    v_inv.id,
    'transaction_id',
    v_txn,
    'status',
    v_inv.status,
    'amount_paid',
    v_inv.amount_paid,
    'replayed',
    true
);
END IF;
-- Lock the invoice LAST and re-check: two payments racing past the probe serialise
-- here, and the loser fails cleanly (everything, ledger entries included, rolls back).
SELECT * INTO v_inv
FROM ledger.invoices
WHERE id = p_invoice_id FOR
UPDATE;
IF v_inv.status NOT IN ('issued', 'partially_paid') THEN RAISE EXCEPTION 'invoice % is % and cannot take payments',
v_inv.id,
v_inv.status USING ERRCODE = 'LD053';
END IF;
IF p_amount > v_inv.total_amount - v_inv.amount_paid THEN RAISE EXCEPTION 'payment % exceeds the remaining balance %',
p_amount,
v_inv.total_amount - v_inv.amount_paid USING ERRCODE = 'LD050';
END IF;
INSERT INTO ledger.invoice_payments (invoice_id, transaction_id, amount)
VALUES (p_invoice_id, v_txn, p_amount);
UPDATE ledger.invoices
SET amount_paid = amount_paid + p_amount,
    status = CASE
        WHEN amount_paid + p_amount = total_amount THEN 'paid'
        ELSE 'partially_paid'
    END,
    updated_at = now()
WHERE id = p_invoice_id
RETURNING * INTO v_inv;
RETURN jsonb_build_object(
    'invoice_id',
    v_inv.id,
    'transaction_id',
    v_txn,
    'status',
    v_inv.status,
    'amount_paid',
    v_inv.amount_paid,
    'remaining',
    v_inv.total_amount - v_inv.amount_paid,
    'replayed',
    false
);
END $$;
-- ---------------------------------------------------------------- void_invoice
-- Credit-note style: posts the exact opposite of the ISSUE transaction. Only allowed
-- while nothing has been paid. (Refunding a paid invoice is out of scope.)
CREATE FUNCTION ledger.void_invoice(
    p_invoice_id uuid,
    p_idempotency_key text,
    p_created_by text DEFAULT NULL,
    p_reason text DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog,
    ledger AS $$
DECLARE v_inv ledger.invoices %ROWTYPE;
v_entries jsonb;
v_post jsonb;
v_txn uuid;
BEGIN IF p_invoice_id IS NULL THEN RAISE EXCEPTION 'an invoice id is required' USING ERRCODE = 'LD030';
END IF;
SELECT * INTO v_inv
FROM ledger.invoices
WHERE id = p_invoice_id;
-- unlocked probe
IF NOT FOUND THEN RAISE EXCEPTION 'invoice % not found',
p_invoice_id USING ERRCODE = 'LD052';
END IF;
IF NOT EXISTS (
    SELECT 1
    FROM ledger.idempotency_keys k
    WHERE k.key = p_idempotency_key
)
AND v_inv.status <> 'issued' THEN RAISE EXCEPTION 'invoice % is % and cannot be voided (only unpaid issued invoices can)',
v_inv.id,
v_inv.status USING ERRCODE = 'LD053';
END IF;
-- Flip every line of the issue transaction: D <-> C, same amounts.
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
WHERE e.transaction_id = v_inv.issue_transaction_id;
-- Posted directly (not via reverse_transaction) so the reversal can carry the
-- invoice_void marker that guard_invoice_reversal looks for.
v_post := ledger.post_transaction(
    p_idempotency_key,
    jsonb_build_object(
        'op',
        'void_invoice',
        'invoice_id',
        p_invoice_id,
        'reason',
        p_reason
    ),
    'reversal',
    v_entries,
    p_description => COALESCE(p_reason, 'Void of invoice ' || v_inv.number),
    p_created_by => p_created_by,
    p_metadata => jsonb_build_object('invoice_id', p_invoice_id, 'invoice_void', true),
    p_reversal_of => v_inv.issue_transaction_id
);
v_txn := (v_post->>'transaction_id')::uuid;
IF (v_post->>'replayed')::boolean THEN RETURN jsonb_build_object(
    'invoice_id',
    p_invoice_id,
    'status',
    'void',
    'transaction_id',
    v_txn,
    'replayed',
    true
);
END IF;
SELECT * INTO v_inv
FROM ledger.invoices
WHERE id = p_invoice_id FOR
UPDATE;
IF v_inv.status <> 'issued' THEN RAISE EXCEPTION 'invoice % is % and cannot be voided',
v_inv.id,
v_inv.status USING ERRCODE = 'LD053';
END IF;
UPDATE ledger.invoices
SET status = 'void',
    void_transaction_id = v_txn,
    updated_at = now()
WHERE id = p_invoice_id;
RETURN jsonb_build_object(
    'invoice_id',
    p_invoice_id,
    'status',
    'void',
    'transaction_id',
    v_txn,
    'replayed',
    false
);
END $$;
COMMENT ON FUNCTION ledger.create_invoice(
    uuid,
    uuid,
    uuid,
    text,
    jsonb,
    text,
    timestamptz,
    text
) IS 'Issues an invoice: posts D receivable / C revenue and writes the invoice and its lines. Idempotent.';
COMMENT ON FUNCTION ledger.record_invoice_payment(uuid, bigint, text, text) IS 'Applies a full or partial payment from the customer wallet. Rejects overpayment. Idempotent.';
COMMENT ON FUNCTION ledger.void_invoice(uuid, text, text, text) IS 'Voids an unpaid invoice by posting the reverse of its issue transaction. Idempotent.';
-- API boundary: functions only.
REVOKE ALL ON FUNCTION ledger.create_invoice(
    uuid,
    uuid,
    uuid,
    text,
    jsonb,
    text,
    timestamptz,
    text
)
FROM PUBLIC;
REVOKE ALL ON FUNCTION ledger.record_invoice_payment(uuid, bigint, text, text)
FROM PUBLIC;
REVOKE ALL ON FUNCTION ledger.void_invoice(uuid, text, text, text)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION ledger.create_invoice(
        uuid,
        uuid,
        uuid,
        text,
        jsonb,
        text,
        timestamptz,
        text
    ) TO ledger_app;
GRANT EXECUTE ON FUNCTION ledger.record_invoice_payment(uuid, bigint, text, text) TO ledger_app;
GRANT EXECUTE ON FUNCTION ledger.void_invoice(uuid, text, text, text) TO ledger_app;
RESET ROLE;
-- migrate:down
SET LOCAL ROLE ledger_owner;
DROP FUNCTION ledger.void_invoice(uuid, text, text, text);
DROP FUNCTION ledger.record_invoice_payment(uuid, bigint, text, text);
DROP FUNCTION ledger.create_invoice(
    uuid,
    uuid,
    uuid,
    text,
    jsonb,
    text,
    timestamptz,
    text
);
RESET ROLE;