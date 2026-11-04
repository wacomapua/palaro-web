// Two sessions against the pnpm test:db container (scripts/test-db.mjs runs
// this file and passes the container name and password).
//
// Reserve auto promotion under concurrency (C7):
//   A. Two seats released at once: the event lock makes the second release
//      wait; each promotes a different reserve, in join order.
//   B. The reserve who joined first is locked by its owner: the release waits
//      for it instead of skipping to the next reserve (no SKIP LOCKED).
//   C. A reserve joins while another session's open transaction claimed a
//      seat (its foreign key check holds FOR KEY SHARE on the event): no
//      deadlock, because the event lock is FOR NO KEY UPDATE. With FOR UPDATE
//      two such sessions each wait for the other's key share lock.
//   D. A promotion races a direct claim of the same free seat: it waits for
//      the claim, then takes the next free seat instead of failing the join.
import { spawn, spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';

const container = process.env.PALARO_DBTEST_CONTAINER;
const password = process.env.PALARO_DBTEST_PASSWORD;
if (!container || !password) {
  console.error('run through pnpm test:db');
  process.exit(2);
}

const tag = randomBytes(4).toString('hex');
const psqlArgs = (app) => [
  'exec', '-i', '-e', `PGPASSWORD=${password}`, '-e', `PGAPPNAME=${app}`, container,
  'psql', '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', '-h', '127.0.0.1', '-U', 'postgres', '-d', 'postgres',
];
const sql = (text) => spawnSync('docker', psqlArgs(`promo_${tag}`), { input: text, encoding: 'utf8' });
const value = (text) => sql(text).stdout.trim();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// A psql session fed statement by statement.
function session(name) {
  const app = `promo_${tag}_${name}`;
  const p = spawn('docker', psqlArgs(app), { stdio: ['pipe', 'pipe', 'pipe'] });
  const s = { app, out: '', status: null };
  p.stdout.on('data', (d) => (s.out += d));
  p.stderr.on('data', (d) => (s.out += d));
  // psql stops at the first error (ON_ERROR_STOP); later writes then hit a
  // closed pipe, which the checks report instead of crashing the run.
  p.stdin.on('error', () => {});
  s.done = new Promise((r) => p.on('exit', (code) => r((s.status = code))));
  s.send = (text) => p.stdin.write(`${text}\n`);
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
// The session finished its statement (and renamed itself) or blocks on a lock.
const settled = (app) =>
  until(`(application_name = '${app}' and wait_event_type = 'Lock') or (application_name = '${app}_done' and state = 'idle')`);

const results = [];
const check = (ok, name, detail = '') => results.push({ ok, name, detail });
const rows = (query) => value(query).split('\n').filter(Boolean).join(' ');

// Committed fixture: four events of one team; other sessions only see
// committed rows.
const setup = sql(`
  select tests.create_user() as captain \\gset
  select tests.create_team(:'captain') as team \\gset
  create temp table u as select n, tests.create_user() as id from generate_series(2, 6) n;
  select tests.add_member(:'team', id) from u;
  select id as u2 from u where n = 2 \\gset
  select id as u3 from u where n = 3 \\gset
  select id as u4 from u where n = 4 \\gset
  select id as u5 from u where n = 5 \\gset
  select id as u6 from u where n = 6 \\gset
  select tests.create_event(:'team', 2) as ea \\gset
  select tests.create_event(:'team', 1) as eb \\gset
  select tests.create_event(:'team', 3) as ec \\gset
  select tests.create_event(:'team', 3) as ed \\gset
  select tests.create_event_slot(:'ea', :'u2', 'confirmed', 1, 'paid') as a1 \\gset
  select tests.create_event_slot(:'ea', :'u3', 'confirmed', 2, 'paid') as a2 \\gset
  select tests.create_event_slot(:'ea', :'u4', 'reserve', 2, 'reserved', now() - interval '30 minutes') as ra1 \\gset
  select tests.create_event_slot(:'ea', :'u5', 'reserve', 1, 'paid', now() - interval '20 minutes') as ra2 \\gset
  select tests.create_event_slot(:'ea', :'u6', 'reserve', 3, 'reserved', now() - interval '10 minutes') as ra3 \\gset
  select tests.create_event_slot(:'eb', :'u2', 'confirmed', 1, 'paid') as b1 \\gset
  select tests.create_event_slot(:'eb', :'u3', 'reserve', 2, 'reserved', now() - interval '30 minutes') as rb1 \\gset
  select tests.create_event_slot(:'eb', :'u4', 'reserve', 1, 'reserved', now() - interval '10 minutes') as rb2 \\gset
  select tests.create_event_slot(:'ec', :'captain', 'confirmed', 1, 'paid') \\gset
  select tests.create_event_slot(:'ed', :'captain', 'confirmed', 1, 'paid') \\gset
  select concat_ws('|', :'captain', :'team', :'u2', :'u3', :'u4', :'u5', :'u6', :'ea', :'eb', :'ec', :'ed',
                   :'a1', :'a2', :'ra1', :'ra2', :'ra3', :'b1', :'rb1', :'rb2');
`);
if (setup.status !== 0) {
  console.error(`setup failed\n${setup.stdout}${setup.stderr}`);
  process.exit(1);
}
const parts = setup.stdout.trim().split('\n').pop().split('|');
const [captain, team, u2, u3, u4, u5, u6, ea, eb, ec, ed, a1, a2, ra1, ra2, ra3, b1, rb1, rb2] = parts;
const users = [captain, u2, u3, u4, u5, u6];

const release = (id) => `update public.event_slots set status = 'released' where id = '${id}';`;
const claim = (event, user, type, pos) =>
  `insert into public.event_slots (event_id, user_id, slot_type, position) values ('${event}', '${user}', '${type}', ${pos});`;

// ---- A. two releases at once ---------------------------------------------
{
  const s1 = session('a1');
  s1.send(`begin; ${release(a1)} set application_name = '${s1.app}_held';`);
  const held = await idleInTx(`${s1.app}_held`);
  check(held, 'A: session 1 holds a release open', held ? '' : s1.out);
  const s2 = session('a2');
  s2.send(release(a2));
  const waited = held && (await waitingOnLock(s2.app));
  check(waited, 'A: the second release waits for the first (event lock)', waited ? '' : s2.out);
  await s1.end('commit;');
  const s2Status = await s2.end();
  check(s2Status === 0, 'A: then completes without error', s2.out);
  const got = rows(`select concat_ws(':', id, slot_type, position) from public.event_slots where event_id = '${ea}' order by created_at`);
  const want = [`${ra1}:confirmed:1`, `${ra2}:confirmed:2`, `${ra3}:reserve:3`].join(' ');
  check(got === want, 'A: the two earliest reserves take seats 1 and 2 in join order; the third waits', `got ${got}`);
}

// ---- B. the first reserve is locked by its owner --------------------------
{
  const s1 = session('b1');
  s1.send(`begin; update public.event_slots set paid_at = now() where id = '${rb1}'; set application_name = '${s1.app}_held';`);
  const held = await idleInTx(`${s1.app}_held`);
  const s2 = session('b2');
  s2.send(release(b1));
  const waited = held && (await waitingOnLock(s2.app));
  check(waited, 'B: the release waits for the locked first reserve instead of skipping it', waited ? '' : `${s1.out}${s2.out}`);
  await s1.end('commit;');
  const s2Status = await s2.end();
  check(s2Status === 0, 'B: then completes', s2.out);
  const got = rows(`select concat_ws(':', id, slot_type, position) from public.event_slots where event_id = '${eb}' order by created_at`);
  const want = [`${rb1}:confirmed:1`, `${rb2}:reserve:1`].join(' ');
  check(got === want, 'B: the reserve who joined first is promoted; the later one waits', `got ${got}`);
}

// ---- C. key share lock held by an open seat claim --------------------------
{
  const s2 = session('c2');
  s2.send(`begin; ${claim(ec, u2, 'confirmed', 3)} set application_name = '${s2.app}_held';`);
  const held = await idleInTx(`${s2.app}_held`);
  check(held, 'C: session 2 holds an uncommitted claim of seat 3', held ? '' : s2.out);
  const s1 = session('c1');
  s1.send(`${claim(ec, u3, 'reserve', 1)} set application_name = '${s1.app}_done';`);
  // Let session 1 either finish or block before session 2 goes on.
  await settled(s1.app);
  s2.send(`set lock_timeout = '5s'; ${claim(ec, u4, 'reserve', 2)}`);
  const s1Status = await s1.end();
  const s2Status = await s2.end('commit;');
  check(s1Status === 0 && s2Status === 0, 'C: both reserves join, no deadlock', `${s1.out}${s2.out}`);
  const got = rows(`select concat_ws(':', user_id, slot_type, position) from public.event_slots where event_id = '${ec}' order by slot_type, position`);
  const want = [`${captain}:confirmed:1`, `${u3}:confirmed:2`, `${u2}:confirmed:3`, `${u4}:reserve:2`].join(' ');
  check(got === want, 'C: the first reserve took the free seat 2; the second waits', `got ${got}`);
}

// ---- D. promotion races a direct claim of the same seat --------------------
{
  const s2 = session('d2');
  s2.send(`begin; ${claim(ed, u2, 'confirmed', 2)} set application_name = '${s2.app}_held';`);
  const held = await idleInTx(`${s2.app}_held`);
  const s1 = session('d1');
  s1.send(claim(ed, u3, 'reserve', 1));
  const waited = held && (await waitingOnLock(s1.app));
  check(waited, 'D: the promotion into seat 2 waits for the uncommitted claim of seat 2', waited ? '' : `${s1.out}${s2.out}`);
  await s2.end('commit;');
  const s1Status = await s1.end();
  check(s1Status === 0, 'D: the reserve still joins', s1.out);
  const got = rows(`select concat_ws(':', user_id, slot_type, position) from public.event_slots where event_id = '${ed}' order by slot_type, position`);
  const want = [`${captain}:confirmed:1`, `${u2}:confirmed:2`, `${u3}:confirmed:3`].join(' ');
  check(got === want, 'D: and is promoted into the next free seat, 3', `got ${got}`);
}

const cleanup = sql(`delete from public.teams where id = '${team}';
  delete from auth.users where id in (${users.map((u) => `'${u}'`).join(', ')});`);
check(cleanup.status === 0, 'committed fixture removed', cleanup.stderr);

console.log(`1..${results.length}`);
results.forEach((r, i) => {
  console.log(`${r.ok ? 'ok' : 'not ok'} ${i + 1} - ${r.name}`);
  if (!r.ok && r.detail) for (const line of r.detail.trim().split('\n')) console.log(`# ${line}`);
});
