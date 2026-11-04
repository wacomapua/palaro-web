-- Refund lifecycle (C13): a failed refund is retried with exponential
-- backoff (next_attempt_at, set by record_venue_refund_result), and a refund
-- PayMongo accepted but has not finished is 'submitted'
-- (record_venue_refund_submitted) until the processor polls it to succeeded
-- or failed. Scheduling: cron_jobs.test.sql.
begin;
select plan(26);

select has_column('public', 'venue_refunds', 'next_attempt_at', 'venue_refunds.next_attempt_at exists');
select col_type_is('public', 'venue_refunds', 'next_attempt_at', 'timestamp with time zone', 'next_attempt_at is timestamptz');
select col_not_null('public', 'venue_refunds', 'next_attempt_at', 'next_attempt_at is required');
select col_default_is('public', 'venue_refunds', 'next_attempt_at', 'now()', 'next_attempt_at defaults to now()');

select tests.create_user() as owner \gset
select tests.create_user() as captain \gset
select tests.create_venue(:'owner') as venue \gset
select tests.create_court(:'venue', 'Court 1') as court \gset
create function pg_temp.refund(_n int) returns uuid language plpgsql as $$
declare _slot uuid; _b uuid; _r uuid;
begin
  _slot := tests.create_slot(current_setting('t.venue')::uuid, current_setting('t.court')::uuid,
                             now() + make_interval(days => 3, hours => _n), now() + make_interval(days => 3, hours => _n + 1));
  _b := tests.create_booking(_slot, current_setting('t.captain')::uuid, 'cancelled', 1, 100000, 'pi_life_' || _n);
  insert into public.venue_refunds (booking_id, amount_cents, reason) values (_b, 100000, 'late_payment') returning id into _r;
  return _r;
end $$;
select set_config('t.venue', :'venue', true) as cfg1, set_config('t.court', :'court', true) as cfg2, set_config('t.captain', :'captain', true) as cfg3 \gset

select pg_temp.refund(1) as r1 \gset
select is((select next_attempt_at from public.venue_refunds where id = :'r1'), now(), 'a new refund is due at once');

-- ---------------------------------------------------------------------------
-- Backoff: now() + 5 minutes * 2^(attempts - 1) after each failure.
-- ---------------------------------------------------------------------------
select pg_temp.refund(2) as r2 \gset
select pg_temp.refund(3) as r3 \gset
select pg_temp.refund(4) as r4 \gset
update public.venue_refunds set status = 'processing', attempts = 1 where id = :'r1';
update public.venue_refunds set status = 'processing', attempts = 2 where id = :'r2';
update public.venue_refunds set status = 'processing', attempts = 3 where id = :'r3';
update public.venue_refunds set status = 'processing', attempts = 8 where id = :'r4';
set local role service_role;
select public.record_venue_refund_result(:'r1', false, null, 'PayMongo 500');
select public.record_venue_refund_result(:'r2', false, null, 'PayMongo 500');
select public.record_venue_refund_result(:'r3', false, null, 'PayMongo 500');
select public.record_venue_refund_result(:'r4', false, null, 'attempts exhausted: PayMongo 500');
reset role;
select results_eq(format('select status, attempts, next_attempt_at - now() from public.venue_refunds where id = %L', :'r1'),
  $$values ('failed'::text, 1, interval '5 minutes')$$, 'first failure: retry in 5 minutes');
select is((select next_attempt_at - now() from public.venue_refunds where id = :'r2'), interval '10 minutes', 'second: 10 minutes');
select is((select next_attempt_at - now() from public.venue_refunds where id = :'r3'), interval '20 minutes', 'third: 20 minutes');
select is((select next_attempt_at - now() from public.venue_refunds where id = :'r4'), interval '640 minutes', 'eighth (the cap): 640 minutes');
select ok((select sum(interval '5 minutes' * power(2, n - 1)) from generate_series(1, 7) n) < interval '24 hours',
  'seven retries fit inside PayMongo''s 24 hour idempotency key lifetime');

-- ---------------------------------------------------------------------------
-- Submitted: PayMongo accepted the refund, it is still pending there.
-- ---------------------------------------------------------------------------
select pg_temp.refund(5) as r5 \gset
update public.venue_refunds set status = 'processing', attempts = 1, last_error = 'old' where id = :'r5';
set local role service_role;
select public.record_venue_refund_submitted(:'r5', 'ref_pending_5');
reset role;
select results_eq(format('select status, paymongo_refund_id, last_error from public.venue_refunds where id = %L', :'r5'),
  $$values ('submitted'::text, 'ref_pending_5'::text, null::text)$$, 'submitted: status and PayMongo id stored');
select is((select count(*)::int from public.transactions where gateway_ref = 'ref_pending_5'), 0, 'no refund row before it succeeds');
select is((select refunded_at from public.venue_bookings b join public.venue_refunds r on r.booking_id = b.id where r.id = :'r5'), null,
  'and the booking is not marked refunded yet');
set local role service_role;
select public.record_venue_refund_submitted(:'r5', 'ref_pending_5');
reset role;
select results_eq(format('select status, paymongo_refund_id, attempts from public.venue_refunds where id = %L', :'r5'),
  $$values ('submitted'::text, 'ref_pending_5'::text, 1)$$, 'a repeat is a no op');

-- The poll finds it succeeded.
set local role service_role;
select public.record_venue_refund_result(:'r5', true, 'ref_pending_5', null);
select public.record_venue_refund_submitted(:'r5', 'ref_pending_5');
reset role;
select is((select status from public.venue_refunds where id = :'r5'), 'succeeded', 'submitted then succeeded');
select is((select count(*)::int from public.transactions where gateway_ref = 'ref_pending_5'), 1, 'with its refund row');
select is((select status from public.venue_refunds where id = :'r5'), 'succeeded', 'a late submitted never downgrades a success');

-- The poll finds it failed.
select pg_temp.refund(6) as r6 \gset
update public.venue_refunds set status = 'processing', attempts = 2 where id = :'r6';
set local role service_role;
select public.record_venue_refund_submitted(:'r6', 'ref_pending_6');
select public.record_venue_refund_result(:'r6', false, null, 'PayMongo refund ref_pending_6 failed');
reset role;
select results_eq(format('select status, last_error, next_attempt_at - now() from public.venue_refunds where id = %L', :'r6'),
  $$values ('failed'::text, 'PayMongo refund ref_pending_6 failed'::text, interval '10 minutes')$$,
  'submitted then failed: retried with backoff');

-- Event slot refunds go through the same states.
insert into public.transactions (user_id, type, amount_cents, gateway, gateway_ref, status)
values (:'captain', 'slot', 20000, 'paymongo', 'pi_life_slot', 'succeeded');
set local role service_role;
select public.queue_event_slot_refund('pi_life_slot', 20000, :'captain', 'late_payment') as r7 \gset
select public.record_venue_refund_submitted(:'r7', 'ref_pending_7');
reset role;
select is((select status from public.venue_refunds where id = :'r7'), 'submitted', 'an event slot refund can be submitted');

-- Bad input.
set local role service_role;
select throws_ok(format('select public.record_venue_refund_submitted(%L, null)', :'r6'), '22023', null, 'a PayMongo refund id is required');
select throws_ok(format($$select public.record_venue_refund_submitted(%L, '  ')$$, :'r6'), '22023', null, 'and may not be blank');
select throws_ok($$select public.record_venue_refund_submitted(gen_random_uuid(), 'ref_x')$$, 'P0002', null, 'unknown refund raises no_data_found');
reset role;

-- The status check takes 'submitted' and nothing new besides.
select lives_ok(format($$update public.venue_refunds set status = 'submitted' where id = %L$$, :'r1'), 'status may be submitted');
select throws_ok(format($$update public.venue_refunds set status = 'queued' where id = %L$$, :'r1'), '23514', null, 'other statuses are still refused');

select is(has_function_privilege('authenticated', 'public.record_venue_refund_submitted(uuid, text)', 'execute'), false,
  'authenticated cannot record a submission');
select is(has_function_privilege('service_role', 'public.record_venue_refund_submitted(uuid, text)', 'execute'), true,
  'service_role can');

select * from finish();
rollback;
