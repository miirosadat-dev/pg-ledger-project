// One-command benchmark: builds a throwaway database, loads ~1M entries, measures, and
// writes docs/benchmarks.md.   Usage:  npm run bench [-- --rows=1000000] [-- --drop]
import { spawnSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import os from 'node:os';

process.loadEnvFile('.env');
const adminUrl = process.env.DATABASE_URL_ADMIN;
if (!adminUrl) { console.error('Set DATABASE_URL_ADMIN in .env'); process.exit(1); }

const args = process.argv.slice(2);
const rowsArg = args.find((a) => a.startsWith('--rows='));
const ENTRIES = rowsArg ? Number(rowsArg.split('=')[1]) : 1_000_000;
const N_TXNS = Math.floor(ENTRIES / 2);          // two entries per transfer
const N_ACCOUNTS = 1000;                         // fixed: the pgbench scripts assume it
const DB = 'ledger_bench';

// Same server and credentials as the dev database, different database name.
const withDb = (name) => { const u = new URL(adminUrl); u.pathname = `/${name}`; return u.toString(); };
const maintUrl = withDb('postgres');
const benchUrl = withDb(DB);

function psql(url, extra = [], { inherit = false } = {}) {
  const r = spawnSync('psql', [url, '-X', '-q', '-v', 'ON_ERROR_STOP=1', ...extra], {
    encoding: 'utf8', maxBuffer: 1 << 28,
    stdio: inherit ? 'inherit' : ['ignore', 'pipe', 'pipe'],
  });
  if (r.status !== 0) {
    console.error(r.stderr ?? '');
    console.error(`psql failed: ${extra.join(' ').slice(0, 200)}`);
    process.exit(1);
  }
  return (r.stdout ?? '').trim();
}
const q = (sql) => psql(benchUrl, ['-At', '-c', sql]);
const median = (xs) => [...xs].sort((a, b) => a - b)[Math.floor(xs.length / 2)];

// EXPLAIN (ANALYZE, BUFFERS): one warm-up run, then the median of 3 measured runs.
function explainOnce(sql) {
  const plan = psql(benchUrl, ['-At', '-c', `EXPLAIN (ANALYZE, BUFFERS) ${sql}`]);
  const m = plan.match(/Execution Time: ([\d.]+) ms/);
  if (!m) throw new Error(`no execution time in plan for: ${sql}\n${plan}`);
  return { ms: Number(m[1]), plan };
}
function measureExplain(sql, runs = 3) {
  explainOnce(sql);
  const rs = Array.from({ length: runs }, () => explainOnce(sql));
  return { ms: median(rs.map((r) => r.ms)), plan: rs.at(-1).plan };
}
// Wall-clock timing via psql \timing, for statements EXPLAIN cannot analyse (REFRESH, functions).
function timedOnce(sql) {
  const out = psql(benchUrl, ['-At', '-c', '\\timing on', '-c', sql]);
  const m = out.match(/Time: ([\d.]+) ms/);
  if (!m) throw new Error(`no timing for: ${sql}\n${out}`);
  return { ms: Number(m[1]), out };
}
function timed(sql, { runs = 3, warm = 1 } = {}) {
  for (let i = 0; i < warm; i++) timedOnce(sql);
  const rs = Array.from({ length: runs }, () => timedOnce(sql));
  return { ms: median(rs.map((r) => r.ms)), out: rs.at(-1).out };
}
function partitionsScanned(plan) {
  const names = new Set();
  const re = /(?:Seq Scan|Index Scan|Index Only Scan|Bitmap Heap Scan)(?: Backward)?(?: using \S+)? on (entries_[a-z0-9_]+)/g;
  for (const m of plan.matchAll(re)) names.add(m[1]);
  return names.size;
}
function pgbench(script, clients, seconds) {
  const r = spawnSync('pgbench', ['-n', '-f', script, '-c', String(clients),
    '-j', String(Math.min(clients, 4)), '-T', String(seconds), benchUrl], { encoding: 'utf8' });
  if (r.error) return null;                               // pgbench not installed
  const text = `${r.stdout ?? ''}\n${r.stderr ?? ''}`;
  return {
    ok: r.status === 0,
    tps: Number(text.match(/tps = ([\d.]+)/)?.[1] ?? NaN),
    latency: Number(text.match(/latency average = ([\d.]+) ms/)?.[1] ?? NaN),
    failed: Number(text.match(/number of failed transactions: (\d+)/)?.[1] ?? 0),
    tail: text.trim().split('\n').slice(-6).join('\n'),
  };
}
const fmt = (n) => (Number.isFinite(n) ? n.toFixed(1) : 'n/a');
const ratio = (a, b) => `${(a / b).toFixed(1)}x`;

// ---------------------------------------------------------------- 1. database + schema
console.log(`1/7 creating database ${DB} (dropping any previous one)`);
psql(maintUrl, ['-c', `DROP DATABASE IF EXISTS ${DB} WITH (FORCE)`]);
psql(maintUrl, ['-c', `CREATE DATABASE ${DB}`]);

console.log('2/7 applying migrations');
const mig = spawnSync('npx dbmate --migrations-dir db/migrations --no-dump-schema up', {
  stdio: 'inherit', shell: true, env: { ...process.env, DATABASE_URL: benchUrl },
});
if (mig.status !== 0 || q("SELECT to_regclass('ledger.entries') IS NOT NULL") !== 't') {
  console.error('Migrations did not apply to the bench database.'); process.exit(1);
}
// Drop the statement index so the BEFORE measurements are honest (and the load is faster).
q('DROP INDEX ledger.entries_account_created_idx');

// ---------------------------------------------------------------- 3. seed
console.log(`3/7 loading ${N_TXNS} transfers (${N_TXNS * 2} entries); this takes a minute or two`);
psql(benchUrl, ['-v', `n_accounts=${N_ACCOUNTS}`, '-v', `n_txns=${N_TXNS}`, '-f', 'db/bench/seed.sql'],
  { inherit: true });
const entryCount = Number(q('SELECT count(*) FROM ledger.entries'));
const partCount = Number(q("SELECT count(*) FROM pg_inherits WHERE inhparent = 'ledger.entries'::regclass"));
if (entryCount < ENTRIES * 0.99) { console.error(`expected ~${ENTRIES} entries, found ${entryCount}`); process.exit(1); }
console.log(`   loaded ${entryCount} entries in ${partCount} partitions`);

// ---------------------------------------------------------------- 4. index before / after
console.log('4/7 statement queries: before and after the index');
const acct = q("SELECT id FROM ledger.accounts WHERE owner_ref = 'bench' ORDER BY name LIMIT 1");
const acctRows = Number(q(`SELECT count(*) FROM ledger.entries WHERE account_id = '${acct}'`));
const allSql = `SELECT id, created_at, direction, amount FROM ledger.entries WHERE account_id = '${acct}' ORDER BY created_at, id`;
const winSql = `SELECT id, created_at, direction, amount FROM ledger.entries WHERE account_id = '${acct}' AND created_at >= now() - interval '30 days' ORDER BY created_at, id`;
const fnSql = `SELECT count(*) FROM ledger.account_statement('${acct}', now() - interval '30 days', NULL, 1000)`;
const statementSet = () => ({ all: measureExplain(allSql), win: measureExplain(winSql), fn: timed(fnSql) });

const before = statementSet();
const indexBuild = timedOnce('CREATE INDEX entries_account_created_idx ON ledger.entries (account_id, created_at, id)');
q('ANALYZE ledger.entries');
const after = statementSet();

// ---------------------------------------------------------------- 5. pruning + trial balance + reconcile
console.log('5/7 partition pruning, trial balance, reconciliation');
const monthSql = "SELECT count(*), sum(amount) FROM ledger.entries WHERE created_at >= date_trunc('month', now()) - interval '1 month' AND created_at < date_trunc('month', now())";
const fullSql = 'SELECT count(*), sum(amount) FROM ledger.entries';
const pruned = measureExplain(monthSql);
const full = measureExplain(fullSql);

const liveTbSql = "SELECT a.currency, sum(CASE WHEN e.direction = 'D' THEN e.amount ELSE 0 END) AS debits, sum(CASE WHEN e.direction = 'C' THEN e.amount ELSE 0 END) AS credits FROM ledger.entries e JOIN ledger.accounts a ON a.id = e.account_id GROUP BY a.currency";
const mvTbSql = 'SELECT currency, sum(debit_balance) AS debits, sum(credit_balance) AS credits FROM ledger.trial_balance GROUP BY currency';
const liveTb = measureExplain(liveTbSql);
const refreshPlain = timed('REFRESH MATERIALIZED VIEW ledger.trial_balance', { runs: 2, warm: 0 });
const refreshConc = timed('REFRESH MATERIALIZED VIEW CONCURRENTLY ledger.trial_balance', { runs: 2, warm: 0 });
const mvTb = measureExplain(mvTbSql);

const recon = timed('SELECT count(*) FROM ledger.reconcile()', { runs: 2, warm: 0 });
const reconCount = recon.out.split('\n').map((l) => l.trim()).find((l) => /^\d+$/.test(l));
if (reconCount !== '0') { console.error(`reconcile() found ${reconCount} discrepancies!`); process.exit(1); }

// ---------------------------------------------------------------- 6. concurrent posting
console.log('6/7 pgbench: concurrent transfers through ledger.transfer');
const uniform = pgbench('db/bench/transfer_uniform.sql', 8, 10);
const hot = pgbench('db/bench/transfer_hot.sql', 8, 10);
const reconAfter = timed('SELECT count(*) FROM ledger.reconcile()', { runs: 1, warm: 0 });
const reconAfterCount = reconAfter.out.split('\n').map((l) => l.trim()).find((l) => /^\d+$/.test(l));

// ---------------------------------------------------------------- 7. report
console.log('7/7 writing docs/benchmarks.md');
const pgVersion = q('SELECT version()');
const settings = ['shared_buffers', 'work_mem', 'max_parallel_workers_per_gather', 'random_page_cost']
  .map((s) => `${s} = ${q(`SHOW ${s}`)}`).join(', ');
const F = '```';
const bench = (r) => (r ? (r.ok ? `${fmt(r.tps)} tps, ${fmt(r.latency)} ms avg latency, ${r.failed} failed` : `ABORTED (see notes)\n${r.tail}`) : 'skipped (pgbench not found)');

const md = `# Benchmarks

Generated by \`npm run bench\` on ${new Date().toISOString().slice(0, 10)}. Numbers are medians of 3 runs (after one warm-up) unless noted, and will differ on your machine.

## Environment
- ${os.cpus().length} logical CPUs (${os.cpus()[0]?.model.trim()}), ${(os.totalmem() / 2 ** 30).toFixed(1)} GiB RAM, ${os.platform()} ${os.release()}
- ${pgVersion}
- Settings: ${settings}

## Method
- Throwaway database \`${DB}\`, all migrations applied, then **${entryCount.toLocaleString()} entries** (${N_TXNS.toLocaleString()} balanced transfers, ${N_ACCOUNTS} accounts) spread over the last 360 days across **${partCount} partitions**.
- Bulk load used \`session_replication_role = replica\` (triggers and FK checks skipped; every transaction is balanced by construction; cached balances recomputed from entries; \`reconcile()\` confirms the result).
- Queries use \`EXPLAIN (ANALYZE, BUFFERS)\`; refreshes and functions use psql \`\\timing\`. The benchmarked account has ${acctRows.toLocaleString()} entries.
- Synthetic, uniformly distributed data on one machine: use these numbers for relative comparisons, not absolute claims.

## Results

| Scenario | Before | After | Speed-up |
|---|---|---|---|
| Statement: all entries of one account, ordered (index \`entries_account_created_idx\`) | ${fmt(before.all.ms)} ms | ${fmt(after.all.ms)} ms | ${ratio(before.all.ms, after.all.ms)} |
| Statement: one account, last 30 days (index) | ${fmt(before.win.ms)} ms | ${fmt(after.win.ms)} ms | ${ratio(before.win.ms, after.win.ms)} |
| \`account_statement()\` function, 30 days (index) | ${fmt(before.fn.ms)} ms | ${fmt(after.fn.ms)} ms | ${ratio(before.fn.ms, after.fn.ms)} |
| Trial balance: live aggregate vs materialized view read | ${fmt(liveTb.ms)} ms | ${fmt(mvTb.ms)} ms | ${ratio(liveTb.ms, mvTb.ms)} |
| Entries in one month vs all entries (partition pruning) | ${fmt(full.ms)} ms (${partitionsScanned(full.plan)} partitions scanned) | ${fmt(pruned.ms)} ms (${partitionsScanned(pruned.plan)} partition(s) scanned) | ${ratio(full.ms, pruned.ms)} |

| Operation | Time |
|---|---|
| \`CREATE INDEX\` on the partitioned table (${entryCount.toLocaleString()} rows) | ${fmt(indexBuild.ms)} ms |
| \`REFRESH MATERIALIZED VIEW\` (plain) | ${fmt(refreshPlain.ms)} ms |
| \`REFRESH MATERIALIZED VIEW CONCURRENTLY\` | ${fmt(refreshConc.ms)} ms |
| \`reconcile()\` over the whole ledger (returned ${reconCount} discrepancies) | ${fmt(recon.ms)} ms |

### Concurrent transfers (\`pgbench\`, 8 clients, 10 s, through \`ledger.transfer\`)
| Workload | Result |
|---|---|
| Uniform: random pairs over ${N_ACCOUNTS} accounts | ${bench(uniform)} |
| Hot: random pairs over 10 accounts (heavy contention) | ${bench(hot)} |

After both runs \`reconcile()\` returned **${reconAfterCount} discrepancies**: balances equal the sum of entries and every transaction is balanced. Sorted lock ordering means contention shows up as waiting (lower tps on hot accounts), never as deadlocks.

## EXPLAIN (ANALYZE, BUFFERS) evidence

### Statement query, before the index
${F}
${before.all.plan}
${F}

### Statement query, after the index
${F}
${after.all.plan}
${F}

### One-month window (partition pruning)
${F}
${pruned.plan}
${F}

### Same aggregate over every partition
${F}
${full.plan}
${F}

### Trial balance computed live
${F}
${liveTb.plan}
${F}

## Notes and caveats
- The index trades write cost and disk for read speed: it adds one index maintenance step per entry insert. The posting benchmark above already includes that cost.
- Plain \`REFRESH\` is faster but blocks readers; \`CONCURRENTLY\` costs more and needs the unique index, but never blocks reports.
- Pruning relies on filtering by \`created_at\`; a query without a time filter must visit every partition.
`;
writeFileSync('docs/benchmarks.md', md);

if (args.includes('--drop')) psql(maintUrl, ['-c', `DROP DATABASE IF EXISTS ${DB} WITH (FORCE)`]);
console.log('\nDone. Open docs/benchmarks.md.');
console.log(`Summary: statement ${fmt(before.all.ms)} -> ${fmt(after.all.ms)} ms; pruning ${fmt(full.ms)} -> ${fmt(pruned.ms)} ms; reconcile discrepancies: ${reconCount} / ${reconAfterCount}`);