-- venue_refunds queue and queue_venue_refund (C1).
begin;
select plan(24);

select has_table('public', 'venue_refunds', 'venue_refunds exists');
select columns_are('public', 'venue_refunds', array[
  'id', 'booking_id', 'amount_cents', 'reason', 'status', 'paymongo_refund_id',
  'last_error', 'attempts', 'created_at', 'updated_at',
  'kind', 'paymongo_intent_id', 'user_id', 'next_attempt_at'], 'venue_refunds has exactly the contract columns (C1, C12 c, C13)');
select is((select relrowsecurity from pg_class where oid = 'public.venue_refunds'::regclass), true, 'RLS is on');

select is(has_function_privilege('anon', 'public.queue_venue_refund(uuid, int, text)', 'execute'), false,
  'anon cannot execute queue_venue_refund');
select is(has_function_privilege('authenticated', 'public.queue_venue_refund(uuid, int, text)', 'execute'), false,
  'authenticated cannot execute queue_venue_refund');
select is(has_function_privilege('service_role', 'public.queue_venue_refund(uuid, int, text)', 'execute'), true,
  'service_role can execute queue_venue_refund');
select is(
  (select count(*)::int from pg_proc p, aclexplode(p.proacl) a
    where p.oid = 'public.queue_venue_refund(uuid, int, text)'::regprocedure and a.grantee = 0),
  0, 'PUBLIC has no execute grant on queue_venue_refund');
select is((select prosecdef from pg_proc where oid = 'public.queue_venue_refund(uuid, int, text)'::regprocedure), true,
  'queue_venue_refund is SECURITY DEFINER');
select ok((select proconfig @> array['search_path=public'] from pg_proc where oid = 'public.queue_venue_refund(uuid, int, text)'::regprocedure),
  'queue_venue_refund pins search_path');

select tests.create_user() as owner \gset
select tests.create_user() as captain \gset
select tests.create_user() as stranger \gset
select tests.create_venue(:'owner') as venue \gset
select tests.create_court(:'venue', 'Court 1') as court \gset
select tests.create_slot(:'venue', :'court', now() + interval '2 days', now() + interval '2 days 1 hour') as slot \gset
select tests.create_booking(:'slot', :'captain', 'paid', 1, 80000) as booking \gset

set local role service_role;
select public.queue_venue_refund(:'booking', 80000, 'venue_closure') as r1 \gset
select public.queue_venue_refund(:'booking', 80000, 'venue_closure') as r2 \gset
reset role;
select is(:'r1'::uuid, :'r2'::uuid, 'queueing the same (booking, reason) twice returns the same id');
select is((select count(*)::int from public.venue_refunds where booking_id = :'booking'), 1, 'and stores one row');
select results_eq(
  format('select status, attempts, amount_cents from public.venue_refunds where id = %L', :'r1'),
  $$values ('pending'::text, 0, 80000)$$, 'a new refund is pending with no attempts');
select throws_ok(format('select public.queue_venue_refund(%L, 0, %L)', :'booking', 'late_payment'),
  '23514', null, 'amount must be positive');
select throws_ok(format('select public.queue_venue_refund(%L, 80001, %L)', :'booking', 'late_payment'),
  '22023', null, 'amount cannot exceed what the booking paid');
select throws_ok(format('select public.queue_venue_refund(%L, 100, %L)', :'booking', 'goodwill'),
  '23514', null, 'reason must be one of the contract reasons');

-- RLS: owner and captain read, nobody else; no client writes.
set local role authenticated;
select tests.claims(:'owner');
select is((select count(*)::int from public.venue_refunds), 1, 'venue owner sees the refund');
select tests.claims(:'captain');
select is((select count(*)::int from public.venue_refunds), 1, 'booking captain sees the refund');
select tests.claims(:'stranger');
select is((select count(*)::int from public.venue_refunds), 0, 'anyone else sees nothing');
select tests.claims(:'owner');
select throws_ok(format($$insert into public.venue_refunds (booking_id, amount_cents, reason) values (%L, 1, 'player_cancel')$$, :'booking'),
  '42501', null, 'owner cannot insert refunds');
select throws_ok($$update public.venue_refunds set status = 'succeeded'$$, '42501', null, 'owner cannot update refunds');
select throws_ok($$delete from public.venue_refunds$$, '42501', null, 'owner cannot delete refunds');
reset role;
select is((select status from public.venue_refunds where id = :'r1'), 'pending', 'owner update changed nothing');
select is((select count(*)::int from public.venue_refunds where id = :'r1'), 1, 'owner delete changed nothing');
set local role anon;
select tests.claims(null, 'anon');
select throws_ok('select count(*) from public.venue_refunds', '42501', null, 'anon cannot read refunds at all');
reset role;

select * from finish();
rollback;
