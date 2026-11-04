-- queue_venue_refund for late payments (C12 a, b).
--   a. A late_payment refund on a booking that stands (paid or completed)
--      queues nothing and returns NULL: one webhook delivery reinstated the
--      booking while another tried to refund it. The booking row lock orders
--      the two (two session test: late_payment_race_sessions.test.mjs).
--   b. Queueing a late_payment refund records the captured payment as the
--      intent's venue_booking transactions row, shaped as
--      complete_venue_booking writes it, when the intent has no row yet, so
--      receipts show the payment and then the refund. Never a second row for
--      an intent: payments-webhook resolves gateway_ref with maybeSingle().
begin;
select plan(37);

select tests.create_user() as owner \gset
select tests.create_user() as captain \gset
select tests.create_team(:'captain') as team \gset
select tests.create_venue(:'owner') as venue \gset
select tests.create_court(:'venue', 'Court 1') as court \gset
select tests.create_court(:'venue', 'Course', null, 'golf', 'shared') as course \gset
select date_trunc('hour', now()) + interval '3 days' as d \gset

-- ---------------------------------------------------------------------------
-- a. Bookings that stand are not refunded as late payments.
-- ---------------------------------------------------------------------------
select tests.create_slot(:'venue', :'court', :'d'::timestamptz + interval '10 hours', :'d'::timestamptz + interval '11 hours', 100000, null, 'booked') as s_paid \gset
select tests.create_booking(:'s_paid', :'captain', 'paid', 1, 100000, 'pi_paid') as b_paid \gset
select tests.create_slot(:'venue', :'court', :'d'::timestamptz + interval '12 hours', :'d'::timestamptz + interval '13 hours', 100000, null, 'booked') as s_done \gset
select tests.create_booking(:'s_done', :'captain', 'completed', 1, 100000, 'pi_done') as b_done \gset

set local role service_role;
select coalesce(public.queue_venue_refund(:'b_paid', 100000, 'late_payment')::text, 'null') as q_paid \gset
select coalesce(public.queue_venue_refund(:'b_done', 100000, 'late_payment')::text, 'null') as q_done \gset
reset role;
select is(:'q_paid'::text, 'null', 'late_payment on a paid booking: NULL');
select is(:'q_done'::text, 'null', 'late_payment on a completed booking: NULL');
select is((select count(*)::int from public.venue_refunds where booking_id in (:'b_paid', :'b_done')), 0, 'and nothing is queued');
select is((select count(*)::int from public.transactions where gateway_ref in ('pi_paid', 'pi_done')), 0, 'nor any payment row written');

-- Other reasons on a paid booking queue as before (closures cancel first,
-- but the function itself does not police them).
set local role service_role;
select coalesce(public.queue_venue_refund(:'b_paid', 100000, 'player_cancel')::text, 'null') as q_cancel \gset
reset role;
select isnt(:'q_cancel'::text, 'null', 'player_cancel on a paid booking still queues');

-- ---------------------------------------------------------------------------
-- b. A late payment refund records the payment once.
-- ---------------------------------------------------------------------------
-- A team booking cancelled before its payment landed.
select tests.create_slot(:'venue', :'court', :'d'::timestamptz + interval '14 hours', :'d'::timestamptz + interval '15 hours', 120000) as s_late \gset
select tests.create_booking(:'s_late', :'captain', 'cancelled', 1, 120000, 'pi_late') as b_late \gset
update public.venue_bookings set team_id = :'team' where id = :'b_late';

set local role service_role;
select public.queue_venue_refund(:'b_late', 120000, 'late_payment') as r_late \gset
reset role;
select isnt(:'r_late'::text, null, 'late_payment on a cancelled booking queues a refund');
select is((select count(*)::int from public.transactions where gateway_ref = 'pi_late'), 1, 'and the intent gets exactly one transactions row');
select results_eq(
  $$select type::text, status::text, gateway::text, user_id, team_id, amount_cents, platform_fee_cents, currency, metadata
      from public.transactions where gateway_ref = 'pi_late'$$,
  format($$values ('venue_booking', 'succeeded', 'paymongo', %L::uuid, %L::uuid, 120000, 6000, 'PHP', jsonb_build_object(
             'booking_id', %L::uuid, 'slot_id', %L::uuid, 'venue_id', %L::uuid, 'court_id', %L::uuid, 'party_size', 1))$$,
         :'captain', :'team', :'b_late', :'s_late', :'venue', :'court'),
  'the payment row is the captured payment, shaped as complete_venue_booking writes it');

-- Same columns, field for field, as complete_venue_booking for a twin.
select tests.create_slot(:'venue', :'court', :'d'::timestamptz + interval '16 hours', :'d'::timestamptz + interval '17 hours', 120000, null, 'held') as s_twin \gset
select tests.create_booking(:'s_twin', :'captain', 'pending_payment', 1, 120000, 'pi_twin') as b_twin \gset
update public.venue_bookings set team_id = :'team' where id = :'b_twin';
set local role service_role;
select * from public.complete_venue_booking('pi_twin') \gset
reset role;
select results_eq(
  $$select type::text, gateway::text, status::text, amount_cents, platform_fee_cents, currency, team_id, user_id,
           array(select jsonb_object_keys(metadata) order by 1)
      from public.transactions where gateway_ref = 'pi_late'$$,
  $$select type::text, gateway::text, status::text, amount_cents, platform_fee_cents, currency, team_id, user_id,
           array(select jsonb_object_keys(metadata) order by 1)
      from public.transactions where gateway_ref = 'pi_twin'$$,
  'matches complete_venue_booking''s row for a twin booking');

-- Repeat queue, reinstate and complete: still one row per intent.
set local role service_role;
select public.queue_venue_refund(:'b_late', 120000, 'late_payment') as r_late2 \gset
select coalesce(r.id::text, 'null') as reinstated from public.reinstate_venue_booking('pi_late') r \gset
select c.status::text as completed_status from public.complete_venue_booking('pi_late') c \gset
reset role;
select is(:'r_late2'::uuid, :'r_late'::uuid, 'queueing again returns the same refund');
select is(:'reinstated'::text, 'null', 'reinstate refuses the refunded booking');
select is(:'completed_status'::text, 'cancelled', 'complete_venue_booking leaves it cancelled');
select is((select count(*)::int from public.transactions where gateway_ref = 'pi_late'), 1,
  'still exactly one transactions row for the intent (the webhook''s maybeSingle lookup)');
select is((select count(*)::int from public.venue_refunds where booking_id = :'b_late'), 1, 'and one refund');
select is((select status::text from public.venue_bookings where id = :'b_late'), 'cancelled', 'the booking stays cancelled');

-- Receipts after the refund goes through: the payment, then the refund.
set local role service_role;
select public.record_venue_refund_result(:'r_late', true, 'ref_late', null);
reset role;
set local role authenticated;
select tests.claims(:'captain');
select results_eq(
  $$select type::text, amount_cents, status::text from public.transactions
     where gateway_ref in ('pi_late', 'ref_late') order by created_at, type$$,
  $$values ('venue_booking', 120000, 'succeeded'), ('venue_refund', 120000, 'succeeded')$$,
  'receipts: the captain sees the captured payment and its refund');
reset role;

-- Paid then cancelled (the intent already has its payment row): a late
-- payment refund is not this booking's, NULL; the row is not duplicated.
select tests.create_slot(:'venue', :'court', :'d'::timestamptz + interval '18 hours', :'d'::timestamptz + interval '19 hours', 90000) as s_has \gset
select tests.create_booking(:'s_has', :'captain', 'cancelled', 1, 90000, 'pi_has') as b_has \gset
insert into public.transactions (user_id, type, amount_cents, gateway, gateway_ref, status)
values (:'captain', 'venue_booking', 90000, 'paymongo', 'pi_has', 'succeeded');
set local role service_role;
select coalesce(public.queue_venue_refund(:'b_has', 90000, 'late_payment')::text, 'null') as q_has \gset
reset role;
select is(:'q_has'::text, 'null', 'late_payment for a booking whose intent was paid (then cancelled): NULL');
select is((select count(*)::int from public.venue_refunds where booking_id = :'b_has'), 0, 'nothing queued');
select is((select count(*)::int from public.transactions where gateway_ref = 'pi_has'), 1, 'and the payment row is not duplicated');

-- ---------------------------------------------------------------------------
-- Refunds never add up to more than the booking paid (review finding 1).
-- ---------------------------------------------------------------------------
-- A paid booking the venue closed: full venue_closure refund queued; a late
-- payment refund on top is refused (its intent was paid through complete).
select tests.create_slot(:'venue', :'court', :'d'::timestamptz + interval '26 hours', :'d'::timestamptz + interval '27 hours', 100000, null, 'held') as s_closed \gset
select tests.create_booking(:'s_closed', :'captain', 'pending_payment', 1, 100000, 'pi_closed') as b_closed \gset
set local role service_role;
select * from public.complete_venue_booking('pi_closed') \gset
reset role;
set local role authenticated;
select tests.claims(:'owner');
select * from public.create_venue_closure(:'venue', :'court', :'d'::timestamptz + interval '26 hours', :'d'::timestamptz + interval '27 hours', 'Flood') \gset
reset role;
set local role service_role;
select coalesce(public.queue_venue_refund(:'b_closed', 100000, 'late_payment')::text, 'null') as q_closed \gset
reset role;
select is(:'q_closed'::text, 'null', 'venue_closure then late_payment: the late payment refund is refused (NULL)');
select results_eq(format('select reason, amount_cents from public.venue_refunds where booking_id = %L', :'b_closed'),
  $$values ('venue_closure'::text, 100000)$$, 'only the closure refund exists');

-- A captain's 0% cancel of a paid booking: no late payment refund either.
select tests.create_slot(:'venue', :'court', now() + interval '2 hours', now() + interval '3 hours', 100000, null, 'held') as s_zero \gset
select tests.create_booking(:'s_zero', :'captain', 'pending_payment', 1, 100000, 'pi_zero') as b_zero \gset
set local role service_role;
select * from public.complete_venue_booking('pi_zero') \gset
reset role;
set local role authenticated;
select tests.claims(:'captain');
select c.refund_amount_cents as zero_refund from public.cancel_venue_booking(:'b_zero', 'changed plans') c \gset
reset role;
set local role service_role;
select coalesce(public.queue_venue_refund(:'b_zero', 100000, 'late_payment')::text, 'null') as q_zero \gset
reset role;
select is(:'zero_refund'::int, 0, 'precondition: the cancel inside 24 hours refunded nothing');
select is(:'q_zero'::text, 'null', 'captain 0% cancel then late_payment: refused (NULL)');
select is((select count(*)::int from public.venue_refunds where booking_id = :'b_zero'), 0, 'nothing queued');

-- The cap itself: refunds of other reasons count against the total.
select tests.create_slot(:'venue', :'court', :'d'::timestamptz + interval '28 hours', :'d'::timestamptz + interval '29 hours', 100000) as s_cap \gset
select tests.create_booking(:'s_cap', :'captain', 'cancelled', 1, 100000, 'pi_cap') as b_cap \gset
set local role service_role;
select public.queue_venue_refund(:'b_cap', 100000, 'venue_closure') as cap_closure \gset
select throws_ok(format('select public.queue_venue_refund(%L, 100000, %L)', :'b_cap', 'late_payment'),
  '22023', null, 'venue_closure 100000 plus late_payment 100000 on a 100000 booking is rejected');
select throws_ok(format('select public.queue_venue_refund(%L, 1, %L)', :'b_cap', 'player_cancel'),
  '22023', null, 'even one more cent is rejected');
select is(public.queue_venue_refund(:'b_cap', 100000, 'venue_closure'), :'cap_closure'::uuid,
  'repeating the refund already queued still returns it');
reset role;
select tests.create_slot(:'venue', :'court', :'d'::timestamptz + interval '30 hours', :'d'::timestamptz + interval '31 hours', 100000) as s_split \gset
select tests.create_booking(:'s_split', :'captain', 'cancelled', 1, 100000, 'pi_split') as b_split \gset
set local role service_role;
select public.queue_venue_refund(:'b_split', 40000, 'player_cancel') \gset
select lives_ok(format('select public.queue_venue_refund(%L, 60000, %L)', :'b_split', 'venue_closure'),
  'refunds that add up to exactly the total are accepted');
reset role;
select is((select sum(amount_cents)::int from public.venue_refunds where booking_id = :'b_split'), 100000, 'and total the booking');

-- A shared tee time booking (walk up, no team).
select tests.create_slot(:'venue', :'course', :'d'::timestamptz + interval '10 hours', :'d'::timestamptz + interval '10 hours 10 minutes', 50000, 4) as s_tee \gset
select tests.create_booking(:'s_tee', :'captain', 'cancelled', 3, 150000, 'pi_tee') as b_tee \gset
set local role service_role;
select public.queue_venue_refund(:'b_tee', 150000, 'late_payment') \gset
reset role;
select results_eq(
  $$select team_id, amount_cents, (metadata->>'party_size')::int from public.transactions where gateway_ref = 'pi_tee'$$,
  $$values (null::uuid, 150000, 3)$$, 'tee time late payment: payment row without a team, with the party size');

-- Other reasons never write a payment row.
select tests.create_slot(:'venue', :'court', :'d'::timestamptz + interval '20 hours', :'d'::timestamptz + interval '21 hours', 80000) as s_other \gset
select tests.create_booking(:'s_other', :'captain', 'cancelled', 1, 80000, 'pi_other') as b_other \gset
set local role service_role;
select public.queue_venue_refund(:'b_other', 80000, 'venue_closure') \gset
reset role;
select is((select count(*)::int from public.transactions where gateway_ref = 'pi_other'), 0, 'a venue_closure refund writes no payment row');

-- No intent: the refund is queued, no row can be keyed.
select tests.create_slot(:'venue', :'court', :'d'::timestamptz + interval '22 hours', :'d'::timestamptz + interval '23 hours', 80000) as s_noint \gset
select tests.create_booking(:'s_noint', :'captain', 'cancelled', 1, 80000, null) as b_noint \gset
set local role service_role;
select public.queue_venue_refund(:'b_noint', 80000, 'late_payment') as r_noint \gset
reset role;
select isnt(:'r_noint'::text, null, 'a booking without an intent still queues');
select is((select count(*)::int from public.transactions where metadata->>'booking_id' = :'b_noint'), 0, 'with no payment row');

-- Unchanged contract: validation and grants.
set local role service_role;
select throws_ok(format('select public.queue_venue_refund(%L, 999999, %L)', :'b_late', 'late_payment'),
  '22023', null, 'still never more than the booking paid');
select throws_ok($$select public.queue_venue_refund(gen_random_uuid(), 100, 'late_payment')$$,
  'P0002', null, 'unknown booking still raises no_data_found');
reset role;
select is(has_function_privilege('authenticated', 'public.queue_venue_refund(uuid, int, text)', 'execute'), false,
  'authenticated still cannot execute');
select is(has_function_privilege('service_role', 'public.queue_venue_refund(uuid, int, text)', 'execute'), true,
  'service_role still can');

select * from finish();
rollback;
