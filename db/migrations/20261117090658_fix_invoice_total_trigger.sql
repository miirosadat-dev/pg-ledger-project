-- migrate:up
SET LOCAL ROLE ledger_owner;
-- Replaces the function body only; the two constraint triggers that call it stay attached.
-- Fix: PL/pgSQL fetches every NEW.<field> referenced in an expression before evaluating
-- it, so an inline CASE over NEW.id / NEW.invoice_id failed on whichever table lacked the
-- field. An IF statement only reads the branch it takes.
CREATE OR REPLACE FUNCTION ledger.assert_invoice_total() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog,
    ledger AS $$
DECLARE v_id uuid;
v_total numeric;
v_sum numeric;
BEGIN IF TG_TABLE_NAME = 'invoices' THEN v_id := NEW.id;
ELSE v_id := NEW.invoice_id;
END IF;
SELECT total_amount INTO v_total
FROM ledger.invoices
WHERE id = v_id;
SELECT COALESCE(sum(line_total), 0) INTO v_sum
FROM ledger.invoice_lines
WHERE invoice_id = v_id;
IF v_total IS DISTINCT
FROM v_sum THEN RAISE EXCEPTION 'invoice % total % does not equal the sum of its lines %',
    v_id,
    v_total,
    v_sum USING ERRCODE = 'LD056';
END IF;
RETURN NULL;
END $$;
RESET ROLE;
-- migrate:down
-- Intentionally empty: the previous body could not run at all, so there is nothing
-- worth restoring. Rolling back the earlier invoice migrations removes the function.
SELECT 1;