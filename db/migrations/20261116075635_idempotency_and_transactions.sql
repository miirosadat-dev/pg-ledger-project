-- migrate:up
SET LOCAL ROLE ledger_owner;
-- --------------------------------------------------------- idempotency_keys
-- Clients send an Idempotency-Key header with each money-moving request. We store the
-- key and a hash of the request body:
--   same key + same hash      -> replay: return the stored response, post nothing
--   same key + different hash -> client bug: reject with a clear error
CREATE TABLE ledger.idempotency_keys (
    key text PRIMARY KEY,
    -- SHA-256 of the canonical request body, as 64 lowercase hex characters.
    request_hash char(64) NOT NULL,
    -- Original request kept for auditability (invariant 6).
    request_payload jsonb NOT NULL,
    -- in_progress = a request is currently running; completed = response is stored.
    status text NOT NULL DEFAULT 'in_progress',
    response jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    expires_at timestamptz NOT NULL DEFAULT now() + interval '24 hours',
    CONSTRAINT idempotency_key_length CHECK (
        length(key) BETWEEN 1 AND 255
    ),
    CONSTRAINT idempotency_hash_format CHECK (request_hash ~ '^[0-9a-f]{64}$'),
    CONSTRAINT idempotency_status_valid CHECK (status IN ('in_progress', 'completed')),
    CONSTRAINT idempotency_expiry_after_creation CHECK (expires_at > created_at),
    -- A completed key MUST carry its response; an in-progress one must not yet.
    CONSTRAINT idempotency_response_matches_status CHECK ((status = 'completed') = (response IS NOT NULL))
);
COMMENT ON TABLE ledger.idempotency_keys IS 'Request fingerprints so retries never create duplicate transactions.';
-- ------------------------------------------------------------- transactions
-- The journal HEADER: one row per business event. Its lines live in `entries`.
CREATE TABLE ledger.transactions (
    id uuid PRIMARY KEY DEFAULT uuidv7(),
    type text NOT NULL,
    description text,
    -- When the event counts for accounting (may be back-dated); created_at is when we
    -- recorded it. Keeping both is standard ledger practice.
    effective_at timestamptz NOT NULL DEFAULT now(),
    created_at timestamptz NOT NULL DEFAULT now(),
    -- Who or what caused it (user id, service name). Part of the audit trail.
    created_by text,
    -- The transaction this one reverses. UNIQUE = a transaction can be reversed at most
    -- once, guaranteed by the database even if two reversals race each other.
    reversal_of uuid UNIQUE REFERENCES ledger.transactions (id),
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    -- The client's idempotency key. Deliberately NOT a foreign key: keys expire and are
    -- purged, but ledger rows are immutable and must outlive them. UNIQUE still
    -- guarantees one transaction per key. NULL is allowed (internal postings).
    idempotency_key text UNIQUE,
    CONSTRAINT transactions_type_valid CHECK (
        type IN (
            'transfer',
            'deposit',
            'withdrawal',
            'invoice_issue',
            'invoice_payment',
            'reversal',
            'adjustment'
        )
    ),
    -- A reversal must point at its original; nothing else may.
    CONSTRAINT transactions_reversal_consistency CHECK ((type = 'reversal') = (reversal_of IS NOT NULL)),
    CONSTRAINT transactions_not_self_reversal CHECK (
        reversal_of IS DISTINCT
        FROM id
    ),
    CONSTRAINT transactions_metadata_is_object CHECK (jsonb_typeof(metadata) = 'object')
);
COMMENT ON TABLE ledger.transactions IS 'Journal header. Immutable (enforced in Phase 3); corrections are reversal transactions.';
COMMENT ON COLUMN ledger.transactions.reversal_of IS 'Original transaction this one reverses. UNIQUE prevents double reversal.';
COMMENT ON COLUMN ledger.transactions.idempotency_key IS 'Client key; unique so a retry cannot create a second transaction. Not an FK on purpose.';
RESET ROLE;
-- migrate:down
SET LOCAL ROLE ledger_owner;
DROP TABLE ledger.transactions;
DROP TABLE ledger.idempotency_keys;
RESET ROLE;