-- complete_venue_booking and a newer hold (C13): on an exclusive slot the
-- newest booking owns the hold (the C11 rule). A payment for an older
-- booking whose hold expired and was retaken returns 'cancelled', as the
-- "slot taken" race does, so payments-webhook reinstates or refunds it
-- instead of taking the slot from the player who holds it now.
begin;
select plan(17);

select tests.create_user() as owner \gset
select tests.create_user() as player_a \gset
select tests.create_user() as player_b \gset
select tests.create_venue(:'owner') as venue \gset
select tests.create_court(:'venue', 'Court 1') as court \gset
select tests.create_court(:'venue', 'Course', null, 'golf', 'shared') as course \gset
select date_trunc('hour', now()) + interval '3 days' as d \gset

-- A booked first; the hold expired; B booked and holds the slot now.
create function pg_temp.retaken(_hour int, _a text, _b text) returns uuid language plpgsql as $$
declare
  _slot uuid;
  _older uuid;
begin
  _slot := tests.create_slot(current_setting('t.venue')::uuid, current_setting('t.court')::uuid,
                             current_setting('t.d')::timestamptz + make_interval(hours => _hour),
                             current_setting('t.d')::timestamptz + make_interval(hours => _hour + 1),
                             100000, null, 'held');
  _older := tests.create_booking(_slot, current_setting('t.a')::uuid, 'pending_payment', 1, 100000, _a);
  update public.venue_bookings set created_at = now() - interval '20 minutes' where id = _older;
  perform tests.create_booking(_slot, current_setting('t.b')::uuid, 'pending_payment', 1, 100000, _b);
  update public.venue_slots set held_until = now() + interval '9 minutes' where id = _slot;
  return _slot;
end $$;
select set_config('t.venue', :'venue', true) as c1, set_config('t.court', :'court', true) as c2,
       set_config('t.d', :'d', true) as c3, set_config('t.a', :'player_a', true) as c4,
       set_config('t.b', :'player_b', true) as c5 \gset

-- ---------------------------------------------------------------------------
-- Order 1: A's late payment lands while B still holds the slot.
-- ---------------------------------------------------------------------------
select pg_temp.retaken(10, 'pi_a1', 'pi_b1') as s1 \gset
select held_until as b1_hold from public.venue_slots where id = :'s1' \gset
set local role service_role;
select c.status::text as a1_status from public.complete_venue_booking('pi_a1') c \gset
reset role;
select is(:'a1_status'::text, 'cancelled', 'order 1: the older booking''s payment returns cancelled');
select results_eq($$select status::text, refund_reason from public.venue_bookings where paymongo_intent_id = 'pi_a1'$$,
  $$values ('cancelled', 'Slot taken before payment confirmed')$$, 'as the slot taken race: cancelled with that reason');
select results_eq(format('select status::text, held_until from public.venue_slots where id = %L', :'s1'),
  format($$values ('held', %L::timestamptz)$$, :'b1_hold'), 'B''s hold is untouched');
select is((select count(*)::int from public.transactions where gateway_ref = 'pi_a1'), 0, 'no payment row for A');
select is((select status::text from public.venue_bookings where paymongo_intent_id = 'pi_b1'), 'pending_payment', 'B is still pending');
set local role service_role;
select coalesce(r.id::text, 'null') as a1_reinstated from public.reinstate_venue_booking('pi_a1') r \gset
select c.status::text as b1_status from public.complete_venue_booking('pi_b1') c \gset
reset role;
select is(:'a1_reinstated'::text, 'null', 'the webhook''s reinstate then refuses A (B''s live hold), so A is refunded');
select is(:'b1_status'::text, 'paid', 'B''s payment completes');
select is((select status::text from public.venue_slots where id = :'s1'), 'booked', 'and B has the slot');

-- ---------------------------------------------------------------------------
-- Order 2: B pays first, then A's late payment lands.
-- ---------------------------------------------------------------------------
select pg_temp.retaken(12, 'pi_a2', 'pi_b2') as s2 \gset
set local role service_role;
select c.status::text as b2_status from public.complete_venue_booking('pi_b2') c \gset
select c.status::text as a2_status from public.complete_venue_booking('pi_a2') c \gset
reset role;
select is(:'b2_status'::text, 'paid', 'order 2: B pays first');
select is(:'a2_status'::text, 'cancelled', 'A''s payment then returns cancelled');
select is((select status::text from public.venue_slots where id = :'s2'), 'booked', 'B keeps the slot');
select is((select count(*)::int from public.transactions where gateway_ref in ('pi_a2', 'pi_b2')), 1, 'one payment row, B''s');

-- ---------------------------------------------------------------------------
-- Unchanged: the newest booking completes; shared tee times are pools.
-- ---------------------------------------------------------------------------
select pg_temp.retaken(14, 'pi_a3', 'pi_b3') as s3 \gset
set local role service_role;
select c.status::text as b3_status from public.complete_venue_booking('pi_b3') c \gset
reset role;
select is(:'b3_status'::text, 'paid', 'the booking that holds the slot completes');

select tests.create_slot(:'venue', :'court', :'d'::timestamptz + interval '16 hours', :'d'::timestamptz + interval '17 hours', 100000, null, 'held') as s4 \gset
select tests.create_booking(:'s4', :'player_a', 'pending_payment', 1, 100000, 'pi_alone') \gset
set local role service_role;
select c.status::text as alone_status from public.complete_venue_booking('pi_alone') c \gset
reset role;
select is(:'alone_status'::text, 'paid', 'a booking alone on its slot completes');

select tests.create_slot(:'venue', :'course', :'d'::timestamptz + interval '10 hours', :'d'::timestamptz + interval '10 hours 10 minutes', 50000, 4) as tee \gset
select tests.create_booking(:'tee', :'player_a', 'pending_payment', 2, 100000, 'pi_tee_old') as tee_old \gset
update public.venue_bookings set created_at = now() - interval '20 minutes' where id = :'tee_old';
select tests.create_booking(:'tee', :'player_b', 'pending_payment', 2, 100000, 'pi_tee_new') \gset
set local role service_role;
select c.status::text as tee_old_status from public.complete_venue_booking('pi_tee_old') c \gset
select c.status::text as tee_new_status from public.complete_venue_booking('pi_tee_new') c \gset
reset role;
select is(:'tee_old_status'::text, 'paid', 'shared: an older booking completes alongside newer ones');
select is(:'tee_new_status'::text, 'paid', 'shared: and so does the newer one');
select is((select status::text from public.venue_slots where id = :'tee'), 'booked', 'shared: the full tee time is booked');

select * from finish();
rollback;
