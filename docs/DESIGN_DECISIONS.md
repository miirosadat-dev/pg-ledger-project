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

## 3. Identifiers (confirmed)

- **Decision:** `uuidv7()` (built into PostgreSQL 18) for accounts and transactions; `bigint GENERATED ALWAYS AS IDENTITY` for entries.
- **Tradeoffs:** UUIDs are safe to expose and large; v7 is time-ordered, so index locality is good. Neon must run PostgreSQL 18 or newer (verify in Phase 11; fallback `gen_random_uuid()`). When we partition `entries` by time in Phase 7, its primary key must include the partition column, so it becomes `(id, created_at)`.

## 7. Debit/credit direction column vs signed amounts

- **Options:** `direction` ('D'/'C') plus positive `amount`, or one signed amount.
- **Decision:** direction column. Amounts are strictly positive (domain-enforced); "balanced" means debit total equals credit total per currency.
- **Tradeoffs:** balance math needs a `CASE`, but the model matches real accounting books and cannot hide a sign mistake.

## 8. Balances stored on the account's normal side

- **Decision:** a generated `normal_side` column; the cached balance is credits-minus-debits for liabilities/equity/revenue and debits-minus-credits for assets/expenses. User wallets are liabilities, so a funded wallet shows a positive balance.
- **Tradeoffs:** one rule to explain, but "non-negative" is then a natural `balance >= 0` check.

## 9. Invariants as constraints instead of triggers

- **Currency match:** composite FK `entries(account_id, currency) -> accounts(id, currency)`. **No overdraft:** `CHECK (allow_negative OR balance >= 0)` on `account_balances`, with `allow_negative` mirrored through a composite FK.
- **Tradeoffs:** declarative constraints are faster, can't be disabled the way triggers can, and are self-documenting. Cost: a deliberately redundant column and extra UNIQUE constraints that exist only as FK targets.

## 10. Idempotency key on transactions is not a foreign key

- **Decision:** `transactions.idempotency_key` is `UNIQUE` text with no FK to `idempotency_keys`.
- **Tradeoffs:** expired keys can be purged without touching immutable ledger rows; the cost is no database-level link between the two tables.

## 11. Text + CHECK instead of enum types

- **Decision:** `type`/`status` columns use `text` with `CHECK (... IN (...))`.
- **Tradeoffs:** changing the allowed values is a simple constraint swap, while enum values can't be removed once added. Cost: no type-level documentation of the values.
