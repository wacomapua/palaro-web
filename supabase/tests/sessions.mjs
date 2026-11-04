// Helpers for the two session tests (supabase/tests/*.test.mjs) that
// scripts/test-db.mjs runs against its container. Not a test file itself.
import { spawn, spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';

export function connect(prefix) {
  const container = process.env.PALARO_DBTEST_CONTAINER;
  const password = process.env.PALARO_DBTEST_PASSWORD;
  if (!container || !password) {
    console.error('run through pnpm test:db');
    process.exit(2);
  }
  const tag = `${prefix}_${randomBytes(4).toString('hex')}`;
  const psqlArgs = (app) => [
    'exec', '-i', '-e', `PGPASSWORD=${password}`, '-e', `PGAPPNAME=${app}`, container,
    'psql', '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', '-h', '127.0.0.1', '-U', 'postgres', '-d', 'postgres',
  ];
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

  // One shot, synchronous.
  const sql = (text) => spawnSync('docker', psqlArgs(tag), { input: text, encoding: 'utf8' });
  const value = (text) => sql(text).stdout.trim();
  const rows = (text) => value(text).split('\n').filter(Boolean).join(' ');

  // A psql session fed statement by statement; application_name is
  // `${tag}_${name}`.
  function session(name) {
    const app = `${tag}_${name}`;
    const p = spawn('docker', psqlArgs(app), { stdio: ['pipe', 'pipe', 'pipe'] });
    const s = { app, out: '', status: null };
    p.stdout.on('data', (d) => (s.out += d));
    p.stderr.on('data', (d) => (s.out += d));
    // psql stops at the first error (ON_ERROR_STOP); later writes then hit a
    // closed pipe, which the checks report instead of crashing the run.
    p.stdin.on('error', () => {});
    s.done = new Promise((r) => p.on('exit', (code) => r((s.status = code))));
    s.send = (text) => p.stdin.write(`${text}\n`);
    // Output reaches us through docker after pg_stat_activity already shows
    // the statement done, so wait for it (5 s at most).
    s.output = async (ms = 5_000) => {
      for (const deadline = Date.now() + ms; s.out.trim() === '' && Date.now() < deadline; ) await sleep(50);
      return s.out.trim();
    };
    s.end = async (text = '') => {
      p.stdin.end(text ? `${text}\n` : '');
      await Promise.race([s.done, sleep(15_000)]);
      if (s.status === null) p.kill('SIGKILL');
      return s.status;
    };
    return s;
  }

  // Polls pg_stat_activity until exactly one backend matches `where`.
  async function until(where, ms = 10_000) {
    for (const deadline = Date.now() + ms; Date.now() < deadline; ) {
      if (value(`select count(*) from pg_stat_activity where ${where}`) === '1') return true;
      await sleep(50);
    }
    return false;
  }
  const idleInTx = (app) => until(`application_name = '${app}' and state = 'idle in transaction'`);
  const waitingOnLock = (app) => until(`application_name = '${app}' and wait_event_type = 'Lock'`);
  // The session finished its statement (and renamed itself to `${app}_done`)
  // or blocks on a lock.
  const settled = (app) =>
    until(`(application_name = '${app}' and wait_event_type = 'Lock') or (application_name = '${app}_done' and state = 'idle')`);

  const results = [];
  const check = (ok, name, detail = '') => results.push({ ok, name, detail });
  const report = () => {
    console.log(`1..${results.length}`);
    results.forEach((r, i) => {
      console.log(`${r.ok ? 'ok' : 'not ok'} ${i + 1} - ${r.name}`);
      if (!r.ok && r.detail) for (const line of String(r.detail).trim().split('\n')) console.log(`# ${line}`);
    });
  };

  return { tag, sql, value, rows, session, until, idleInTx, waitingOnLock, settled, check, report };
}
