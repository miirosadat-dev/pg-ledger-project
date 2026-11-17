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

## 12. Advisory lock for the idempotency key, row locks for accounts

- **Context:** Concurrent postings must not duplicate a request or deadlock.
- **Options:** advisory locks everywhere, row locks everywhere, or each where it fits.
- **Decision:** `pg_advisory_xact_lock(hashtextextended(key, 0))` first (the key has no row yet), then `SELECT ... FOR UPDATE` on `account_balances` in sorted account-id order.
- **Tradeoffs:** one fixed lock order across all callers rules out lock-order deadlocks. The `xact` advisory variant releases at transaction end and is safe behind transaction-level poolers (Neon); session-level `pg_advisory_lock` would leak across pooled connections. Hash collisions only cause extra waiting.

## 13. The API can only call functions

- **Decision:** posting functions are `SECURITY DEFINER` with a pinned `search_path`; `ledger_app` has no INSERT on `entries`, `transactions` or `idempotency_keys`, and no UPDATE on balances. `post_transaction` is internal.
- **Tradeoffs:** the security boundary is small and auditable, but all writes must go through functions, so tests and ad-hoc fixes need them too. A bug inside a definer function runs with owner rights, so these functions stay short and are reviewed first.

## 14. Idempotency hash is computed in the database

- **Decision:** SHA-256 over the `jsonb` text of a logical request object built inside each public function.
- **Tradeoffs:** clients cannot send a wrong or forged hash, and key reuse is judged on the logical request. Relies on `jsonb` text output being canonical, which holds in practice. A failed request rolls back its key, so only successful requests are replayable.

## 15. Concurrency

- **Context:** Concurrent requests must never lose money, overdraw, duplicate, or deadlock.
- **Demonstrated anomalies** (`db/demos/phase5_setup.sql`):
  1. _Lost update_ under READ COMMITTED with an app-side read-modify-write: 1000 + 100 + 100 ended at 1100. Fixed by atomic `balance = balance + delta` (our balance trigger) or by REPEATABLE READ, which raises `40001`.
  2. _Write skew_: two sessions each passed a cross-row check ("joint wallets total >= 0") and wrote different rows; the total reached -100 under REPEATABLE READ. SERIALIZABLE aborted one session with `40001`.
  3. _Deadlock_: opposite lock order on two rows gives `40P01` within ~1 s. Locking rows in sorted order made the second session wait instead.
  4. _Idempotency race_: two same-key requests serialise on `pg_advisory_xact_lock`; the second returns `replayed: true`.
- **Decision:** posting functions run at the default READ COMMITTED and take explicit locks: advisory lock on the idempotency key, then `FOR UPDATE` on `account_balances` in sorted account-id order. Our invariants are per-row (`balance >= 0`) or per-transaction (debits = credits), both safe under row locks.
- **Where each level is used:**
  - Posting (`transfer`, `deposit`, `withdraw`, `reverse_transaction`): READ COMMITTED + locks.
  - Consistent multi-query reports (reconciliation, trial balance): `REPEATABLE READ READ ONLY`, so all queries see one snapshot.
  - SERIALIZABLE: reserved for any future cross-row business rule (for example a per-customer total limit) that cannot be expressed as a constraint.
- **Tradeoffs:** explicit locks mean predictable latency and few retries but require discipline (every writer must follow the lock order, which one function guarantees). SERIALIZABLE everywhere would be simpler to reason about, but costs predicate-lock overhead and frequent `40001` retries on hot accounts. Call the posting functions as the first statement of a transaction; at higher isolation levels a snapshot taken earlier cannot see a just-committed duplicate key.

### Retry rules

1. Retry **only** `40001` (serialization failure) and `40P01` (deadlock). Also retry `23505` on `idempotency_keys_pkey` (the replay will succeed on the second attempt). Never retry `LD*` business errors, constraint violations, or `42501`: they are deterministic and will fail again.
2. Retry the **whole transaction** from `BEGIN`, never a single statement.
3. Only retry money-moving work that carries an idempotency key. A replay returns the original result, so a retry can never double-post.
4. Capped exponential backoff with full jitter: `delay = random(0, min(cap, base * 2^attempt))`, base 20 ms, cap 500 ms, at most 5 attempts. Jitter prevents contending clients retrying in lockstep.
5. After the final attempt, surface the error as HTTP 409/503 with a `Retry-After` hint. The helper is implemented in `src/db/pool.ts` in Phase 8.

## 16. Invoice accounting and state machine

- **Decision:** issue = D receivable (asset) / C revenue; payment = D customer wallet / C receivable; void = exact reversal of the issue. Statuses: issued, partially_paid, paid, void (paid and void terminal). Validity is a CHECK tying status to `amount_paid`; legal transitions and frozen columns are a BEFORE UPDATE trigger.
- **Tradeoffs:** payments debit the wallet, so the no-overdraft rule protects customers for free. Void is allowed only before any payment; refunds of paid invoices would need credit notes and are out of scope. Invoice numbers come from a sequence and can have gaps after rollbacks.

## 17. Probe the idempotency key before validating state

- **Context:** A retry of a payment that already succeeded must replay, not fail with "invoice already paid".
- **Decision:** each invoice function validates state only when the key is unknown, posts through `post_transaction` (which replays or rejects a mismatched payload), then locks the invoice row last and re-validates. Lock order is always advisory key, accounts, invoice.
- **Tradeoffs:** state is checked twice (unlocked probe for correct error codes, locked re-check for correctness under races). Any error after posting rolls the ledger entries back with it.

## 18. Guarding invoice transactions against generic reversal

- **Decision:** a BEFORE INSERT trigger rejects `reverse_transaction` on `invoice_issue` / `invoice_payment` transactions (LD043). `void_invoice` posts its reversal with a metadata marker only database functions can write.
- **Tradeoffs:** one more trigger, but the invoice row and its ledger entries cannot drift apart.

## 19. Partitioning `entries` by month

- **Context:** `entries` is the largest, append-only table; time-bounded queries and retention are the common access patterns.
- **Options:** one big table; hash partitions; range partitions by `created_at`.
- **Decision:** monthly range partitions on `created_at`, a default partition as a safety net, helper functions to create partitions (`create_entries_partition`, `ensure_entries_partitions`), ledger guards attached to every partition.
- **Tradeoffs:** the primary key becomes `(id, created_at)`, so uniqueness of `id` alone is not database-enforced (it comes from one sequence); no foreign keys may point at `entries`; row triggers live on each partition, not the parent; a default partition holding rows blocks creating an overlapping partition, so partitions are created ahead of time on a schedule. In return: partition pruning for time-bounded queries and cheap archival by detaching old months.

## 20. Statements, reconciliation and the trial balance

- **Statement:** window function over the account's entries with an opening balance, so filters never distort running totals. Ordered by `(created_at, id)` because all lines of a transaction share `created_at`.
- **Reconciliation:** `reconcile()` returns only discrepancies (currency balance, per-transaction balance, cached balance vs entries). It is the executable proof of invariant 7 and runs in tests and via the API.
- **Trial balance:** a materialized view with a unique index, refreshed `CONCURRENTLY` through a SECURITY DEFINER function. Reports tolerate staleness; live numbers come from `account_balances`. Concurrent refresh keeps readers unblocked but costs more than a plain refresh and requires the unique index.

## 21. Indexing strategy for entries

- **Decision:** two indexes on the partitioned parent: `(transaction_id)` for the balance check and loading a transaction's lines, and `(account_id, created_at, id)` for statements ("one account, in time order"). Keys: equality first, then the range, then the tiebreaker.
- **Evidence:** `docs/benchmarks.md` (generated by `npm run bench`) holds the EXPLAIN (ANALYZE, BUFFERS) plans before and after, the partition-pruning comparison, and the cost of building the index on ~1M rows.
- **Tradeoffs:** every entry insert maintains one more index; in return statements and opening-balance scans stop reading whole partitions. No index on `direction` or `amount`: low selectivity or never filtered on.
