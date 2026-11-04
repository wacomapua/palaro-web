-- apply_venue_closure gives a closure written the old way the full
-- create_venue_closure treatment, and complete_venue_booking never turns a
-- booking under a closure into a paid one.
begin;
select plan(33);

select tests.create_user() as owner \gset
select tests.create_user() as p1 \gset
select tests.create_user() as p2 \gset
select tests.create_user() as p3 \gset
select tests.create_venue(:'owner') as venue \gset
select tests.create_court(:'venue', 'Course', null, 'golf', 'shared') as course \gset
select tests.create_court(:'venue', 'Full Pitch') as pitch \gset
select tests.create_court(:'venue', 'North Half', :'pitch') as north \gset
select tests.create_court(:'venue', 'Court B') as court_b \gset
select date_trunc('day', now()) + interval '3 days' as d \gset

-- ---------- complete_venue_booking backstop ----------
-- A legacy closure (written straight to the table) over a held exclusive slot
-- on a child court and an open tee time, each with a booking awaiting payment.
insert into public.venue_closures (venue_id, court_id, starts_at, ends_at)
values (:'venue', :'pitch', :'d'::timestamptz + interval '8 hours', :'d'::timestamptz + interval '9 hours'),
       (:'venue', :'course', :'d'::timestamptz + interval '8 hours', :'d'::timestamptz + interval '9 hours');

select tests.create_slot(:'venue', :'north', :'d'::timestamptz + interval '8 hours', :'d'::timestamptz + interval '9 hours', 100000, null, 'held') as c_held \gset
update public.venue_slots set held_until = now() + interval '5 minutes' where id = :'c_held';
select tests.create_booking(:'c_held', :'p1', 'pending_payment', 1, 100000, 'pi_c_held') as cb_held \gset
select tests.create_slot(:'venue', :'course', :'d'::timestamptz + interval '8 hours', :'d'::timestamptz + interval '8 hours 10 minutes', 50000, 4) as c_tee \gset
select tests.create_booking(:'c_tee', :'p2', 'pending_payment', 4, 200000, 'pi_c_tee') as cb_tee \gset
-- Control: same time, unrelated court, no closure.
select tests.create_slot(:'venue', :'court_b', :'d'::timestamptz + interval '8 hours', :'d'::timestamptz + interval '9 hours', 100000, null, 'held') as c_free \gset
select tests.create_booking(:'c_free', :'p3', 'pending_payment', 1, 100000, 'pi_c_free') as cb_free \gset

set local role service_role;
select * from public.complete_venue_booking('pi_c_held') \gset held_
select * from public.complete_venue_booking('pi_c_tee') \gset tee_
select * from public.complete_venue_booking('pi_c_free') \gset free_
reset role;

select is(:'held_status'::text, 'cancelled', 'exclusive: completing a payment under a closure returns cancelled');
select is((select status::text from public.venue_bookings where id = :'cb_held'), 'cancelled', 'exclusive: the booking is cancelled, not paid');
select is((select status::text from public.venue_slots where id = :'c_held'), 'closed', 'exclusive: the slot ends closed, not booked');
select is((select refund_reason from public.venue_bookings where id = :'cb_held'), 'Venue closed before payment confirmed',
  'exclusive: the reason says why');
select is(:'tee_status'::text, 'cancelled', 'shared: completing a payment under a closure returns cancelled');
select is((select status::text from public.venue_bookings where id = :'cb_tee'), 'cancelled', 'shared: the booking is cancelled, not paid');
select is((select status::text from public.venue_slots where id = :'c_tee'), 'closed', 'shared: a full tee time ends closed, not booked');
select is((select count(*)::int from public.transactions where gateway_ref in ('pi_c_held', 'pi_c_tee')), 0,
  'no payment ledger row is written for a cancelled completion');
select is((select count(*)::int from public.venue_refunds where booking_id in (:'cb_held', :'cb_tee')), 0,
  'the late payment refund is left to the webhook (never paid here)');
select is(:'free_status'::text, 'paid', 'control: completion outside any closure still marks paid');
select is((select status::text from public.venue_slots where id = :'c_free'), 'booked', 'control: and books the slot');

set local role service_role;
select is((select status::text from public.complete_venue_booking('pi_c_held')), 'cancelled', 'a retried webhook stays cancelled');
reset role;

-- ---------- closures that existed before the migration ----------
-- Seeded the old way: closure row only, slots and bookings untouched.
insert into public.venue_closures (venue_id, court_id, starts_at, ends_at, reason)
values (:'venue', null, :'d'::timestamptz + interval '12 hours', :'d'::timestamptz + interval '14 hours', 'Typhoon')
returning id as legacy \gset
insert into public.venue_closures (venue_id, court_id, starts_at, ends_at)
values (:'venue', null, now() - interval '3 hours', now() - interval '1 hour')
returning id as ended \gset

select tests.create_slot(:'venue', :'course', :'d'::timestamptz + interval '12 hours', :'d'::timestamptz + interval '12 hours 10 minutes', 50000, 4) as tee \gset
select tests.create_booking(:'tee', :'p1', 'paid', 2, 100000, 'pi_tee_paid') as b_tee_paid \gset
select tests.create_booking(:'tee', :'p2', 'pending_payment', 1, 50000, 'pi_tee_pend') as b_tee_pend \gset
select tests.create_slot(:'venue', :'north', :'d'::timestamptz + interval '12 hours', :'d'::timestamptz + interval '13 hours', 120000, null, 'held') as held \gset
update public.venue_slots set held_until = now() + interval '5 minutes' where id = :'held';
select tests.create_booking(:'held', :'p3', 'pending_payment', 1, 120000, 'pi_held') as b_held \gset
select tests.create_slot(:'venue', :'court_b', :'d'::timestamptz + interval '13 hours', :'d'::timestamptz + interval '14 hours', 90000, null, 'booked') as booked \gset
select tests.create_booking(:'booked', :'p1', 'paid', 1, 90000, 'pi_booked') as b_booked \gset
-- Under the closure that already ended: a game that was played.
select tests.create_slot(:'venue', :'court_b', now() - interval '3 hours', now() - interval '2 hours', 90000, null, 'booked') as played \gset
select tests.create_booking(:'played', :'p2', 'paid', 1, 90000, 'pi_played') as b_played \gset

select is(has_function_privilege('anon', 'public.apply_venue_closure(uuid)', 'execute'), false, 'anon cannot apply a closure');
select is(has_function_privilege('authenticated', 'public.apply_venue_closure(uuid)', 'execute'), false, 'authenticated cannot apply a closure');
select is(has_function_privilege('service_role', 'public.apply_venue_closure(uuid)', 'execute'), true, 'service_role can apply a closure');
select is((select prosecdef from pg_proc where oid = 'public.apply_venue_closure(uuid)'::regprocedure), true, 'apply_venue_closure is SECURITY DEFINER');
select ok((select proconfig @> array['search_path=public'] from pg_proc where oid = 'public.apply_venue_closure(uuid)'::regprocedure),
  'apply_venue_closure pins search_path');

-- The helper on its own, over this venue's closures that have not ended. The
-- migration's own run over pre-existing closures is covered by
-- premigrate_closures.test.sql.
select lives_ok(
  format('select public.apply_venue_closure(id) from public.venue_closures where venue_id = %L and ends_at > now() order by created_at, id', :'venue'),
  'apply_venue_closure runs over the venue''s active closures');

select is((select status::text from public.venue_bookings where id = :'b_tee_paid'), 'cancelled', 'paid golfer under a legacy closure is cancelled');
select results_eq(
  format($$select amount_cents, reason, status from public.venue_refunds where booking_id = %L$$, :'b_tee_paid'),
  $$values (100000, 'venue_closure', 'pending')$$, 'and gets a full venue_closure refund queued');
select is((select refund_reason from public.venue_bookings where id = :'b_tee_paid'), 'Venue closure: Typhoon', 'with the closure''s reason');
select is((select status::text from public.venue_bookings where id = :'b_tee_pend'), 'cancelled', 'pending golfer is cancelled');
select is((select count(*)::int from public.venue_refunds where booking_id = :'b_tee_pend'), 0, 'with no refund queued');
select is((select status::text from public.venue_slots where id = :'tee'), 'closed', 'the tee time is closed');
select is((select status::text from public.venue_bookings where id = :'b_held'), 'cancelled', 'held exclusive booking is cancelled');
select is((select status::text from public.venue_slots where id = :'held'), 'closed', 'and its slot is closed');
select is((select status::text from public.venue_bookings where id = :'b_booked'), 'cancelled', 'paid exclusive booking is cancelled');
select is((select amount_cents from public.venue_refunds where booking_id = :'b_booked' and reason = 'venue_closure'), 90000, 'with a full refund queued');
select is((select status::text from public.venue_bookings where id = :'b_played'), 'paid', 'a closure that already ended is not applied');
select is((select status::text from public.venue_slots where id = :'played'), 'booked', 'and its slot is untouched');
-- The earlier backstop closures were applied too: their cancelled bookings get no refund.
select is((select count(*)::int from public.venue_refunds where booking_id in (:'cb_held', :'cb_tee', :'cb_free')), 0,
  'unpaid bookings never get a closure refund');

-- Running it again changes nothing.
set local role service_role;
select * from public.apply_venue_closure(:'legacy') \gset again_
reset role;
select is(:'again_closed_slot_count'::int, 0, 'reapplying closes nothing new');
select is((select count(*)::int from public.venue_refunds r join public.venue_bookings b on b.id = r.booking_id where b.venue_id = :'venue'), 2,
  'and queues no second refund');

select * from finish();
rollback;
