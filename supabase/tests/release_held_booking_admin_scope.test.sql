-- release_held_booking_admin (C11): the payments-webhook failure path and the
-- payments-create-intent rollback cancel one pending booking. An exclusive
-- slot is freed only when its current hold is that booking's; a shared tee
-- time that is no longer full reopens (closed instead under a closure).
begin;
select plan(17);

select tests.create_user() as owner \gset
select tests.create_user() as player \gset
select tests.create_user() as other \gset
select tests.create_venue(:'owner') as venue \gset
select tests.create_court(:'venue', 'Court 1') as court \gset
select tests.create_court(:'venue', 'Course', null, 'golf', 'shared') as course \gset
select date_trunc('hour', now()) + interval '3 days' as d \gset

-- ---------------------------------------------------------------------------
-- Exclusive: someone else holds the slot now.
-- ---------------------------------------------------------------------------
-- The player's hold expired and was swept; another player booked the slot
-- and holds it. The player's failed payment event arrives afterwards.
select tests.create_slot(:'venue', :'court', :'d'::timestamptz + interval '10 hours', :'d'::timestamptz + interval '11 hours', 100000, null, 'held') as s_ex \gset
select tests.create_booking(:'s_ex', :'player', 'pending_payment', 1, 100000, 'pi_old') as b_old \gset
update public.venue_bookings set created_at = now() - interval '20 minutes' where id = :'b_old';
select tests.create_booking(:'s_ex', :'other', 'pending_payment', 1, 100000, 'pi_new') as b_new \gset
update public.venue_slots set held_until = now() + interval '9 minutes' where id = :'s_ex';
select held_until as new_hold from public.venue_slots where id = :'s_ex' \gset

set local role service_role;
select public.release_held_booking_admin(:'b_old', 'Payment failed at gateway');
reset role;
select is((select status::text from public.venue_bookings where id = :'b_old'), 'cancelled', 'the failed booking is cancelled');
select results_eq(format('select status::text, held_until from public.venue_slots where id = %L', :'s_ex'),
  format($$values ('held', %L::timestamptz)$$, :'new_hold'),
  'another booking''s hold on the slot is left exactly as it was');
select is((select status::text from public.venue_bookings where id = :'b_new'), 'pending_payment', 'the other booking is untouched');

-- Its own hold: freed.
set local role service_role;
select public.release_held_booking_admin(:'b_new', 'PayMongo intent creation failed');
reset role;
select results_eq(format('select status::text, held_until from public.venue_slots where id = %L', :'s_ex'),
  $$values ('available', null::timestamptz)$$, 'the booking that holds the slot frees it');

-- Releasing the old booking again after a third player took a fresh hold:
-- a no op, the hold stays.
select tests.create_booking(:'s_ex', :'owner', 'pending_payment', 1, 100000, 'pi_third') as b_third \gset
update public.venue_slots set status = 'held', held_until = now() + interval '10 minutes' where id = :'s_ex';
set local role service_role;
select public.release_held_booking_admin(:'b_new', 'retry');
select public.release_held_booking_admin(:'b_old', 'retry');
reset role;
select is((select status::text from public.venue_slots where id = :'s_ex'), 'held', 'repeat releases never free a newer hold');

-- Booked by someone who paid: untouched (as before).
select tests.create_slot(:'venue', :'court', :'d'::timestamptz + interval '12 hours', :'d'::timestamptz + interval '13 hours', 100000, null, 'booked') as s_booked \gset
select tests.create_booking(:'s_booked', :'player', 'pending_payment', 1, 100000, 'pi_lost') as b_lost \gset
update public.venue_bookings set created_at = now() - interval '20 minutes' where id = :'b_lost';
select tests.create_booking(:'s_booked', :'other', 'paid', 1, 100000, 'pi_won') \gset
set local role service_role;
select public.release_held_booking_admin(:'b_lost');
reset role;
select is((select status::text from public.venue_slots where id = :'s_booked'), 'booked', 'a booked slot stays booked');
select is((select status::text from public.venue_bookings where id = :'b_lost'), 'cancelled', 'the pending booking is still cancelled');

-- ---------------------------------------------------------------------------
-- Shared tee times.
-- ---------------------------------------------------------------------------
select tests.create_slot(:'venue', :'course', :'d'::timestamptz + interval '10 hours', :'d'::timestamptz + interval '10 hours 10 minutes', 50000, 4, 'booked') as s_tee \gset
select tests.create_booking(:'s_tee', :'other', 'paid', 2, 100000) \gset
select tests.create_booking(:'s_tee', :'player', 'pending_payment', 2, 100000, 'pi_tee') as b_tee \gset
set local role service_role;
select public.release_held_booking_admin(:'b_tee', 'Payment failed at gateway');
reset role;
select is((select status::text from public.venue_bookings where id = :'b_tee'), 'cancelled', 'shared: the booking is cancelled');
select is((select status::text from public.venue_slots where id = :'s_tee'), 'available', 'shared: a full tee time with spots freed reopens');

-- An open tee time stays open.
select tests.create_slot(:'venue', :'course', :'d'::timestamptz + interval '10 hours 10 minutes', :'d'::timestamptz + interval '10 hours 20 minutes', 50000, 4) as s_tee_open \gset
select tests.create_booking(:'s_tee_open', :'player', 'pending_payment', 1, 50000, 'pi_tee_open') as b_tee_open \gset
set local role service_role;
select public.release_held_booking_admin(:'b_tee_open');
reset role;
select is((select status::text from public.venue_slots where id = :'s_tee_open'), 'available', 'shared: an open tee time stays open');

select tests.create_slot(:'venue', :'course', :'d'::timestamptz + interval '10 hours 20 minutes', :'d'::timestamptz + interval '10 hours 30 minutes', 50000, 4, 'booked') as s_tee_full \gset
select tests.create_booking(:'s_tee_full', :'other', 'paid', 4, 200000) \gset
select tests.create_booking(:'s_tee_full', :'player', 'cancelled', 1, 50000, 'pi_tee_gone') as b_tee_gone \gset
set local role service_role;
select public.release_held_booking_admin(:'b_tee_gone');
reset role;
select is((select status::text from public.venue_slots where id = :'s_tee_full'), 'booked',
  'shared: releasing a booking that is not pending leaves a full tee time booked');

-- Under a closure: closed, not available.
select tests.create_slot(:'venue', :'course', :'d'::timestamptz + interval '11 hours', :'d'::timestamptz + interval '11 hours 10 minutes', 50000, 4, 'booked') as s_tee_closed \gset
select tests.create_booking(:'s_tee_closed', :'other', 'paid', 3, 150000) \gset
select tests.create_booking(:'s_tee_closed', :'player', 'pending_payment', 1, 50000, 'pi_tee_closed') as b_tee_closed \gset
insert into public.venue_closures (venue_id, court_id, starts_at, ends_at)
values (:'venue', null, :'d'::timestamptz + interval '11 hours', :'d'::timestamptz + interval '12 hours');
set local role service_role;
select public.release_held_booking_admin(:'b_tee_closed');
reset role;
select is((select status::text from public.venue_slots where id = :'s_tee_closed'), 'closed',
  'shared: a tee time no longer full but under a closure becomes closed');

-- ---------------------------------------------------------------------------
-- Not pending: no op.
-- ---------------------------------------------------------------------------
select tests.create_slot(:'venue', :'court', :'d'::timestamptz + interval '14 hours', :'d'::timestamptz + interval '15 hours', 100000, null, 'booked') as s_paid \gset
select tests.create_booking(:'s_paid', :'player', 'paid', 1, 100000, 'pi_paid') as b_paid \gset
set local role service_role;
select public.release_held_booking_admin(:'b_paid');
reset role;
select is((select status::text from public.venue_bookings where id = :'b_paid'), 'paid', 'a paid booking stays paid');
select is((select status::text from public.venue_slots where id = :'s_paid'), 'booked', 'and its slot stays booked');

select tests.create_slot(:'venue', :'course', :'d'::timestamptz + interval '12 hours', :'d'::timestamptz + interval '12 hours 10 minutes', 50000, 4, 'booked') as s_tee_paid \gset
select tests.create_booking(:'s_tee_paid', :'player', 'paid', 4, 200000, 'pi_tee_paid') as b_tee_paid \gset
set local role service_role;
select public.release_held_booking_admin(:'b_tee_paid');
reset role;
select is((select status::text from public.venue_bookings where id = :'b_tee_paid'), 'paid', 'a paid tee time booking stays paid');
select is((select status::text from public.venue_slots where id = :'s_tee_paid'), 'booked', 'and its tee time stays booked');

set local role service_role;
select lives_ok($$select public.release_held_booking_admin(gen_random_uuid())$$, 'an unknown booking is a no op');
reset role;

select * from finish();
rollback;
