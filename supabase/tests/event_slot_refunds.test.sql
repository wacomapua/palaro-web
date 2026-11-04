-- Event slot refunds (C12 c). A slot fee captured after the player's
-- event_slots row was released, deleted or taken over is refunded through the
-- same venue_refunds queue and processor:
--   * venue_refunds rows have a kind; event_slot rows carry the PayMongo
--     intent and the paying user instead of a booking.
--   * queue_event_slot_refund(_intent_id, _amount_cents, _user_id, _reason)
--     records the captured payment as the app's event slot payment row
--     (transactions type 'slot', as payments-create-intent writes it), then
--     queues the refund. Idempotent per (intent, reason).
--   * record_venue_refund_result records either kind; an event slot refund
--     writes the user's refund row and touches no booking.
begin;
select plan(52);

-- ---------------------------------------------------------------------------
-- Table shape.
-- ---------------------------------------------------------------------------
select has_column('public', 'venue_refunds', 'kind', 'venue_refunds.kind exists');
select col_type_is('public', 'venue_refunds', 'kind', 'text', 'kind is text');
select col_default_is('public', 'venue_refunds', 'kind', 'venue_booking', 'kind defaults to venue_booking');
select col_not_null('public', 'venue_refunds', 'kind', 'kind is required');
select col_is_null('public', 'venue_refunds', 'booking_id', 'booking_id is nullable');
select col_type_is('public', 'venue_refunds', 'paymongo_intent_id', 'text', 'paymongo_intent_id is text');
select col_type_is('public', 'venue_refunds', 'user_id', 'uuid', 'user_id is uuid');

select tests.create_user() as owner \gset
select tests.create_user() as player \gset
select tests.create_user() as other \gset
select tests.create_team(:'player') as team \gset
select tests.create_venue(:'owner') as venue \gset
select tests.create_court(:'venue', 'Court 1') as court \gset
select tests.create_slot(:'venue', :'court', now() + interval '2 days', now() + interval '2 days 1 hour') as slot \gset
select tests.create_booking(:'slot', :'player', 'cancelled', 1, 50000, 'pi_vb') as booking \gset

select throws_ok($$insert into public.venue_refunds (kind, amount_cents, reason) values ('venue_booking', 100, 'late_payment')$$,
  '23514', null, 'a venue_booking refund needs its booking');
select throws_ok(format($$insert into public.venue_refunds (kind, amount_cents, reason, user_id) values ('event_slot', 100, 'late_payment', %L)$$, :'player'),
  '23514', null, 'an event_slot refund needs its intent');
select throws_ok($$insert into public.venue_refunds (kind, amount_cents, reason, paymongo_intent_id) values ('event_slot', 100, 'late_payment', 'pi_x')$$,
  '23514', null, 'an event_slot refund needs its user');
select throws_ok(format($$insert into public.venue_refunds (kind, booking_id, amount_cents, reason, paymongo_intent_id, user_id) values ('event_slot', %L, 100, 'late_payment', 'pi_x', %L)$$, :'booking', :'player'),
  '23514', null, 'an event_slot refund has no booking');
select throws_ok($$insert into public.venue_refunds (kind, booking_id, amount_cents, reason) values ('court_hire', null, 100, 'late_payment')$$,
  '23514', null, 'kind is venue_booking or event_slot');
select throws_ok(format($$insert into public.venue_refunds (kind, amount_cents, reason, paymongo_intent_id, user_id) values ('event_slot', 100, 'venue_closure', 'pi_x', %L)$$, :'player'),
  '23514', null, 'an event slot is never refunded for a venue closure');

-- Venue refunds keep working unchanged and default to kind venue_booking.
set local role service_role;
select public.queue_venue_refund(:'booking', 50000, 'late_payment') as vb_refund \gset
reset role;
select results_eq(format('select kind, paymongo_intent_id, user_id from public.venue_refunds where id = %L', :'vb_refund'),
  $$values ('venue_booking'::text, null::text, null::uuid)$$, 'queue_venue_refund rows are venue_booking refunds');

-- ---------------------------------------------------------------------------
-- queue_event_slot_refund with the payment row payments-create-intent wrote.
-- ---------------------------------------------------------------------------
select tests.create_event(:'team', 2) as event \gset
insert into public.transactions (team_id, user_id, type, amount_cents, currency, platform_fee_cents, gateway, gateway_ref, status, metadata)
values (:'team', :'player', 'slot', 20000, 'PHP', 400, 'paymongo', 'pi_slot', 'pending',
        jsonb_build_object('slot_id', gen_random_uuid(), 'event_id', :'event', 'method', 'gcash'));

set local role service_role;
select public.queue_event_slot_refund('pi_slot', 20000, :'player', 'late_payment') as es_refund \gset
select public.queue_event_slot_refund('pi_slot', 20000, :'player', 'late_payment') as es_refund2 \gset
reset role;
select results_eq(
  format('select kind, booking_id, paymongo_intent_id, user_id, amount_cents, reason, status from public.venue_refunds where id = %L', :'es_refund'),
  format($$values ('event_slot'::text, null::uuid, 'pi_slot'::text, %L::uuid, 20000, 'late_payment'::text, 'pending'::text)$$, :'player'),
  'an event_slot refund is queued for the intent and its payer');
select is(:'es_refund2'::uuid, :'es_refund'::uuid, 'queueing again returns the same refund');
select is((select count(*)::int from public.venue_refunds where paymongo_intent_id = 'pi_slot'), 1, 'one refund row');
select results_eq(
  $$select type::text, status::text, team_id is not null, amount_cents, platform_fee_cents from public.transactions where gateway_ref = 'pi_slot'$$,
  $$values ('slot', 'succeeded', true, 20000, 400)$$,
  'the pending payment row is recorded as captured, otherwise unchanged');
select is((select count(*)::int from public.transactions where gateway_ref = 'pi_slot'), 1, 'still one transactions row for the intent');
-- The payment row names its refund (metadata.event_slot_refund_id), so the
-- captain's income screens, which cannot read the payer's refunds under RLS,
-- leave the refunded fee out; its other metadata is kept.
select is((select metadata->>'event_slot_refund_id' from public.transactions where gateway_ref = 'pi_slot'), :'es_refund'::text,
  'the payment row is marked with its refund id');
select is((select metadata->>'event_id' from public.transactions where gateway_ref = 'pi_slot'), :'event'::text,
  'and keeps its other metadata');

-- The unique (intent, reason) for event slot refunds holds in the table too.
select throws_ok(format($$insert into public.venue_refunds (kind, amount_cents, reason, paymongo_intent_id, user_id) values ('event_slot', 1, 'late_payment', 'pi_slot', %L)$$, :'player'),
  '23505', null, 'one event_slot refund per (intent, reason)');

-- No payment row at all: one is written for the captured payment.
set local role service_role;
select public.queue_event_slot_refund('pi_slot_bare', 15000, :'player', 'late_payment') as es_bare \gset
reset role;
select results_eq(
  $$select type::text, status::text, gateway::text, user_id, team_id, amount_cents, platform_fee_cents
      from public.transactions where gateway_ref = 'pi_slot_bare'$$,
  format($$values ('slot', 'succeeded', 'paymongo', %L::uuid, null::uuid, 15000, 0)$$, :'player'),
  'a missing payment row is written as a captured slot payment for the payer');
select is((select count(*)::int from public.venue_refunds where paymongo_intent_id = 'pi_slot_bare'), 1, 'and the refund is queued');
select is((select metadata->>'event_slot_refund_id' from public.transactions where gateway_ref = 'pi_slot_bare'), :'es_bare'::text,
  'the written payment row is marked with its refund id');

-- The webhook marks the payment row too (same key, same id): repeat calls
-- and an existing marker leave it as it is.
insert into public.transactions (team_id, user_id, type, amount_cents, gateway, gateway_ref, status, metadata)
values (:'team', :'player', 'slot', 30000, 'paymongo', 'pi_slot_marked', 'succeeded', '{"slot_id": "s-1"}');
set local role service_role;
select public.queue_event_slot_refund('pi_slot_marked', 30000, :'player', 'late_payment') as es_marked \gset
update public.transactions set metadata = metadata || jsonb_build_object('event_slot_refund_id', :'es_marked'::text)
 where gateway_ref = 'pi_slot_marked';
select public.queue_event_slot_refund('pi_slot_marked', 30000, :'player', 'late_payment') \gset
reset role;
select is((select metadata from public.transactions where gateway_ref = 'pi_slot_marked'),
  jsonb_build_object('slot_id', 's-1', 'event_slot_refund_id', :'es_marked'::text),
  'the marker is written once and agrees with the webhook''s');

-- Refunds for one intent never add up to more than it paid (review finding 1).
set local role service_role;
select throws_ok(format($$select public.queue_event_slot_refund('pi_slot', 1, %L, 'player_cancel')$$, :'player'),
  '22023', null, 'late_payment 20000 plus player_cancel 1 on a 20000 payment is rejected');
select public.queue_event_slot_refund('pi_slot_split', 12000, :'player', 'player_cancel') \gset
select throws_ok(format($$select public.queue_event_slot_refund('pi_slot_split', 1, %L, 'late_payment')$$, :'player'),
  '22023', null, 'a refund above what the intent''s payment row recorded is rejected');
reset role;

-- A failed payment row (an earlier attempt failed, a later one was captured).
insert into public.transactions (team_id, user_id, type, amount_cents, gateway, gateway_ref, status)
values (:'team', :'player', 'slot', 20000, 'paymongo', 'pi_slot_failed', 'failed');
set local role service_role;
select public.queue_event_slot_refund('pi_slot_failed', 20000, :'player', 'late_payment') \gset
reset role;
select is((select status::text from public.transactions where gateway_ref = 'pi_slot_failed'), 'succeeded',
  'a failed payment row is recorded as captured');

-- Bad input.
insert into public.transactions (user_id, type, amount_cents, gateway, gateway_ref, status)
values (:'player', 'venue_booking', 50000, 'paymongo', 'pi_vb_paid', 'succeeded');
set local role service_role;
select throws_ok(format($$select public.queue_event_slot_refund('pi_slot', 20001, %L, 'player_cancel')$$, :'player'),
  '22023', null, 'never more than the payment');
select throws_ok(format($$select public.queue_event_slot_refund('pi_slot', 100, %L, 'player_cancel')$$, :'other'),
  '22023', null, 'only the user who paid');
select throws_ok(format($$select public.queue_event_slot_refund('pi_vb_paid', 100, %L, 'late_payment')$$, :'player'),
  '22023', null, 'not for an intent that paid for a venue booking');
select throws_ok(format($$select public.queue_event_slot_refund(null, 100, %L, 'late_payment')$$, :'player'),
  '22023', null, 'an intent is required');
select throws_ok($$select public.queue_event_slot_refund('pi_x2', 100, null, 'late_payment')$$,
  '22023', null, 'a user is required');
select throws_ok(format($$select public.queue_event_slot_refund('pi_x3', 0, %L, 'late_payment')$$, :'player'),
  '23514', null, 'the amount must be positive');
select throws_ok(format($$select public.queue_event_slot_refund('pi_x4', 100, %L, 'venue_closure')$$, :'player'),
  '23514', null, 'the reason must fit an event slot');
reset role;
select is((select count(*)::int from public.transactions where gateway_ref in ('pi_x2', 'pi_x3', 'pi_x4')), 0,
  'a rejected call writes no payment row');

-- ---------------------------------------------------------------------------
-- Recording the outcome.
-- ---------------------------------------------------------------------------
set local role service_role;
select public.record_venue_refund_result(:'es_refund', true, 'ref_slot', null);
select public.record_venue_refund_result(:'es_refund', true, 'ref_slot', null);
reset role;
select results_eq(format('select status, paymongo_refund_id from public.venue_refunds where id = %L', :'es_refund'),
  $$values ('succeeded'::text, 'ref_slot'::text)$$, 'event slot refund recorded as succeeded');
select results_eq(
  $$select type::text, status::text, gateway::text, user_id, team_id, amount_cents, platform_fee_cents, currency
      from public.transactions where gateway_ref = 'ref_slot'$$,
  format($$values ('venue_refund', 'succeeded', 'paymongo', %L::uuid, null::uuid, 20000, 0, 'PHP')$$, :'player'),
  'one refund row for the user, no team');
select is((select metadata from public.transactions where gateway_ref = 'ref_slot'),
  jsonb_build_object('refund_id', :'es_refund'::uuid, 'kind', 'event_slot', 'reason', 'late_payment',
                     'intent_id', 'pi_slot', 'event_id', :'event'::uuid,
                     'slot_id', (select metadata->'slot_id' from public.transactions where gateway_ref = 'pi_slot')),
  'its metadata links the refund, intent, event and slot');
select is((select count(*)::int from public.transactions where gateway_ref = 'pi_slot'), 1,
  'the intent still resolves to one row (the payment)');

set local role service_role;
select public.record_venue_refund_result(:'es_bare', false, null, 'PayMongo 400: not refundable');
reset role;
select results_eq(format('select status, last_error from public.venue_refunds where id = %L', :'es_bare'),
  $$values ('failed'::text, 'PayMongo 400: not refundable'::text)$$, 'event slot failure recorded');
select is((select count(*)::int from public.transactions where type = 'venue_refund' and user_id = :'player'), 1,
  'a failure writes no refund row');

-- Venue booking refunds are recorded as before.
set local role service_role;
select public.record_venue_refund_result(:'vb_refund', true, 'ref_vb', null);
reset role;
select is((select refund_amount_cents from public.venue_bookings where id = :'booking'), 50000, 'venue booking refund still lands on the booking');
select is((select metadata->>'booking_id' from public.transactions where gateway_ref = 'ref_vb'), :'booking'::text,
  'and its refund row links the booking');

-- ---------------------------------------------------------------------------
-- RLS: the payer reads their own event slot refunds; nobody else does.
-- ---------------------------------------------------------------------------
set local role authenticated;
select tests.claims(:'player');
select is((select count(*)::int from public.venue_refunds where kind = 'event_slot'), 5, 'the payer sees their event slot refunds');
select tests.claims(:'other');
select is((select count(*)::int from public.venue_refunds where kind = 'event_slot'), 0, 'another user sees none');
select tests.claims(:'owner');
select is((select count(*)::int from public.venue_refunds where kind = 'event_slot'), 0, 'a venue owner sees none');
select throws_ok(format($$insert into public.venue_refunds (kind, amount_cents, reason, paymongo_intent_id, user_id) values ('event_slot', 1, 'player_cancel', 'pi_y', %L)$$, :'owner'),
  '42501', null, 'clients still cannot write refunds');
reset role;

-- Grants.
select is(has_function_privilege('anon', 'public.queue_event_slot_refund(text, int, uuid, text)', 'execute'), false, 'anon cannot queue');
select is(has_function_privilege('authenticated', 'public.queue_event_slot_refund(text, int, uuid, text)', 'execute'), false, 'authenticated cannot queue');
select is(has_function_privilege('service_role', 'public.queue_event_slot_refund(text, int, uuid, text)', 'execute'), true, 'service_role can queue');

select * from finish();
rollback;
