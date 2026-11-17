// Runs every db/tests/*.sql file in order, stopping at the first failure.
// Reads the connection URL from .env, so psql never asks for a password.
// Node 24 loads .env natively with process.loadEnvFile (no dotenv package needed).
import { readdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';

process.loadEnvFile('.env');
// TEST_DATABASE_URL lets us point the tests at another database; defaults to the admin URL.
const url = process.env.TEST_DATABASE_URL ?? process.env.DATABASE_URL_ADMIN;
if (!url) {
  console.error('Set DATABASE_URL_ADMIN (or TEST_DATABASE_URL) in .env');
  process.exit(1);
}

const files = readdirSync('db/tests').filter((f) => f.endsWith('.sql')).sort();
for (const file of files) {
  console.log(`\n=== ${file} ===`);
  const result = spawnSync(
    'psql',
    [url, '-q', '-v', 'ON_ERROR_STOP=1', '-P', 'pager=off', '-f', `db/tests/${file}`],
    // stdout (the "(1 row)" tables) is hidden; stderr carries the NOTICE lines and errors.
    { stdio: ['inherit', 'ignore', 'inherit'] },
  );
  if (result.status !== 0) {
    console.error(`\nFAILED: ${file}`);
    process.exit(1);
  }
}
console.log('\nAll database test files passed.');