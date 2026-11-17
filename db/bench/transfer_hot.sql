\
set a random(1, 10) \
set off random(1, 9) \
set b ((:a - 1 + :off) % 10) + 1
SELECT ledger.transfer(
        (
            SELECT id
            FROM public.bench_accounts
            WHERE n = :a
        ),
        (
            SELECT id
            FROM public.bench_accounts
            WHERE n = :b
        ),
        100,
        'USD',
        CAST(gen_random_uuid() AS text),
        'pgbench'
    );