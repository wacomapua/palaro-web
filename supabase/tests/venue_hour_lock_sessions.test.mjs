// Two sessions against the pnpm test:db container (scripts/test-db.mjs runs
// this file and passes the container name and password).
//
// reinstate_venue_booking takes book_venue_slot's venue-hour advisory lock
// (PR #11 review, finding 3). A court and its sub court overlap, but a
// booking on one does not lock the other's slot row: only the venue-hour
// lock orders book_venue_slot on the parent court with a late payment
// reinstated on the child court at the same hour.
//   A: book_venue_slot holds the parent court's slot (not yet committed).
//   B: a late payment on a child court booking at the same hour is
//      reinstated. It must wait for A, then see the parent's hold and
//      return NULL (payments-webhook refunds it).
//   Then A's booking is paid (complete_venue_booking).
// Without the lock B sees the parent still available, reinstates the
// child, and the court tree ends up with two paid bookings at once.
import { connect } from './sessions.mjs';

const { sql, rows, value, session, idleInTx, settled, check, report } = connect('vhlock');

// Committed fixture: a parent court with one sub court, a slot on each at
// the same hour, and a child court booking cancelled before its payment.
const setup = sql(`
  select tests.create_user() as owner \\gset
  select tests.create_user() as captain \\gset
  select tests.create_venue(:'owner') as venue \\gset
  select tests.create_court(:'venue', 'Full Pitch') as parent \\gset
  select tests.create_court(:'venue', 'Half Pitch A', :'parent') as child \\gset
  select date_trunc('hour', now()) + interval '3 days' as t0 \\gset
  select tests.create_slot(:'venue', :'parent', :'t0', :'t0'::timestamptz + interval '1 hour', 200000) as sp \\gset
  select tests.create_slot(:'venue', :'child', :'t0', :'t0'::timestamptz + interval '1 hour', 100000) as sc \\gset
  select tests.create_booking(:'sc', :'captain', 'cancelled', 1, 100000, 'pi_vh_child_' || :'venue') as bc \\gset
  select concat_ws('|', :'owner', :'captain', :'venue', :'parent', :'child', :'sp', :'sc', :'bc');
`);
if (setup.status !== 0) {
  console.error(`setup failed\n${setup.stdout}${setup.stderr}`);
  process.exit(1);
}
const [owner, captain, venue, parent, child, sp, sc, bc] = setup.stdout.trim().split('\n').pop().split('|');
const childIntent = `pi_vh_child_${venue}`;
const parentIntent = `pi_vh_parent_${venue}`;

{
  // payments-create-intent: book_venue_slot, then the intent id on the booking.
  const a = session('book');
  a.send(`begin;
    select booking_id as bp from public.book_venue_slot('${sp}', '${captain}', null) \\gset
    update public.venue_bookings set paymongo_intent_id = '${parentIntent}' where id = :'bp' returning id;
    set application_name = '${a.app}_held';`);
  const held = await idleInTx(`${a.app}_held`);
  const bp = held ? await a.output() : '';
  check(/^[0-9a-f-]{36}$/.test(bp), 'A: book_venue_slot holds the parent court slot (not yet committed)', a.out);

  // payments-webhook: a late payment on the child court booking.
  const b = session('reinstate');
  b.send(`select coalesce(r.id::text, 'null') from public.reinstate_venue_booking('${childIntent}') r;
    set application_name = '${b.app}_done';`);
  await settled(b.app);
  const waiting = value(`select count(*) from pg_stat_activity where application_name = '${b.app}' and wait_event_type = 'Lock'`);
  check(waiting === '1', "B: the child court reinstatement waits for A's venue-hour lock", b.out);

  await a.end('commit;');
  const bStatus = await b.end();
  check(bStatus === 0 && (await b.output()) === 'null', 'B: then returns NULL: the parent court is held at that hour', b.out);

  const done = sql(`select status from public.complete_venue_booking('${parentIntent}');`);
  check(done.status === 0 && done.stdout.trim() === 'paid', "A's booking is paid", done.stdout + done.stderr);

  const paid = rows(`select count(*) from public.venue_bookings b
                       join public.venue_slots s on s.id = b.slot_id
                      where s.id in ('${sp}', '${sc}') and b.status in ('paid', 'completed')`);
  check(paid === '1', 'the court tree has one paid booking at that hour, not two', `got ${paid}`);
  const got = rows(`select concat_ws(':',
      (select status from public.venue_bookings where id = '${bc}'),
      (select status from public.venue_slots where id = '${sc}'),
      (select status from public.venue_slots where id = '${sp}'))`);
  check(got === 'cancelled:available:booked', 'the child booking stays cancelled (refunded), the parent slot is booked', `got ${got}`);
}

const cleanup = sql(`
  delete from public.transactions where gateway_ref in ('${childIntent}', '${parentIntent}');
  delete from public.venue_bookings where slot_id in ('${sp}', '${sc}');
  delete from public.venue_slots where id in ('${sp}', '${sc}');
  delete from public.venue_courts where id in ('${child}', '${parent}');
  delete from public.venues where id = '${venue}';
  delete from auth.users where id in ('${owner}', '${captain}');`);
check(cleanup.status === 0, 'committed fixture removed', cleanup.stdout + cleanup.stderr);

report();
