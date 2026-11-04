-- create_venue_closure (C2): owner only; one transaction inserts the closure,
-- closes every overlapping slot across the court tree (or the whole venue),
-- cancels paid bookings with a 100% refund queued (owner decision 3) and
-- pending ones with none, and returns what it did.
begin;
select plan(41);

select tests.create_user() as owner \gset
select tests.create_user() as player \gset
select tests.create_user() as player2 \gset
select tests.create_user() as stranger \gset
select tests.create_venue(:'owner') as venue \gset
select tests.create_venue(:'stranger') as other_venue \gset
select tests.create_court(:'venue', 'Full Pitch') as pitch \gset
select tests.create_court(:'venue', 'North Half', :'pitch') as north \gset
select tests.create_court(:'venue', 'Q1', :'north') as q1 \gset
select tests.create_court(:'venue', 'South Half', :'pitch') as south \gset
select tests.create_court(:'venue', 'Course', null, 'golf', 'shared') as course \gset
select tests.create_court(:'other_venue', 'Not yours') as foreign_court \gset
select date_trunc('day', now()) + interval '3 days' as d \gset

-- 10:00 to 11:00 on day d: a paid booking on Q1 (with its match event), a held
-- slot on North, an open Pitch slot, and an open sibling on South.
select tests.create_slot(:'venue', :'q1', :'d'::timestamptz + interval '10 hours', :'d'::timestamptz + interval '11 hours', 120000, null, 'booked') as q1_10 \gset
select tests.create_booking(:'q1_10', :'player', 'paid', 1, 120000, 'pi_q1') as b_q1 \gset
insert into public.teams (slug, name, captain_id) values ('t-closure', 'Team', :'player') returning id as team \gset
insert into public.events (team_id, title, starts_at, created_by, venue_booking_id)
values (:'team', 'Match', :'d'::timestamptz + interval '10 hours', :'player', :'b_q1') returning id as ev \gset
update public.venue_bookings set event_id = :'ev', team_id = :'team' where id = :'b_q1';
select tests.create_slot(:'venue', :'north', :'d'::timestamptz + interval '10 hours', :'d'::timestamptz + interval '11 hours', 100000, null, 'held') as north_10 \gset
update public.venue_slots set held_until = now() + interval '5 minutes' where id = :'north_10';
select tests.create_booking(:'north_10', :'player2', 'pending_payment', 1, 100000, 'pi_north') as b_north \gset
select tests.create_slot(:'venue', :'pitch', :'d'::timestamptz + interval '10 hours', :'d'::timestamptz + interval '11 hours') as pitch_10 \gset
select tests.create_slot(:'venue', :'south', :'d'::timestamptz + interval '10 hours', :'d'::timestamptz + interval '11 hours') as south_10 \gset
-- A slot that already ended, inside the window of a closure that started earlier.
select tests.create_slot(:'venue', :'q1', now() - interval '3 hours', now() - interval '2 hours', 90000, null, 'booked') as q1_past \gset
select tests.create_booking(:'q1_past', :'player', 'paid', 1, 90000, 'pi_past') as b_past \gset

-- ---------- authorization ----------
select is(has_function_privilege('anon', 'public.create_venue_closure(uuid, uuid, timestamptz, timestamptz, text)', 'execute'),
  false, 'anon cannot execute create_venue_closure');
select is(has_function_privilege('authenticated', 'public.create_venue_closure(uuid, uuid, timestamptz, timestamptz, text)', 'execute'),
  true, 'authenticated can execute create_venue_closure');

set local role authenticated;
select tests.claims(:'stranger');
select throws_ok(
  format('select * from public.create_venue_closure(%L, null, %L, %L, %L)', :'venue',
    :'d'::timestamptz + interval '9 hours', :'d'::timestamptz + interval '12 hours', 'x'),
  '42501', null, 'a non owner cannot close the venue');

-- Clients cannot write closures directly any more, only remove their own.
select tests.claims(:'owner');
select throws_ok(
  format($$insert into public.venue_closures (venue_id, starts_at, ends_at) values (%L, %L, %L)$$, :'venue',
    :'d'::timestamptz + interval '1 hour', :'d'::timestamptz + interval '2 hours'),
  '42501', null, 'owner cannot insert a closure directly');

-- ---------- validation ----------
select throws_ok(
  format('select * from public.create_venue_closure(%L, null, %L, %L, null)', :'venue',
    :'d'::timestamptz + interval '12 hours', :'d'::timestamptz + interval '12 hours'),
  '22023', null, 'end must be after start');
select throws_ok(
  format('select * from public.create_venue_closure(%L, %L, %L, %L, null)', :'venue', :'foreign_court',
    :'d'::timestamptz + interval '9 hours', :'d'::timestamptz + interval '12 hours'),
  '22023', null, 'court must belong to the venue');
select throws_ok(
  format('select * from public.create_venue_closure(%L, null, %L, %L, null)', :'venue',
    now() - interval '2 days', now() - interval '1 day'),
  '22023', null, 'a closure that already ended is rejected');
select is((select count(*)::int from public.venue_closures where venue_id = :'venue'), 0,
  'rejected calls leave no closure behind');

-- ---------- a court closure covers the court tree ----------
select * from public.create_venue_closure(:'venue', :'north',
  now() - interval '4 hours', :'d'::timestamptz + interval '10 hours 30 minutes', 'Resurfacing') \gset c1_
reset role;

select isnt(:'c1_closure_id'::uuid, null::uuid, 'returns the new closure id');
select is((select reason from public.venue_closures where id = :'c1_closure_id'), 'Resurfacing', 'closure row stored with its reason');
select is((select court_id from public.venue_closures where id = :'c1_closure_id'), :'north'::uuid, 'closure row stored on the chosen court');
select is(:'c1_closed_slot_count'::int, 3, 'closed the North slot, its parent Pitch slot and its child Q1 slot');
select is((select status::text from public.venue_slots where id = :'north_10'), 'closed', 'the closed court''s slot is closed');
select is((select status::text from public.venue_slots where id = :'pitch_10'), 'closed', 'ancestor slot is closed');
select is((select status::text from public.venue_slots where id = :'q1_10'), 'closed', 'descendant slot is closed');
select is((select status::text from public.venue_slots where id = :'south_10'), 'available', 'sibling branch is untouched');
select is((select held_until from public.venue_slots where id = :'north_10'), null, 'the hold is cleared');

select is(:'c1_refunded_booking_ids'::uuid[], array[:'b_q1'::uuid], 'returns the paid booking ids it refunded');
select is((select status::text from public.venue_bookings where id = :'b_q1'), 'cancelled', 'paid booking is cancelled');
select is((select refund_amount_cents from public.venue_bookings where id = :'b_q1'), 120000, 'paid booking records a full refund');
select is((select refund_reason from public.venue_bookings where id = :'b_q1'), 'Venue closure: Resurfacing', 'refund reason names the closure');
select results_eq(
  format($$select amount_cents, reason, status from public.venue_refunds where booking_id = %L$$, :'b_q1'),
  $$values (120000, 'venue_closure', 'pending')$$,
  'a full venue_closure refund is queued for the paid booking');
select is((select status::text from public.events where id = :'ev'), 'cancelled', 'the booking''s match event is cancelled');

select is((select status::text from public.venue_bookings where id = :'b_north'), 'cancelled', 'pending booking is cancelled');
select is((select count(*)::int from public.venue_refunds where booking_id = :'b_north'), 0, 'no refund is queued for an unpaid booking');

select is((select status::text from public.venue_slots where id = :'q1_past'), 'booked', 'a slot that already ended is untouched');
select is((select status::text from public.venue_bookings where id = :'b_past'), 'paid', 'a booking that already played keeps its payment');

-- ---------- whole venue, shared tee times ----------
select tests.create_slot(:'venue', :'course', :'d'::timestamptz + interval '14 hours', :'d'::timestamptz + interval '14 hours 10 minutes', 50000, 4) as tee \gset
select tests.create_booking(:'tee', :'player', 'paid', 2, 100000, 'pi_tee1') as b_tee1 \gset
select tests.create_booking(:'tee', :'player2', 'paid', 1, 50000, 'pi_tee2') as b_tee2 \gset
select tests.create_booking(:'tee', :'stranger', 'pending_payment', 1, 50000, 'pi_tee3') as b_tee3 \gset
select tests.create_slot(:'venue', :'south', :'d'::timestamptz + interval '14 hours', :'d'::timestamptz + interval '15 hours') as south_14 \gset

set local role authenticated;
select tests.claims(:'owner');
select * from public.create_venue_closure(:'venue', null,
  :'d'::timestamptz + interval '13 hours', :'d'::timestamptz + interval '16 hours', null) \gset c2_
reset role;

select is((select court_id from public.venue_closures where id = :'c2_closure_id'), null, 'whole venue closure has no court');
select is(:'c2_closed_slot_count'::int, 2, 'whole venue closure closes every court''s slots');
select is((select status::text from public.venue_slots where id = :'tee'), 'closed', 'a part booked tee time is closed');
select is((select status::text from public.venue_slots where id = :'south_14'), 'closed', 'an open court slot is closed');
select bag_eq(
  format('select unnest(%L::uuid[])', :'c2_refunded_booking_ids'),
  format('values (%L::uuid), (%L::uuid)', :'b_tee1', :'b_tee2'),
  'every paid golfer on the tee time is refunded');
select bag_eq(
  format($$select booking_id, amount_cents from public.venue_refunds where booking_id in (%L, %L, %L)$$, :'b_tee1', :'b_tee2', :'b_tee3'),
  format($$values (%L::uuid, 100000), (%L::uuid, 50000)$$, :'b_tee1', :'b_tee2'),
  'each refund is the full amount that golfer paid');
select is((select status::text from public.venue_bookings where id = :'b_tee3'), 'cancelled', 'pending golfer is cancelled');
select is((select refund_reason from public.venue_bookings where id = :'b_tee1'), 'Venue closure', 'refund reason without a closure reason');

-- ---------- rerunning over the same window ----------
set local role authenticated;
select tests.claims(:'owner');
select * from public.create_venue_closure(:'venue', null,
  :'d'::timestamptz + interval '9 hours', :'d'::timestamptz + interval '16 hours', 'Again') \gset c3_
reset role;
select is(:'c3_closed_slot_count'::int, 1, 'an overlapping closure only closes slots still open (South 10:00)');
select is(:'c3_refunded_booking_ids'::uuid[], '{}'::uuid[], 'already cancelled bookings are not refunded twice');
select is((select count(*)::int from public.venue_refunds), 3, 'still exactly three refunds queued');

-- ---------- the closure blocks booking afterwards ----------
select throws_like(
  format('select * from public.book_venue_slot(%L, %L, null)', :'south_10', :'player'),
  'Slot closed%', 'a slot under a closure cannot be booked');

-- ---------- owner can remove a closure ----------
set local role authenticated;
select tests.claims(:'owner');
select lives_ok(format('delete from public.venue_closures where id = %L', :'c3_closure_id'), 'owner can delete a closure');
select tests.claims(:'stranger');
delete from public.venue_closures where id = :'c2_closure_id';
reset role;
select is((select count(*)::int from public.venue_closures where venue_id = :'venue'), 2, 'only the owner''s delete went through');


select * from finish();
rollback;
