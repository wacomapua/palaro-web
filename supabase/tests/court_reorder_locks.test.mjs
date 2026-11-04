// Two sessions against the pnpm test:db container (scripts/test-db.mjs runs
// this file and passes the container name and password).
//
// swap_venue_court_sort_order keeps row locks on every court of the venue
// until its transaction ends. Those locks must not block the foreign key
// checks (FOR KEY SHARE on venue_courts) taken when slots or templates are
// inserted for the venue's courts: generate_venue_slots and
// replace_venue_slot_templates insert across many courts while a reorder
// locks them in id order, so a conflicting lock can deadlock the two. A
// second reorder of the same venue must still wait for the first.
import { spawn, spawnSync } from 'node:child_process';
import { randomBytes } from 'node:crypto';

const container = process.env.PALARO_DBTEST_CONTAINER;
const password = process.env.PALARO_DBTEST_PASSWORD;
if (!container || !password) {
  console.error('run through pnpm test:db');
  process.exit(2);
}

const psqlArgs = (app) => [
  'exec', '-i', '-e', `PGPASSWORD=${password}`, '-e', `PGAPPNAME=${app}`, container,
  'psql', '-X', '-q', '-At', '-v', 'ON_ERROR_STOP=1', '-h', '127.0.0.1', '-U', 'postgres', '-d', 'postgres',
];
const sql = (text, app = 'reorder_locks') => spawnSync('docker', psqlArgs(app), { input: text, encoding: 'utf8' });

const results = [];
const check = (ok, name, detail = '') => results.push({ ok, name, detail });

// Committed fixtures: the other sessions can only see committed rows.
const setup = sql(`
  select tests.create_user() as owner \\gset
  select tests.create_venue(:'owner') as venue \\gset
  select tests.create_court(:'venue', 'Lock A') as c1 \\gset
  select tests.create_court(:'venue', 'Lock B') as c2 \\gset
  select :'owner' || '|' || :'venue' || '|' || :'c1' || '|' || :'c2';
`);
if (setup.status !== 0) {
  console.error(`setup failed\n${setup.stdout}${setup.stderr}`);
  process.exit(1);
}
const [owner, venue, c1, c2] = setup.stdout.trim().split('\n').pop().split('|');

// Session A: a reorder that has run and not yet committed.
const tag = randomBytes(4).toString('hex');
const heldApp = `reorder_a_${tag}_held`;
const a = spawn('docker', psqlArgs(`reorder_a_${tag}`), { stdio: ['pipe', 'pipe', 'pipe'] });
let aOut = '';
let aExited = false;
a.stdout.on('data', (d) => (aOut += d));
a.stderr.on('data', (d) => (aOut += d));
a.on('exit', () => (aExited = true));
a.stdin.write(`begin;
set local role authenticated;
select tests.claims('${owner}');
select public.swap_venue_court_sort_order('${c1}', '${c2}');
set application_name = '${heldApp}';
`);

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let held = false;
for (const deadline = Date.now() + 30_000; Date.now() < deadline && !aExited; ) {
  const r = sql(`select count(*) from pg_stat_activity
                  where application_name = '${heldApp}' and state = 'idle in transaction'`);
  if (r.stdout.trim() === '1') {
    held = true;
    break;
  }
  await sleep(100);
}
check(held, 'session A holds a court reorder open', held ? '' : aOut);

if (held) {
  // Session B: what the slot generator does, one insert per court.
  const slot = sql(`begin;
    set local lock_timeout = '1s';
    select tests.create_slot('${venue}', '${c1}', now() + interval '3 days', now() + interval '3 days 1 hour');
    rollback;`);
  check(slot.status === 0, 'inserting a slot on a court being reordered does not wait for the reorder', slot.stderr);

  // Session B again: what replace_venue_slot_templates writes.
  const template = sql(`begin;
    set local lock_timeout = '1s';
    insert into public.venue_slot_templates (venue_id, court_id, day_of_week, start_time, end_time, price_cents)
    values ('${venue}', '${c2}', 1, '08:00', '09:00', 100000);
    rollback;`);
  check(template.status === 0, 'inserting a template on a court being reordered does not wait for the reorder', template.stderr);

  // Session C: a second reorder of the same venue queues behind A.
  const second = sql(`begin;
    set local lock_timeout = '1s';
    set local role authenticated;
    select tests.claims('${owner}');
    select public.swap_venue_court_sort_order('${c2}', '${c1}');
    rollback;`);
  check(
    second.status !== 0 && /lock timeout/.test(second.stderr),
    'a second reorder of the same venue waits for the first',
    second.status === 0 ? 'it did not wait' : second.stderr,
  );
} else {
  check(false, 'inserting a slot on a court being reordered does not wait for the reorder', 'skipped');
  check(false, 'inserting a template on a court being reordered does not wait for the reorder', 'skipped');
  check(false, 'a second reorder of the same venue waits for the first', 'skipped');
}

a.stdin.end('rollback;\n');
if (!aExited) await Promise.race([new Promise((r) => a.on('exit', r)), sleep(10_000)]);
if (!aExited) a.kill('SIGKILL');

sql(`delete from public.venues where id = '${venue}'; delete from auth.users where id = '${owner}';`);

console.log(`1..${results.length}`);
results.forEach((r, i) => {
  console.log(`${r.ok ? 'ok' : 'not ok'} ${i + 1} - ${r.name}`);
  if (!r.ok && r.detail) for (const line of r.detail.trim().split('\n')) console.log(`# ${line}`);
});
