// SQL test runner. Run with: pnpm test:db
//
// 1. Starts a throwaway container from the local Supabase Postgres image,
//    named palaro-dbtest-<random>, published on a random free localhost port.
// 2. Applies scripts/test-db/bootstrap.sql as supabase_admin (the bits of the
//    auth schema that hosted GoTrue owns, plus pgTAP).
// 3. Applies supabase/migrations/*.sql in file name order as postgres, each in
//    its own transaction (as the Supabase CLI does). Before a migration V,
//    supabase/tests/premigrate/V (if present) runs the same way, so tests can
//    seed the data a migration has to carry forward.
// 4. Applies supabase/tests/setup/*.sql (shared fixture helpers).
// 5. Runs every supabase/tests/*.test.sql through psql and fails on any
//    `not ok`, a plan mismatch, or any SQL error.
// The container is always removed, whatever happens. No other container is
// ever touched: every docker command names this run's container explicitly.
import { spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { existsSync, readdirSync, readFileSync, realpathSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const IMAGE = 'public.ecr.aws/supabase/postgres:17.11.0.004';
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const MIGRATIONS = join(ROOT, 'supabase', 'migrations');
const TESTS = join(ROOT, 'supabase', 'tests');
const SETUP = join(TESTS, 'setup');
const PREMIGRATE = join(TESTS, 'premigrate');
const BOOTSTRAP = join(ROOT, 'scripts', 'test-db', 'bootstrap.sql');

// Parses psql's TAP output for one test file.
export function evaluateTap(output) {
  const failures = [];
  let planned = null;
  let ran = 0;
  for (const raw of output.split('\n')) {
    const line = raw.trim();
    const plan = /^1\.\.(\d+)$/.exec(line);
    if (plan) planned = Number(plan[1]);
    else if (/^ok \d+/.test(line)) ran++;
    else if (/^not ok \d+/.test(line)) {
      ran++;
      failures.push(line);
    }
  }
  if (planned === null) failures.push('no plan line (call plan(n) and finish())');
  else if (planned !== ran) failures.push(`planned ${planned} but ran ${ran}`);
  if (ran === 0) failures.push('no tests ran');
  return { ok: failures.length === 0, planned, ran, failures };
}

export function migrationFiles(dir) {
  return readdirSync(dir)
    .filter((f) => f.endsWith('.sql') && statSync(join(dir, f)).isFile())
    .sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
}

// Seed file to run just before migration `name`, or null.
export function premigrateSeed(dir, name) {
  const path = join(dir, name);
  return existsSync(path) && statSync(path).isFile() ? path : null;
}

function docker(args, opts = {}) {
  return spawnSync('docker', args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, ...opts });
}

function main() {
  const name = `palaro-dbtest-${randomBytes(6).toString('hex')}`;
  const password = randomBytes(16).toString('hex');
  let removed = false;
  const cleanup = () => {
    if (removed) return;
    removed = true;
    docker(['rm', '-f', '-v', name]);
  };
  process.on('exit', cleanup);
  for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
    process.on(sig, () => {
      cleanup();
      process.exit(130);
    });
  }

  const psql = (user, sql, extra = []) =>
    docker(
      [
        'exec', '-i', '-e', `PGPASSWORD=${password}`, name,
        'psql', '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-h', '127.0.0.1', '-U', user, '-d', 'postgres',
        ...extra,
      ],
      { input: sql },
    );
  const applyOrDie = (label, user, sql, extra) => {
    const r = psql(user, sql, extra);
    if (r.status !== 0) {
      console.error(`FAILED applying ${label}\n${r.stdout}${r.stderr}`);
      process.exit(1);
    }
  };

  try {
    const run = docker([
      'run', '-d', '--pull', 'never', '--name', name,
      '-e', `POSTGRES_PASSWORD=${password}`,
      '-p', '127.0.0.1::5432',
      IMAGE,
    ]);
    if (run.status !== 0) {
      console.error(`Could not start ${IMAGE} (is it pulled locally?)\n${run.stderr}`);
      process.exit(1);
    }
    const port = docker(['port', name, '5432/tcp']).stdout.trim();
    console.log(`# container ${name} on ${port}`);

    // TCP only answers once the image's init scripts are done: the init phase
    // server listens on the unix socket only.
    const deadline = Date.now() + 120_000;
    for (;;) {
      if (psql('postgres', 'select 1', ['-Atc', 'select 1']).status === 0) break;
      if (Date.now() > deadline) {
        console.error(`database never became ready\n${docker(['logs', '--tail', '50', name]).stderr}`);
        process.exit(1);
      }
      spawnSync('sleep', ['1']);
    }

    applyOrDie('bootstrap.sql', 'supabase_admin', readFileSync(BOOTSTRAP, 'utf8'));
    const migrations = migrationFiles(MIGRATIONS);
    for (const f of migrations) {
      const seed = premigrateSeed(PREMIGRATE, f);
      if (seed) applyOrDie(`premigrate/${f}`, 'postgres', readFileSync(seed, 'utf8'), ['--single-transaction']);
      applyOrDie(f, 'postgres', readFileSync(join(MIGRATIONS, f), 'utf8'), ['--single-transaction']);
    }
    console.log(`# applied ${migrations.length} migrations`);
    for (const f of migrationFiles(SETUP)) {
      applyOrDie(`setup/${f}`, 'postgres', readFileSync(join(SETUP, f), 'utf8'), ['--single-transaction']);
    }

    const files = readdirSync(TESTS).filter((f) => f.endsWith('.test.sql')).sort();
    if (files.length === 0) {
      console.error('no supabase/tests/*.test.sql files found');
      process.exit(1);
    }
    let failed = 0;
    let total = 0;
    for (const f of files) {
      const r = psql('postgres', readFileSync(join(TESTS, f), 'utf8'), ['-t', '-A']);
      const out = `${r.stdout}${r.stderr}`;
      const verdict = evaluateTap(r.stdout);
      total += verdict.ran;
      const ok = r.status === 0 && verdict.ok;
      console.log(`\n# ${f}`);
      process.stdout.write(out.endsWith('\n') ? out : `${out}\n`);
      if (!ok) {
        failed++;
        const why = r.status !== 0 ? [`psql exited ${r.status} (SQL error)`] : [];
        console.log(`# FAIL ${f}: ${[...why, ...verdict.failures].join('; ')}`);
      }
    }
    console.log(`\n# ${files.length - failed}/${files.length} files passed, ${total} assertions`);
    process.exitCode = failed ? 1 : 0;
  } finally {
    cleanup();
  }
}

// Resolve symlinks on both sides: import.meta.url is the real path, argv[1] is not.
const isMain = Boolean(process.argv[1]) && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url));
if (isMain) main();
