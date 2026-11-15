# Design Decisions

Each decision: Context / Options / Decision / Tradeoffs.

## 1. Money is `bigint` in minor units

- **Context:** A ledger must never lose or invent a cent.
- **Options:** `float`/`double` (binary rounding errors), `numeric(p,s)` (exact, slower, wide), `bigint` minor units (exact, fast).
- **Decision:** `bigint` minor units (cents), always stored beside a currency code.
- **Tradeoffs:** The app must know each currency's minor-unit exponent (USD 2, UGX 0, KWD 3) to display amounts. Hard ceiling of about 9.2e18 minor units, far beyond real use.

## 2. Time is `timestamptz`, UTC

- **Decision:** All timestamps are `timestamptz`; the server and clients treat UTC as the standard.
- **Tradeoffs:** Display-time conversion is the client's job. This removes ambiguity around DST and offsets, which matters for audit trails.

## 3. Identifiers (proposed, confirmed in Phase 2)

- **Proposal:** UUID v7 (`uuidv7()`, built into PostgreSQL 18) for `accounts` and `transactions`; `bigint GENERATED ALWAYS AS IDENTITY` for high-volume `entries`.
- **Tradeoffs:** UUIDs are safe to expose and generate anywhere, but are larger than bigint. v7 is time-ordered, so index locality is much better than random v4. Verify the hosting provider's PostgreSQL version supports `uuidv7()` before Phase 11; the fallback is `gen_random_uuid()`.

## 4. Roles and least privilege

- **Decision:** `ledger_owner` (owns objects, runs migrations), `ledger_app` (API, explicit per-table grants only), `ledger_readonly` (SELECT only). No superuser credentials in the app.
- **Tradeoffs:** More setup than a single role, but a compromised API cannot alter the schema, and in Phase 3 it cannot UPDATE or DELETE ledger rows.

## 5. Dedicated schema and pinned `search_path`

- **Decision:** All objects in schema `ledger`; each role has `search_path = ledger, public`.
- **Tradeoffs:** Slightly more typing (`ledger.accounts` in migrations), in exchange for protection against object shadowing.

## 6. Naming conventions

- snake_case; plural table names; `<table>_id` for foreign keys; `_at` suffix for timestamps; constraint names spell out the rule (`currency_code_format`).
