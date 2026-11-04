-- reinstate_venue_booking (C4, C11 note): a payment that lands on a booking
-- cancelled before it was paid puts the booking back, under the same checks
-- as book_venue_slot, when the slot still has room; otherwise it returns NULL
-- (never raises for "no room") so payments-webhook refunds in full.
begin;
select plan(40);

select tests.create_user() as owner \gset
select tests.create_user() as player \gset
select tests.create_user() as other \gset
select tests.create_team(:'player') as team \gset
select tests.create_venue(:'owner') as venue \gset
select tests.create_court(:'venue', 'Full Pitch') as pitch \gset
select tests.create_court(:'venue', 'North Half', :'pitch') as north \gset
select tests.create_court(:'venue', 'Court B') as court_b \gset
select tests.create_court(:'venue', 'Course', null, 'golf', 'shared') as course \gset
select date_trunc('hour', now()) + interval '3 days' as d \gset

-- A booking cancelled before payment (stale hold or failed intent), the way
-- release paths leave it: cancelled, no transactions row, no snapshot.
create function pg_temp.cancelled_booking(_slot uuid, _captain uuid, _party int, _total int, _intent text)
returns uuid language sql as $$
  with b as (
    insert into public.venue_bookings (
      slot_id, venue_id, captain_user_id, party_size, total_cents,
      platform_fee_cents, payout_cents, status, paymongo_intent_id, refund_reason
    )
    select _slot, s.venue_id, _captain, _party, _total, _total / 20, _total - _total / 20,
           'cancelled', _intent, 'Auto-released: payment not completed'
      from public.venue_slots s where s.id = _slot
    returning id
  ) select id from b
$$;

-- ---------------------------------------------------------------------------
-- Exclusive slot with room, team booking.
-- ---------------------------------------------------------------------------
select tests.create_slot(:'venue', :'court_b', :'d'::timestamptz + interval '10 hours', :'d'::timestamptz + interval '11 hours', 100000) as s_ex \gset
select pg_temp.cancelled_booking(:'s_ex', :'player', 1, 100000, 'pi_ex_ok') as b_ex \gset
update public.venue_bookings set team_id = :'team' where id = :'b_ex';

set local role service_role;
select coalesce(r.id::text, 'null') as r_ex, r.status as r_ex_status from public.reinstate_venue_booking('pi_ex_ok') r \gset
reset role;
select is(:'r_ex'::uuid, :'b_ex'::uuid, 'exclusive with room: returns the reinstated booking');
select is(:'r_ex_status'::text, 'paid', 'and the returned row is paid');
select is((select status::text from public.venue_bookings where id = :'b_ex'), 'paid', 'booking is paid');
select results_eq(format('select status::text, held_until from public.venue_slots where id = %L', :'s_ex'),
  $$values ('booked', null::timestamptz)$$, 'exclusive slot is booked with no hold');
select is((select refund_policy_snapshot from public.venue_bookings where id = :'b_ex'),
  (select default_refund_policy from public.venues where id = :'venue'),
  'a missing refund policy snapshot is written (venue default, no slot override)');
select is((select count(*)::int from public.events where venue_booking_id = :'b_ex'), 1, 'team booking gets its match event');
select is((select event_id from public.venue_bookings where id = :'b_ex'),
  (select id from public.events where venue_booking_id = :'b_ex'), 'and the booking points at it');
select results_eq(
  format($$select user_id, team_id, amount_cents, platform_fee_cents, currency, metadata
             from public.transactions where gateway_ref = 'pi_ex_ok'$$),
  format($$values (%L::uuid, %L::uuid, 100000, 5000, 'PHP', jsonb_build_object(
             'booking_id', %L::uuid, 'slot_id', %L::uuid, 'venue_id', %L::uuid, 'court_id', %L::uuid, 'party_size', 1))$$,
         :'player', :'team', :'b_ex', :'s_ex', :'venue', :'court_b'),
  'one transactions row with the booking''s money, captain, team and metadata');

-- Same transactions row as complete_venue_booking writes for a twin booking.
select tests.create_slot(:'venue', :'court_b', :'d'::timestamptz + interval '12 hours', :'d'::timestamptz + interval '13 hours', 100000, null, 'held') as s_twin \gset
select tests.create_booking(:'s_twin', :'player', 'pending_payment', 1, 100000, 'pi_twin') as b_twin \gset
update public.venue_bookings set team_id = :'team' where id = :'b_twin';
set local role service_role;
select * from public.complete_venue_booking('pi_twin') \gset
reset role;
select results_eq(
  $$select type::text, gateway::text, status::text, amount_cents, platform_fee_cents, currency,
           team_id, user_id, array(select jsonb_object_keys(metadata) order by 1)
      from public.transactions where gateway_ref = 'pi_ex_ok'$$,
  $$select type::text, gateway::text, status::text, amount_cents, platform_fee_cents, currency,
           team_id, user_id, array(select jsonb_object_keys(metadata) order by 1)
      from public.transactions where gateway_ref = 'pi_twin'$$,
  'the reinstated transactions row matches complete_venue_booking''s row field for field');
select results_eq(
  format($$select type::text, title, status::text, slot_count, reserve_count, slot_fee_cents, created_by
             from public.events where venue_booking_id = %L$$, :'b_ex'),
  format($$select type::text, title, status::text, slot_count, reserve_count, slot_fee_cents, created_by
             from public.events where venue_booking_id = %L$$, :'b_twin'),
  'and its match event matches complete_venue_booking''s');

-- Idempotent: a second call returns the same paid row and writes nothing.
set local role service_role;
select coalesce(r.id::text, 'null') as r_ex2, r.status as r_ex2_status from public.reinstate_venue_booking('pi_ex_ok') r \gset
reset role;
select is(:'r_ex2'::uuid, :'b_ex'::uuid, 'second call returns the same booking');
select is(:'r_ex2_status'::text, 'paid', 'still paid');
select is((select count(*)::int from public.transactions where gateway_ref = 'pi_ex_ok'), 1, 'still one transactions row');
select is((select count(*)::int from public.events where venue_booking_id = :'b_ex'), 1, 'still one event');

-- ---------------------------------------------------------------------------
-- Shared tee times: capacity.
-- ---------------------------------------------------------------------------
-- Room for the party and it fills the tee time: booked.
select tests.create_slot(:'venue', :'course', :'d'::timestamptz + interval '10 hours', :'d'::timestamptz + interval '10 hours 10 minutes', 50000, 4) as s_tee_fill \gset
select tests.create_booking(:'s_tee_fill', :'other', 'paid', 2, 100000) \gset
select pg_temp.cancelled_booking(:'s_tee_fill', :'player', 2, 100000, 'pi_tee_fill') as b_tee_fill \gset
set local role service_role;
select coalesce(r.id::text, 'null') as r_tee_fill from public.reinstate_venue_booking('pi_tee_fill') r \gset
reset role;
select is(:'r_tee_fill'::uuid, :'b_tee_fill'::uuid, 'shared with room: reinstated');
select is((select status::text from public.venue_slots where id = :'s_tee_fill'), 'booked', 'a tee time it fills becomes booked');
select is((select count(*)::int from public.transactions where gateway_ref = 'pi_tee_fill'), 1, 'and its payment is recorded');

-- Room left after the party: stays open.
select tests.create_slot(:'venue', :'course', :'d'::timestamptz + interval '10 hours 10 minutes', :'d'::timestamptz + interval '10 hours 20 minutes', 50000, 4) as s_tee_open \gset
select pg_temp.cancelled_booking(:'s_tee_open', :'player', 1, 50000, 'pi_tee_open') as b_tee_open \gset
set local role service_role;
select coalesce(r.id::text, 'null') as r_tee_open from public.reinstate_venue_booking('pi_tee_open') r \gset
reset role;
select is(:'r_tee_open'::uuid, :'b_tee_open'::uuid, 'shared with more room than the party: reinstated');
select is((select status::text from public.venue_slots where id = :'s_tee_open'), 'available', 'the tee time stays open');

-- Open, but not enough spots for the party: NULL.
select tests.create_slot(:'venue', :'course', :'d'::timestamptz + interval '10 hours 20 minutes', :'d'::timestamptz + interval '10 hours 30 minutes', 50000, 4) as s_tee_short \gset
select tests.create_booking(:'s_tee_short', :'other', 'paid', 3, 150000) \gset
select pg_temp.cancelled_booking(:'s_tee_short', :'player', 2, 100000, 'pi_tee_short') as b_tee_short \gset
set local role service_role;
select coalesce(r.id::text, 'null') as r_tee_short from public.reinstate_venue_booking('pi_tee_short') r \gset
reset role;
select is(:'r_tee_short'::text, 'null', 'shared without room for the party: NULL, no error');
select is((select status::text from public.venue_bookings where id = :'b_tee_short'), 'cancelled', 'booking stays cancelled');
select is((select count(*)::int from public.transactions where gateway_ref = 'pi_tee_short'), 0, 'no payment recorded');

-- Full (booked): NULL.
select tests.create_slot(:'venue', :'course', :'d'::timestamptz + interval '10 hours 30 minutes', :'d'::timestamptz + interval '10 hours 40 minutes', 50000, 4, 'booked') as s_tee_full \gset
select tests.create_booking(:'s_tee_full', :'other', 'paid', 4, 200000) \gset
select pg_temp.cancelled_booking(:'s_tee_full', :'player', 1, 50000, 'pi_tee_full') as b_tee_full \gset
set local role service_role;
select coalesce(r.id::text, 'null') as r_tee_full from public.reinstate_venue_booking('pi_tee_full') r \gset
reset role;
select is(:'r_tee_full'::text, 'null', 'shared tee time that is full: NULL');

-- ---------------------------------------------------------------------------
-- Exclusive slots without room.
-- ---------------------------------------------------------------------------
-- Court tree conflict: the parent pitch is booked over the same hour.
select tests.create_slot(:'venue', :'pitch', :'d'::timestamptz + interval '14 hours', :'d'::timestamptz + interval '15 hours', 300000, null, 'booked') \gset
select tests.create_slot(:'venue', :'north', :'d'::timestamptz + interval '14 hours', :'d'::timestamptz + interval '15 hours', 150000) as s_tree \gset
select pg_temp.cancelled_booking(:'s_tree', :'player', 1, 150000, 'pi_tree') as b_tree \gset
set local role service_role;
select coalesce(r.id::text, 'null') as r_tree from public.reinstate_venue_booking('pi_tree') r \gset
reset role;
select is(:'r_tree'::text, 'null', 'exclusive slot whose court tree is booked at that time: NULL');
select is((select status::text from public.venue_slots where id = :'s_tree'), 'available', 'and the slot is untouched');

-- Another booking holds the slot now.
select tests.create_slot(:'venue', :'court_b', :'d'::timestamptz + interval '16 hours', :'d'::timestamptz + interval '17 hours', 100000, null, 'held') as s_held \gset
update public.venue_slots set held_until = now() + interval '8 minutes' where id = :'s_held';
select tests.create_booking(:'s_held', :'other', 'pending_payment', 1, 100000, 'pi_holder') \gset
select pg_temp.cancelled_booking(:'s_held', :'player', 1, 100000, 'pi_held') as b_held \gset
set local role service_role;
select coalesce(r.id::text, 'null') as r_held from public.reinstate_venue_booking('pi_held') r \gset
reset role;
select is(:'r_held'::text, 'null', 'exclusive slot under someone else''s live hold: NULL');
select is((select status::text from public.venue_slots where id = :'s_held'), 'held', 'their hold stays');

-- Someone else paid for it.
select tests.create_slot(:'venue', :'court_b', :'d'::timestamptz + interval '18 hours', :'d'::timestamptz + interval '19 hours', 100000, null, 'booked') as s_taken \gset
select tests.create_booking(:'s_taken', :'other', 'paid', 1, 100000) \gset
select pg_temp.cancelled_booking(:'s_taken', :'player', 1, 100000, 'pi_taken') as b_taken \gset
set local role service_role;
select coalesce(r.id::text, 'null') as r_taken from public.reinstate_venue_booking('pi_taken') r \gset
reset role;
select is(:'r_taken'::text, 'null', 'exclusive slot someone else paid for: NULL');

-- An expired hold does not block (as in book_venue_slot).
select tests.create_slot(:'venue', :'court_b', :'d'::timestamptz + interval '20 hours', :'d'::timestamptz + interval '21 hours', 100000, null, 'held') as s_stale \gset
update public.venue_slots set held_until = now() - interval '1 minute' where id = :'s_stale';
select pg_temp.cancelled_booking(:'s_stale', :'player', 1, 100000, 'pi_stale') as b_stale \gset
set local role service_role;
select coalesce(r.id::text, 'null') as r_stale from public.reinstate_venue_booking('pi_stale') r \gset
reset role;
select is(:'r_stale'::uuid, :'b_stale'::uuid, 'exclusive slot with an expired hold: reinstated');
select is((select status::text from public.venue_slots where id = :'s_stale'), 'booked', 'and booked');

-- ---------------------------------------------------------------------------
-- Closed, past, refunded, paid before, unknown.
-- ---------------------------------------------------------------------------
-- A closure written directly leaves the slot 'available': the check itself
-- must refuse it.
select tests.create_slot(:'venue', :'north', :'d'::timestamptz + interval '22 hours', :'d'::timestamptz + interval '23 hours', 100000) as s_closed \gset
insert into public.venue_closures (venue_id, court_id, starts_at, ends_at)
values (:'venue', :'pitch', :'d'::timestamptz + interval '22 hours 30 minutes', :'d'::timestamptz + interval '23 hours 30 minutes');
select pg_temp.cancelled_booking(:'s_closed', :'player', 1, 100000, 'pi_closed') as b_closed \gset
set local role service_role;
select coalesce(r.id::text, 'null') as r_closed from public.reinstate_venue_booking('pi_closed') r \gset
reset role;
select is(:'r_closed'::text, 'null', 'slot under a closure (parent court): NULL');
select is((select count(*)::int from public.transactions where gateway_ref = 'pi_closed'), 0, 'no payment recorded');

select tests.create_slot(:'venue', :'court_b', now() - interval '30 minutes', now() + interval '30 minutes', 100000) as s_past \gset
select pg_temp.cancelled_booking(:'s_past', :'player', 1, 100000, 'pi_past') as b_past \gset
set local role service_role;
select coalesce(r.id::text, 'null') as r_past from public.reinstate_venue_booking('pi_past') r \gset
reset role;
select is(:'r_past'::text, 'null', 'slot that has already started: NULL');

select tests.create_slot(:'venue', :'court_b', :'d'::timestamptz + interval '24 hours', :'d'::timestamptz + interval '25 hours', 100000) as s_refunded \gset
select pg_temp.cancelled_booking(:'s_refunded', :'player', 1, 100000, 'pi_refunded') as b_refunded \gset
set local role service_role;
select public.queue_venue_refund(:'b_refunded', 100000, 'late_payment') \gset
select coalesce(r.id::text, 'null') as r_refunded from public.reinstate_venue_booking('pi_refunded') r \gset
reset role;
select is(:'r_refunded'::text, 'null', 'booking with a late_payment refund already queued: NULL even with room');
select is((select status::text from public.venue_slots where id = :'s_refunded'), 'available', 'and the slot is not taken');

-- Paid once, then cancelled (here: a 0% player cancel): never reinstated.
select tests.create_slot(:'venue', :'court_b', :'d'::timestamptz + interval '26 hours', :'d'::timestamptz + interval '27 hours', 100000) as s_was_paid \gset
select pg_temp.cancelled_booking(:'s_was_paid', :'player', 1, 100000, 'pi_was_paid') as b_was_paid \gset
insert into public.transactions (user_id, type, amount_cents, gateway, gateway_ref, status)
values (:'player', 'venue_booking', 100000, 'paymongo', 'pi_was_paid', 'succeeded');
set local role service_role;
select coalesce(r.id::text, 'null') as r_was_paid from public.reinstate_venue_booking('pi_was_paid') r \gset
reset role;
select is(:'r_was_paid'::text, 'null', 'a cancelled booking that had been paid: NULL');

select tests.create_slot(:'venue', :'court_b', :'d'::timestamptz + interval '28 hours', :'d'::timestamptz + interval '29 hours', 100000, null, 'held') as s_pending \gset
update public.venue_slots set held_until = now() + interval '8 minutes' where id = :'s_pending';
select tests.create_booking(:'s_pending', :'player', 'pending_payment', 1, 100000, 'pi_pending') as b_pending \gset
set local role service_role;
select coalesce(r.id::text, 'null') as r_pending from public.reinstate_venue_booking('pi_pending') r \gset
reset role;
select is(:'r_pending'::text, 'null', 'a booking still pending payment is not this function''s to complete: NULL');
select is((select status::text from public.venue_bookings where id = :'b_pending'), 'pending_payment', 'and it is left alone');

set local role service_role;
select coalesce(r.id::text, 'null') as r_unknown from public.reinstate_venue_booking('pi_nobody') r \gset
reset role;
select is(:'r_unknown'::text, 'null', 'unknown intent: NULL');

-- An existing snapshot is kept.
select tests.create_slot(:'venue', :'court_b', :'d'::timestamptz + interval '30 hours', :'d'::timestamptz + interval '31 hours', 100000) as s_snap \gset
update public.venue_slots set refund_policy = '{"tiers":[{"hours_before":0,"refund_pct":0}]}' where id = :'s_snap';
select pg_temp.cancelled_booking(:'s_snap', :'player', 1, 100000, 'pi_snap') as b_snap \gset
update public.venue_bookings set refund_policy_snapshot = '{"tiers":[{"hours_before":0,"refund_pct":100}]}' where id = :'b_snap';
set local role service_role;
select coalesce(r.id::text, 'null') as r_snap from public.reinstate_venue_booking('pi_snap') r \gset
reset role;
select is((select refund_policy_snapshot from public.venue_bookings where id = :'b_snap'),
  '{"tiers":[{"hours_before":0,"refund_pct":100}]}'::jsonb, 'an existing refund policy snapshot is kept');

select * from finish();
rollback;
