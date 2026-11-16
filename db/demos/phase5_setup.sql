-- Scratch tables for the concurrency demos. Safe to re-run: re-running IS the reset.
DROP SCHEMA IF EXISTS demo CASCADE;
CREATE SCHEMA demo;
-- id 1: solo wallet for the lost-update demo.
-- ids 2 and 3: two wallets of one customer ("joint") for the write-skew demo.
-- Business rule (cross-row, so no CHECK can enforce it): the TOTAL of the joint
-- wallets must never go below zero.
CREATE TABLE demo.wallets (
    id int PRIMARY KEY,
    owner text NOT NULL,
    balance bigint NOT NULL
);
INSERT INTO demo.wallets
VALUES (1, 'solo', 1000),
    (2, 'joint', 100),
    (3, 'joint', 100);
-- Two plain rows for the deadlock demo.
CREATE TABLE demo.locks (id int PRIMARY KEY, n int NOT NULL DEFAULT 0);
INSERT INTO demo.locks
VALUES (1, 0),
    (2, 0);
-- Real ledger accounts for demo 4 (idempotency race). They persist: ledger rows are
-- immutable, which is the point. ON CONFLICT makes re-running harmless.
INSERT INTO ledger.accounts (
        id,
        owner_ref,
        name,
        type,
        currency,
        allow_negative
    )
VALUES (
        '00000000-0000-0000-0000-0000000000d1',
        NULL,
        'demo cash',
        'asset',
        'USD',
        true
    ),
    (
        '00000000-0000-0000-0000-0000000000d2',
        'demo',
        'demo wallet',
        'liability',
        'USD',
        false
    ) ON CONFLICT (id) DO NOTHING;