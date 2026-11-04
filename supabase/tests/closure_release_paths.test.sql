-- Every path that frees a slot leaves it 'closed' instead of 'available' when
-- a closure overlaps it (its court, the court tree, or the whole venue), and
-- behaves exactly as before when none does (C3, P2).
begin;
select plan(17);

select tests.create_user() as owner \gset
select tests.create_user() as player \gset
select tests.create_venue(:'owner') as venue \gset
select tests.create_court(:'venue', 'Full Pitch') as pitch \gset
select tests.create_court(:'venue', 'North Half', :'pitch') as north \gset
select tests.create_court(:'venue', 'Q1', :'north') as q1 \gset
select tests.create_court(:'venue', 'South Half', :'pitch') as south \gset
select tests.create_court(:'venue', 'Course', null, 'golf', 'shared') as course \gset
select tests.create_court(:'venue', 'Court B') as court_b \gset
select date_trunc('day', now()) + interval '3 days' as d \gset

-- Legacy closures: written directly, slots under them left as they were.
insert into public.venue_closures (venue_id, court_id, starts_at, ends_at) values
  (:'venue', :'pitch', :'d'::timestamptz + interval '10 hours', :'d'::timestamptz + interval '11 hours'),
  (:'venue', :'q1', :'d'::timestamptz + interval '12 hours', :'d'::timestamptz + interval '13 hours'),
  (:'venue', null, :'d'::timestamptz + interval '14 hours', :'d'::timestamptz + interval '15 hours');

-- 1. cancel_venue_booking by the captain, slot on a child of the closed court.
select tests.create_slot(:'venue', :'q1', :'d'::timestamptz + interval '10 hours', :'d'::timestamptz + interval '11 hours', 100000, null, 'booked') as s_cancel \gset
select tests.create_booking(:'s_cancel', :'player', 'paid') as b_cancel \gset
set local role authenticated;
select tests.claims(:'player');
select * from public.cancel_venue_booking(:'b_cancel', 'changed plans') \gset
reset role;
select is((select status::text from public.venue_slots where id = :'s_cancel'), 'closed',
  'cancel_venue_booking: slot under a parent court closure stays closed');

-- 2. release_held_booking_admin (payments-create-intent rollback), slot on the
--    parent of the closed court.
select tests.create_slot(:'venue', :'north', :'d'::timestamptz + interval '12 hours', :'d'::timestamptz + interval '13 hours', 100000, null, 'held') as s_release \gset
update public.venue_slots set held_until = now() + interval '5 minutes' where id = :'s_release';
select tests.create_booking(:'s_release', :'player', 'pending_payment') as b_release \gset
set local role service_role;
select public.release_held_booking_admin(:'b_release');
reset role;
select is((select status::text from public.venue_slots where id = :'s_release'), 'closed',
  'release_held_booking_admin: slot under a child court closure stays closed');
select is((select status::text from public.venue_bookings where id = :'b_release'), 'cancelled',
  'release_held_booking_admin still cancels the booking');

-- 3. release_stale_shared_bookings, whole venue closure over a full tee time.
select tests.create_slot(:'venue', :'course', :'d'::timestamptz + interval '14 hours', :'d'::timestamptz + interval '14 hours 10 minutes', 50000, 4, 'booked') as s_tee \gset
select tests.create_booking(:'s_tee', :'player', 'pending_payment', 4, 200000) as b_tee \gset
update public.venue_bookings set created_at = now() - interval '30 minutes' where id = :'b_tee';
set local role service_role;
select public.release_stale_shared_bookings(15);
reset role;
select is((select status::text from public.venue_slots where id = :'s_tee'), 'closed',
  'release_stale_shared_bookings: reopened tee time under a venue closure stays closed');
select is((select status::text from public.venue_bookings where id = :'b_tee'), 'cancelled',
  'release_stale_shared_bookings still cancels the stale booking');

-- 4. The release-stale-venue-holds cron statement (0005), verbatim.
select tests.create_slot(:'venue', :'south', :'d'::timestamptz + interval '14 hours', :'d'::timestamptz + interval '15 hours', 100000, null, 'held') as s_cron \gset
update public.venue_slots set held_until = now() - interval '1 minute' where id = :'s_cron';
update public.venue_slots
   set status = 'available', held_until = null
 where status = 'held'
   and held_until is not null
   and held_until < now();
select is((select status::text from public.venue_slots where id = :'s_cron'), 'closed',
  'stale hold cron: expired hold under a closure becomes closed');

-- 5. payments-webhook failure path: service role writes the slot directly.
select tests.create_slot(:'venue', :'pitch', :'d'::timestamptz + interval '10 hours 30 minutes', :'d'::timestamptz + interval '11 hours 30 minutes', 100000, null, 'held') as s_hook \gset
set local role service_role;
update public.venue_slots set status = 'available', held_until = null where id = :'s_hook';
reset role;
select is((select status::text from public.venue_slots where id = :'s_hook'), 'closed',
  'webhook payment failure: direct release under a closure stays closed (partial overlap)');
select is((select held_until from public.venue_slots where id = :'s_hook'), null, 'and the hold is cleared');

-- 6. The owner reopening a slot by hand through RLS.
select tests.create_slot(:'venue', :'q1', :'d'::timestamptz + interval '12 hours', :'d'::timestamptz + interval '13 hours', 100000, null, 'closed') as s_owner \gset
set local role authenticated;
select tests.claims(:'owner');
update public.venue_slots set status = 'available' where id = :'s_owner';
reset role;
select is((select status::text from public.venue_slots where id = :'s_owner'), 'closed',
  'owner cannot reopen a slot that a closure still covers');

-- 7. Moving an open slot into a closure window closes it; new slots inside
--    a closure are created closed.
select tests.create_slot(:'venue', :'south', :'d'::timestamptz + interval '16 hours', :'d'::timestamptz + interval '17 hours') as s_move \gset
update public.venue_slots
   set starts_at = :'d'::timestamptz + interval '14 hours 15 minutes', ends_at = :'d'::timestamptz + interval '14 hours 45 minutes'
 where id = :'s_move';
select is((select status::text from public.venue_slots where id = :'s_move'), 'closed',
  'moving an open slot into a closure closes it');
select tests.create_slot(:'venue', :'south', :'d'::timestamptz + interval '14 hours 30 minutes', :'d'::timestamptz + interval '15 hours 30 minutes') as s_new \gset
select is((select status::text from public.venue_slots where id = :'s_new'), 'closed',
  'a slot inserted inside a closure is stored closed');

-- Controls: no closure, nothing changes.
select tests.create_slot(:'venue', :'court_b', :'d'::timestamptz + interval '10 hours', :'d'::timestamptz + interval '11 hours', 100000, null, 'booked') as c_cancel \gset
select tests.create_booking(:'c_cancel', :'player', 'paid') as cb_cancel \gset
set local role authenticated;
select tests.claims(:'player');
select * from public.cancel_venue_booking(:'cb_cancel', null) \gset
reset role;
select is((select status::text from public.venue_slots where id = :'c_cancel'), 'available',
  'control: cancel outside any closure frees the slot (unrelated court, same time)');
select results_eq(
  format('select status::text, refund_amount_cents from public.venue_bookings where id = %L', :'cb_cancel'),
  $$values ('refunded', 100000)$$,
  'cancel_venue_booking can write its refunded status (enum cast) with the 48h full refund tier');

select tests.create_slot(:'venue', :'q1', :'d'::timestamptz + interval '18 hours', :'d'::timestamptz + interval '19 hours', 100000, null, 'held') as c_release \gset
select tests.create_booking(:'c_release', :'player', 'pending_payment') as cb_release \gset
set local role service_role;
select public.release_held_booking_admin(:'cb_release');
reset role;
select is((select status::text from public.venue_slots where id = :'c_release'), 'available',
  'control: release outside any closure frees the slot');

select tests.create_slot(:'venue', :'south', :'d'::timestamptz + interval '11 hours', :'d'::timestamptz + interval '12 hours', 100000, null, 'held') as c_hook \gset
update public.venue_slots set status = 'available', held_until = null where id = :'c_hook';
select is((select status::text from public.venue_slots where id = :'c_hook'), 'available',
  'control: a slot touching a closure boundary is freed');

select tests.create_slot(:'venue', :'south', :'d'::timestamptz + interval '20 hours', :'d'::timestamptz + interval '21 hours') as c_price \gset
update public.venue_slots set price_cents = 1 where id = :'c_price';
select is((select status::text from public.venue_slots where id = :'c_price'), 'available',
  'control: editing an open slot outside closures keeps it open');

-- Only slots being opened are rewritten.
select tests.create_slot(:'venue', :'south', :'d'::timestamptz + interval '14 hours', :'d'::timestamptz + interval '14 hours 5 minutes', 100000, null, 'cancelled') as s_cancelled \gset
select is((select status::text from public.venue_slots where id = :'s_cancelled'), 'cancelled',
  'a cancelled slot is left cancelled');

select * from finish();
rollback;
