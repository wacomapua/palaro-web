-- record_venue_refund_result (C10): payments-process-refunds records each
-- PayMongo outcome through it. Success marks the refund succeeded, sets the
-- booking's refunded amount and time, and writes one venue_refund
-- transactions row that the player's receipts list; a repeat is a no op.
-- Failure marks the refund failed with the error.
begin;
select plan(27);

select tests.create_user() as owner \gset
select tests.create_user() as captain \gset
select tests.create_user() as stranger \gset
select tests.create_team(:'captain') as team \gset
select tests.create_venue(:'owner') as venue \gset
select tests.create_court(:'venue', 'Court 1') as court \gset
select date_trunc('hour', now()) + interval '4 days' as d \gset

-- A booking paid through the normal path (venue_booking transactions row),
-- then cancelled by a venue closure with a full refund queued.
select tests.create_slot(:'venue', :'court', :'d'::timestamptz + interval '10 hours', :'d'::timestamptz + interval '11 hours', 120000, null, 'held') as slot \gset
select tests.create_booking(:'slot', :'captain', 'pending_payment', 1, 120000, 'pi_paid') as booking \gset
update public.venue_bookings set team_id = :'team' where id = :'booking';
set local role service_role;
select * from public.complete_venue_booking('pi_paid') \gset
reset role;
set local role authenticated;
select tests.claims(:'owner');
select * from public.create_venue_closure(:'venue', :'court', :'d'::timestamptz + interval '9 hours', :'d'::timestamptz + interval '12 hours', 'Flooding') \gset
reset role;
select id as refund from public.venue_refunds where booking_id = :'booking' and reason = 'venue_closure' \gset
select is((select refund_amount_cents from public.venue_bookings where id = :'booking'), 120000,
  'precondition: the closure already set the booking''s refund amount to the total');

-- Success.
set local role service_role;
select public.record_venue_refund_result(:'refund', true, 'ref_abc123', null);
reset role;
select results_eq(format('select status, paymongo_refund_id, last_error from public.venue_refunds where id = %L', :'refund'),
  $$values ('succeeded'::text, 'ref_abc123'::text, null::text)$$, 'success: the refund is succeeded with the PayMongo id');
select is((select refund_amount_cents from public.venue_bookings where id = :'booking'), 120000,
  'the booking''s refunded amount is set to the refund, not added to what the closure wrote');
select isnt((select refunded_at from public.venue_bookings where id = :'booking'), null, 'the refunded time is recorded');
select refunded_at as first_refunded_at from public.venue_bookings where id = :'booking' \gset
select is((select count(*)::int from public.transactions where type = 'venue_refund' and metadata->>'refund_id' = :'refund'), 1,
  'one venue_refund transactions row');
select results_eq(
  format($$select user_id, team_id, amount_cents, platform_fee_cents, currency, gateway::text, gateway_ref, status::text
             from public.transactions where type = 'venue_refund' and metadata->>'refund_id' = %L$$, :'refund'),
  format($$values (%L::uuid, null::uuid, 120000, 0, 'PHP', 'paymongo', 'ref_abc123', 'succeeded')$$, :'captain'),
  'refund row: the captain''s, the refunded amount in the venue currency, keyed by the PayMongo refund id');
select is((select metadata from public.transactions where type = 'venue_refund' and metadata->>'refund_id' = :'refund'),
  jsonb_build_object('refund_id', :'refund'::uuid, 'booking_id', :'booking'::uuid, 'reason', 'venue_closure',
                     'intent_id', 'pi_paid', 'slot_id', :'slot'::uuid, 'venue_id', :'venue'::uuid, 'court_id', :'court'::uuid),
  'refund row metadata links the refund, booking, intent, slot, venue and court');
-- payments-webhook looks transactions up by gateway_ref = intent id with
-- maybeSingle(); the refund row must not make that lookup ambiguous.
select is((select count(*)::int from public.transactions where gateway_ref = 'pi_paid'), 1,
  'the intent id still matches only the original payment row');

-- The player's receipts (useMyTransactions: own rows, newest first) show the
-- payment and the refund; nobody else sees them.
set local role authenticated;
select tests.claims(:'captain');
select results_eq(
  format($$select type::text, amount_cents, status::text from public.transactions where user_id = %L order by type::text$$, :'captain'),
  $$values ('venue_booking', 120000, 'succeeded'), ('venue_refund', 120000, 'succeeded')$$,
  'receipts: the captain sees the booking payment and the refund');
select tests.claims(:'stranger');
select is((select count(*)::int from public.transactions where type = 'venue_refund'), 0, 'a stranger sees no refund rows');
-- The venue's next payout (palaro-web payouts page) no longer counts it.
select tests.claims(:'owner');
select is((select coalesce(sum(payout_cents), 0)::int from public.venue_bookings
            where venue_id = :'venue' and status = 'paid' and payout_id is null), 0,
  'payouts: the refunded booking is not in the venue''s next payout');
select is((select refund_amount_cents from public.venue_bookings where id = :'booking'), 120000,
  'bookings page: the owner sees the refunded amount');
reset role;

-- A repeat success is a no op.
set local role service_role;
select public.record_venue_refund_result(:'refund', true, 'ref_abc123', null);
select public.record_venue_refund_result(:'refund', true, 'ref_other', null);
reset role;
select is((select count(*)::int from public.transactions where type = 'venue_refund' and metadata->>'refund_id' = :'refund'), 1,
  'repeat success: still one transactions row');
select is((select paymongo_refund_id from public.venue_refunds where id = :'refund'), 'ref_abc123', 'the first PayMongo id stays');
select results_eq(format('select refund_amount_cents, refunded_at from public.venue_bookings where id = %L', :'booking'),
  format('values (120000, %L::timestamptz)', :'first_refunded_at'), 'booking refund columns unchanged');

-- A late failure never downgrades a recorded success.
set local role service_role;
select public.record_venue_refund_result(:'refund', false, null, 'PayMongo 500');
reset role;
select results_eq(format('select status, last_error from public.venue_refunds where id = %L', :'refund'),
  $$values ('succeeded'::text, null::text)$$, 'failure after success is ignored');

-- ---------------------------------------------------------------------------
-- Failure, then a successful retry (late payment refund).
-- ---------------------------------------------------------------------------
select tests.create_slot(:'venue', :'court', :'d'::timestamptz + interval '14 hours', :'d'::timestamptz + interval '15 hours', 90000) as slot2 \gset
select tests.create_booking(:'slot2', :'captain', 'cancelled', 1, 90000, 'pi_late') as booking2 \gset
set local role service_role;
select public.queue_venue_refund(:'booking2', 90000, 'late_payment') as refund2 \gset
update public.venue_refunds set status = 'processing', attempts = 1 where id = :'refund2';
select public.record_venue_refund_result(:'refund2', false, null, 'PayMongo 400: payment not refundable');
reset role;
select results_eq(format('select status, last_error, attempts from public.venue_refunds where id = %L', :'refund2'),
  $$values ('failed'::text, 'PayMongo 400: payment not refundable'::text, 1)$$,
  'failure: the refund is failed with the error (attempts are the claim''s business)');
select results_eq(format('select refund_amount_cents, refunded_at from public.venue_bookings where id = %L', :'booking2'),
  $$values (0, null::timestamptz)$$, 'failure leaves the booking''s refund columns alone');
select is((select count(*)::int from public.transactions where metadata->>'refund_id' = :'refund2'), 0,
  'failure writes no transactions row');

set local role service_role;
update public.venue_refunds set status = 'processing', attempts = 2 where id = :'refund2';
select public.record_venue_refund_result(:'refund2', true, 'mock_ref_' || :'refund2', null);
reset role;
select results_eq(format('select status, last_error from public.venue_refunds where id = %L', :'refund2'),
  $$values ('succeeded'::text, null::text)$$, 'a retry that succeeds is recorded and clears the error');
select is((select refund_amount_cents from public.venue_bookings where id = :'booking2'), 90000,
  'late payment refund: booking refunded amount set');
select results_eq(
  format($$select team_id, amount_cents, gateway_ref, metadata->>'reason' from public.transactions where metadata->>'refund_id' = %L$$, :'refund2'),
  format($$values (null::uuid, 90000, %L, 'late_payment')$$, 'mock_ref_' || :'refund2'),
  'late payment refund: one transactions row');

-- Bad input.
set local role service_role;
select throws_ok(format('select public.record_venue_refund_result(%L, true, null, null)', :'refund2'),
  '22023', null, 'success without a PayMongo refund id is rejected');
select throws_ok(format($$select public.record_venue_refund_result(%L, true, '  ', null)$$, :'refund2'),
  '22023', null, 'success with a blank PayMongo refund id is rejected');
select throws_ok($$select public.record_venue_refund_result(gen_random_uuid(), false, null, 'x')$$,
  'P0002', null, 'unknown refund id raises no_data_found');
select throws_ok(format('select public.record_venue_refund_result(%L, null, null, null)', :'refund2'),
  '22023', null, 'a NULL outcome is rejected');
reset role;

select is((select count(*)::int from public.transactions where type = 'venue_refund' and user_id = :'captain'), 2,
  'two refunds, two refund rows in total');

select * from finish();
rollback;
