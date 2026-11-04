// Two sessions against the pnpm test:db container (scripts/test-db.mjs runs
// this file and passes the container name and password).
//
// C12 a: two deliveries of one late "paid" webhook. One reinstates the
// cancelled booking while the other, having seen it cancelled, queues the
// late_payment refund. The booking row lock orders them, so exactly one wins:
//   1. reinstate first: the queue waits, then sees the booking paid and
//      returns NULL (nothing queued);
//   2. queue first: the reinstate waits, then sees the refund and returns
//      NULL (the booking stays cancelled and is refunded).
// Either way the intent has exactly one transactions row.
import { connect } from './sessions.mjs';

const { sql, rows, session, idleInTx, waitingOnLock, check, report } = connect('latepay');

// Committed fixture: two exclusive slots with room, each with a booking that
// was cancelled before its payment landed.
const setup = sql(`
  select tests.create_user() as owner \\gset
  select tests.create_user() as captain \\gset
  select tests.create_venue(:'owner') as venue \\gset
  select tests.create_court(:'venue', 'Race Court') as court \\gset
  select tests.create_slot(:'venue', :'court', now() + interval '3 days', now() + interval '3 days 1 hour', 100000) as s1 \\gset
  select tests.create_slot(:'venue', :'court', now() + interval '3 days 2 hours', now() + interval '3 days 3 hours', 100000) as s2 \\gset
  select tests.create_booking(:'s1', :'captain', 'cancelled', 1, 100000, 'pi_race_reinstate_' || :'venue') as b1 \\gset
  select tests.create_booking(:'s2', :'captain', 'cancelled', 1, 100000, 'pi_race_queue_' || :'venue') as b2 \\gset
  select concat_ws('|', :'owner', :'captain', :'venue', :'s1', :'s2', :'b1', :'b2');
`);
if (setup.status !== 0) {
  console.error(`setup failed\n${setup.stdout}${setup.stderr}`);
  process.exit(1);
}
const [owner, captain, venue, s1, s2, b1, b2] = setup.stdout.trim().split('\n').pop().split('|');
const intent1 = `pi_race_reinstate_${venue}`;
const intent2 = `pi_race_queue_${venue}`;

const reinstate = (intent) =>
  `select coalesce(r.id::text, 'null') from public.reinstate_venue_booking('${intent}') r;`;
const queue = (booking) =>
  `select coalesce(public.queue_venue_refund('${booking}', 100000, 'late_payment')::text, 'null');`;
const state = (booking, intent) =>
  rows(`select concat_ws(':',
          (select status from public.venue_bookings where id = '${booking}'),
          (select count(*) from public.venue_refunds where booking_id = '${booking}'),
          (select count(*) from public.transactions where gateway_ref = '${intent}'))`);

// ---- 1. reinstate first, queue second --------------------------------------
{
  const a = session('r1');
  a.send(`begin; set local role service_role; ${reinstate(intent1)} set application_name = '${a.app}_held';`);
  const held = await idleInTx(`${a.app}_held`);
  check(held && (await a.output()) === b1, '1: delivery A reinstates the booking (not yet committed)', a.out);
  const b = session('q1');
  b.send(`set role service_role; ${queue(b1)}`);
  const waited = held && (await waitingOnLock(b.app));
  check(waited, "1: delivery B's late_payment refund waits for the reinstatement", b.out);
  await a.end('commit;');
  const bStatus = await b.end();
  check(bStatus === 0 && (await b.output()) === 'null', '1: then returns NULL: the booking is paid, nothing to refund', b.out);
  const got = state(b1, intent1);
  check(got === 'paid:0:1', '1: booking paid, no refund queued, one transactions row', `got ${got}`);
}

// ---- 2. queue first, reinstate second --------------------------------------
{
  const a = session('q2');
  a.send(`begin; set local role service_role; ${queue(b2)} set application_name = '${a.app}_held';`);
  const held = await idleInTx(`${a.app}_held`);
  check(held && /^[0-9a-f-]{36}$/.test(await a.output()), '2: delivery A queues the refund (not yet committed)', a.out);
  const b = session('r2');
  b.send(`set role service_role; ${reinstate(intent2)}`);
  const waited = held && (await waitingOnLock(b.app));
  check(waited, "2: delivery B's reinstatement waits for the refund", b.out);
  await a.end('commit;');
  const bStatus = await b.end();
  check(bStatus === 0 && (await b.output()) === 'null', '2: then returns NULL: the refund stands', b.out);
  const got = state(b2, intent2);
  check(got === 'cancelled:1:1', '2: booking cancelled, one refund, one transactions row (the payment)', `got ${got}`);
}

const cleanup = sql(`
  delete from public.venue_refunds where booking_id in ('${b1}', '${b2}');
  delete from public.transactions where gateway_ref in ('${intent1}', '${intent2}');
  delete from public.venue_bookings where id in ('${b1}', '${b2}');
  delete from public.venue_slots where id in ('${s1}', '${s2}');
  delete from public.venues where id = '${venue}';
  delete from auth.users where id in ('${owner}', '${captain}');`);
check(cleanup.status === 0, 'committed fixture removed', cleanup.stdout + cleanup.stderr);

report();
