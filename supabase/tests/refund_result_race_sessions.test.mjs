// Two sessions against the pnpm test:db container (scripts/test-db.mjs runs
// this file and passes the container name and password).
//
// record_venue_refund_result row locks (PR #11 review, finding 3). Two
// payments-process-refunds runs that poll the same submitted refund can both
// record its success. The function locks the booking, then the refund row,
// before it reads the status, so the second call waits for the first, sees
// 'succeeded' and does nothing:
//   1. a venue booking refund (booking lock, then refund row lock);
//   2. an event slot refund (no booking: the refund row lock alone).
// Either way the refund has exactly one 'venue_refund' transactions row.
// Without the locks both calls read 'submitted' and both write one.
import { connect } from './sessions.mjs';

const { sql, rows, session, idleInTx, settled, check, report } = connect('refres');

// Committed fixture: a cancelled venue booking and an event slot payment,
// each with a refund PayMongo has accepted but not finished.
const setup = sql(`
  select tests.create_user() as owner \\gset
  select tests.create_user() as captain \\gset
  select tests.create_venue(:'owner') as venue \\gset
  select tests.create_court(:'venue', 'Refund Court') as court \\gset
  select tests.create_slot(:'venue', :'court', now() + interval '3 days', now() + interval '3 days 1 hour', 100000) as slot \\gset
  select tests.create_booking(:'slot', :'captain', 'cancelled', 1, 100000, 'pi_rr_booking_' || :'venue') as booking \\gset
  insert into public.venue_refunds (booking_id, amount_cents, reason, status, attempts, paymongo_refund_id)
  values (:'booking', 100000, 'late_payment', 'submitted', 1, 'ref_rr_booking')
  returning id as r1 \\gset
  insert into public.venue_refunds (kind, paymongo_intent_id, user_id, amount_cents, reason, status, attempts, paymongo_refund_id)
  values ('event_slot', 'pi_rr_slot_' || :'venue', :'captain', 20000, 'late_payment', 'submitted', 1, 'ref_rr_slot')
  returning id as r2 \\gset
  select concat_ws('|', :'owner', :'captain', :'venue', :'court', :'slot', :'booking', :'r1', :'r2');
`);
if (setup.status !== 0) {
  console.error(`setup failed\n${setup.stdout}${setup.stderr}`);
  process.exit(1);
}
const [owner, captain, venue, court, slot, booking, r1, r2] = setup.stdout.trim().split('\n').pop().split('|');

const succeed = (refund, ref) => `select public.record_venue_refund_result('${refund}', true, '${ref}', null);`;
const refundRows = (refund) =>
  rows(`select count(*) from public.transactions where type = 'venue_refund' and metadata ->> 'refund_id' = '${refund}'`);

async function race(n, refund, ref) {
  const a = session(`a${n}`);
  a.send(`begin; ${succeed(refund, ref)} set application_name = '${a.app}_held';`);
  const held = await idleInTx(`${a.app}_held`);
  check(held, `${n}: run A records the success (not yet committed)`, a.out);
  const b = session(`b${n}`);
  b.send(`${succeed(refund, ref)} set application_name = '${b.app}_done';`);
  await settled(b.app);
  await a.end('commit;');
  const bStatus = await b.end();
  check(bStatus === 0, `${n}: run B records the same success without error`, b.out);
  const got = `${rows(`select status from public.venue_refunds where id = '${refund}'`)}:${refundRows(refund)}`;
  check(got === 'succeeded:1', `${n}: the refund is succeeded with exactly one venue_refund transactions row`, `got ${got}`);
}

// ---- 1. venue booking refund ------------------------------------------------
await race(1, r1, 'ref_rr_booking');
const amount = rows(`select refund_amount_cents from public.venue_bookings where id = '${booking}'`);
check(amount === '100000', '1: the booking records the refund once', `got ${amount}`);

// ---- 2. event slot refund ---------------------------------------------------
await race(2, r2, 'ref_rr_slot');

const cleanup = sql(`
  delete from public.transactions where type = 'venue_refund' and metadata ->> 'refund_id' in ('${r1}', '${r2}');
  delete from public.venue_refunds where id in ('${r1}', '${r2}');
  delete from public.venue_bookings where id = '${booking}';
  delete from public.venue_slots where id = '${slot}';
  delete from public.venue_courts where id = '${court}';
  delete from public.venues where id = '${venue}';
  delete from auth.users where id in ('${owner}', '${captain}');`);
check(cleanup.status === 0, 'committed fixture removed', cleanup.stdout + cleanup.stderr);

report();
