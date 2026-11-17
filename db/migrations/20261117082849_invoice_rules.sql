-- migrate:up
SET LOCAL ROLE ledger_owner;
-- State machine: only legal transitions, frozen identity columns
CREATE FUNCTION ledger.invoices_enforce_state_machine() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog,
    ledger AS $$ BEGIN -- Everything except status, amount_paid, void link and updated_at is frozen.
    IF ROW(
        NEW.id,
        NEW.number,
        NEW.customer_account_id,
        NEW.receivable_account_id,
        NEW.revenue_account_id,
        NEW.currency,
        NEW.total_amount,
        NEW.issue_transaction_id,
        NEW.due_at,
        NEW.issued_at,
        NEW.created_at
    ) IS DISTINCT
FROM ROW(
        OLD.id,
        OLD.number,
        OLD.customer_account_id,
        OLD.receivable_account_id,
        OLD.revenue_account_id,
        OLD.currency,
        OLD.total_amount,
        OLD.issue_transaction_id,
        OLD.due_at,
        OLD.issued_at,
        OLD.created_at
    ) THEN RAISE EXCEPTION 'invoice % : identity and amount fields are immutable',
    OLD.id USING ERRCODE = 'LD054';
END IF;
-- paid and void are terminal.
IF OLD.status IN ('paid', 'void') THEN RAISE EXCEPTION 'invoice % is % and can no longer change',
OLD.id,
OLD.status USING ERRCODE = 'LD054';
END IF;
-- Legal moves: issued -> partially_paid | paid | void ; partially_paid -> paid.
-- (partially_paid -> partially_paid, i.e. another partial payment, keeps the status.)
IF NEW.status <> OLD.status
AND NOT (
    (
        OLD.status = 'issued'
        AND NEW.status IN ('partially_paid', 'paid', 'void')
    )
    OR (
        OLD.status = 'partially_paid'
        AND NEW.status = 'paid'
    )
) THEN RAISE EXCEPTION 'invoice % : illegal status change % -> %',
OLD.id,
OLD.status,
NEW.status USING ERRCODE = 'LD054';
END IF;
-- Money paid can only grow.
IF NEW.amount_paid < OLD.amount_paid THEN RAISE EXCEPTION 'invoice % : amount_paid cannot decrease',
OLD.id USING ERRCODE = 'LD054';
END IF;
RETURN NEW;
END $$;
CREATE TRIGGER invoices_state_machine BEFORE
UPDATE ON ledger.invoices FOR EACH ROW EXECUTE FUNCTION ledger.invoices_enforce_state_machine();
-- Invoice total must equal the sum of its lines (checked at COMMIT)
-- Deferred for the same reason as the journal balance check: the header is inserted
-- before its lines. Fires for the invoice row AND for each line.
CREATE FUNCTION ledger.assert_invoice_total() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog,
    ledger AS $$
DECLARE v_id uuid;
v_total numeric;
v_sum numeric;
BEGIN v_id := CASE
    WHEN TG_TABLE_NAME = 'invoices' THEN NEW.id
    ELSE NEW.invoice_id
END;
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
CREATE CONSTRAINT TRIGGER invoices_total_check
AFTER
INSERT ON ledger.invoices DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ledger.assert_invoice_total();
CREATE CONSTRAINT TRIGGER invoice_lines_total_check
AFTER
INSERT ON ledger.invoice_lines DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION ledger.assert_invoice_total();
-- Immutability (reuses reject_mutation from Phase 3)
CREATE TRIGGER invoices_no_delete BEFORE DELETE ON ledger.invoices FOR EACH ROW EXECUTE FUNCTION ledger.reject_mutation();
CREATE TRIGGER invoices_no_truncate BEFORE TRUNCATE ON ledger.invoices FOR EACH STATEMENT EXECUTE FUNCTION ledger.reject_mutation();
CREATE TRIGGER invoice_lines_immutable BEFORE
UPDATE
    OR DELETE ON ledger.invoice_lines FOR EACH ROW EXECUTE FUNCTION ledger.reject_mutation();
CREATE TRIGGER invoice_lines_no_truncate BEFORE TRUNCATE ON ledger.invoice_lines FOR EACH STATEMENT EXECUTE FUNCTION ledger.reject_mutation();
CREATE TRIGGER invoice_payments_immutable BEFORE
UPDATE
    OR DELETE ON ledger.invoice_payments FOR EACH ROW EXECUTE FUNCTION ledger.reject_mutation();
CREATE TRIGGER invoice_payments_no_truncate BEFORE TRUNCATE ON ledger.invoice_payments FOR EACH STATEMENT EXECUTE FUNCTION ledger.reject_mutation();
-- Guard: invoice transactions can only be reversed through void_invoice
-- Without this, the generic reverse_transaction() could undo an invoice's ledger entries
-- and leave the invoice row saying "issued". void_invoice marks its reversal with
-- metadata.invoice_void = true. The app role cannot forge that marker: metadata is only
-- written by post_transaction, which the app cannot call, and reverse_transaction
-- passes no metadata.
CREATE FUNCTION ledger.guard_invoice_reversal() RETURNS trigger LANGUAGE plpgsql
SET search_path = pg_catalog,
    ledger AS $$ BEGIN IF NEW.reversal_of IS NOT NULL
    AND COALESCE(NEW.metadata->>'invoice_void', '') <> 'true'
    AND EXISTS (
        SELECT 1
        FROM ledger.transactions o
        WHERE o.id = NEW.reversal_of
            AND o.type IN ('invoice_issue', 'invoice_payment')
    ) THEN RAISE EXCEPTION 'invoice transactions cannot be reversed directly; use void_invoice' USING ERRCODE = 'LD043';
END IF;
RETURN NEW;
END $$;
CREATE TRIGGER transactions_guard_invoice_reversal BEFORE
INSERT ON ledger.transactions FOR EACH ROW EXECUTE FUNCTION ledger.guard_invoice_reversal();
RESET ROLE;
-- migrate:down
SET LOCAL ROLE ledger_owner;
DROP TRIGGER transactions_guard_invoice_reversal ON ledger.transactions;
DROP FUNCTION ledger.guard_invoice_reversal();
DROP TRIGGER invoice_payments_no_truncate ON ledger.invoice_payments;
DROP TRIGGER invoice_payments_immutable ON ledger.invoice_payments;
DROP TRIGGER invoice_lines_no_truncate ON ledger.invoice_lines;
DROP TRIGGER invoice_lines_immutable ON ledger.invoice_lines;
DROP TRIGGER invoices_no_truncate ON ledger.invoices;
DROP TRIGGER invoices_no_delete ON ledger.invoices;
DROP TRIGGER invoice_lines_total_check ON ledger.invoice_lines;
DROP TRIGGER invoices_total_check ON ledger.invoices;
DROP FUNCTION ledger.assert_invoice_total();
DROP TRIGGER invoices_state_machine ON ledger.invoices;
DROP FUNCTION ledger.invoices_enforce_state_machine();
RESET ROLE;