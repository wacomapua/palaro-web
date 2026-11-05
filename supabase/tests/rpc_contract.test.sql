-- Every RPC the team-manager app and edge functions call (origin/feat/quick-wins)
-- exists once, with the argument names and types the caller sends, the return
-- shape it reads, and exactly the execute grants its caller needs. The app
-- calls with the anon or authenticated key; edge functions use the service
-- role. Call sites:
--   venue_slots_remaining       src/hooks/queries/slotRemaining.ts:12 (via src/lib/slotAvailability.ts:33)
--   book_venue_slot             supabase/functions/payments-create-intent/index.ts:125
--                               (C14: _holes int default 18 is the 7th argument)
--   complete_venue_booking      payments-create-intent/index.ts:178, payments-webhook/index.ts:338
--   release_held_booking_admin  payments-create-intent/index.ts:239, payments-webhook/index.ts:371
--   reinstate_venue_booking     payments-webhook/index.ts:280
--   queue_venue_refund          payments-webhook/index.ts:287
--   record_venue_refund_result  payments-process-refunds/index.ts:165
--   queue_event_slot_refund     payments-webhook (C12 d, being written against this signature)
--   record_venue_refund_submitted payments-process-refunds (C13, being written against this signature)
-- payments-process-refunds also reads venue_refunds directly (listCandidates,
-- claim): the columns it selects and the booking embed must keep working.
begin;
select plan(89);

create temp table rpc_contract (fn text, args text, result text, client boolean) on commit drop;
insert into rpc_contract values
  ('venue_slots_remaining', '_slot_ids uuid[]', 'TABLE(slot_id uuid, remaining integer)', true),
  ('book_venue_slot',
   '_slot_id uuid, _captain_user_id uuid, _team_id uuid, _party_size integer, _hold_minutes integer, _platform_fee_pct numeric, _holes integer',
   'TABLE(booking_id uuid, slot_id uuid, total_cents integer, platform_fee_cents integer, payout_cents integer, currency text, party_size integer)',
   false),
  ('complete_venue_booking', '_intent_id text', 'TABLE(booking_id uuid, event_id uuid, status venue_booking_status)', false),
  ('release_held_booking_admin', '_booking_id uuid, _reason text', 'void', false),
  ('reinstate_venue_booking', '_intent_id text', 'venue_bookings', false),
  ('queue_venue_refund', '_booking_id uuid, _amount_cents integer, _reason text', 'uuid', false),
  ('record_venue_refund_result', '_refund_id uuid, _succeeded boolean, _paymongo_refund_id text, _error text', 'void', false),
  ('queue_event_slot_refund', '_intent_id text, _amount_cents integer, _user_id uuid, _reason text', 'uuid', false),
  ('record_venue_refund_submitted', '_refund_id uuid, _paymongo_refund_id text', 'void', false);

create temp view rpc_found as
  select c.*, (select p.oid from pg_proc p
                where p.pronamespace = 'public'::regnamespace and p.proname = c.fn
                order by p.oid limit 1) as oid
    from rpc_contract c;

select is((select count(*)::int from pg_proc p where p.pronamespace = 'public'::regnamespace and p.proname = f.fn), 1,
          f.fn || ': exactly one public function, so PostgREST resolves named arguments without ambiguity')
  from rpc_found f order by f.fn;

select is(pg_get_function_identity_arguments(f.oid), f.args, f.fn || ': argument names and types match the caller')
  from rpc_found f order by f.fn;

select is(pg_get_function_result(f.oid), f.result, f.fn || ': return shape matches what the caller reads')
  from rpc_found f order by f.fn;

select is(has_function_privilege('anon', f.oid, 'execute'), f.client,
          f.fn || case when f.client then ': anon can execute' else ': anon cannot execute' end)
  from rpc_found f order by f.fn;

select is(has_function_privilege('authenticated', f.oid, 'execute'), f.client,
          f.fn || case when f.client then ': authenticated can execute' else ': authenticated cannot execute' end)
  from rpc_found f order by f.fn;

select is(has_function_privilege('service_role', f.oid, 'execute'), true, f.fn || ': service_role can execute')
  from rpc_found f order by f.fn;

select is((select count(*)::int from pg_proc p, aclexplode(p.proacl) a where p.oid = f.oid and a.grantee = 0), 0,
          f.fn || ': PUBLIC has no execute grant')
  from rpc_found f order by f.fn;

select ok(coalesce((select p.prosecdef and p.proconfig @> array['search_path=public'] from pg_proc p where p.oid = f.oid), false),
          f.fn || ': SECURITY DEFINER with search_path pinned to public')
  from rpc_found f order by f.fn;

-- The grants hold for real calls, not just in the catalog.
set local role anon;
select throws_ok($$select * from public.book_venue_slot(gen_random_uuid(), gen_random_uuid(), null)$$,
  '42501', null, 'anon calling book_venue_slot is refused');
select throws_ok($$select public.queue_venue_refund(gen_random_uuid(), 1, 'late_payment')$$,
  '42501', null, 'anon calling queue_venue_refund is refused');
select throws_ok($$select * from public.reinstate_venue_booking('pi_x')$$,
  '42501', null, 'anon calling reinstate_venue_booking is refused');
select throws_ok($$select public.record_venue_refund_result(gen_random_uuid(), true, 'ref_x', null)$$,
  '42501', null, 'anon calling record_venue_refund_result is refused');
select throws_ok($$select public.queue_event_slot_refund('pi_x', 1, gen_random_uuid(), 'late_payment')$$,
  '42501', null, 'anon calling queue_event_slot_refund is refused');
select throws_ok($$select public.record_venue_refund_submitted(gen_random_uuid(), 'ref_x')$$,
  '42501', null, 'anon calling record_venue_refund_submitted is refused');
reset role;

set local role authenticated;
select tests.claims(gen_random_uuid());
select throws_ok($$select * from public.book_venue_slot(gen_random_uuid(), gen_random_uuid(), null)$$,
  '42501', null, 'authenticated calling book_venue_slot is refused');
select throws_ok($$select public.queue_venue_refund(gen_random_uuid(), 1, 'late_payment')$$,
  '42501', null, 'authenticated calling queue_venue_refund is refused');
select throws_ok($$select * from public.reinstate_venue_booking('pi_x')$$,
  '42501', null, 'authenticated calling reinstate_venue_booking is refused');
select throws_ok($$select public.record_venue_refund_result(gen_random_uuid(), true, 'ref_x', null)$$,
  '42501', null, 'authenticated calling record_venue_refund_result is refused');
select throws_ok($$select public.queue_event_slot_refund('pi_x', 1, gen_random_uuid(), 'late_payment')$$,
  '42501', null, 'authenticated calling queue_event_slot_refund is refused');
select throws_ok($$select public.record_venue_refund_submitted(gen_random_uuid(), 'ref_x')$$,
  '42501', null, 'authenticated calling record_venue_refund_submitted is refused');
reset role;

-- venue_refunds as payments-process-refunds reads it (listCandidates select,
-- including the booking embed, which needs the booking_id foreign key).
select fk_ok('public', 'venue_refunds', 'booking_id', 'public', 'venue_bookings', 'id',
  'venue_refunds.booking_id references venue_bookings, so the booking embed resolves');
select lives_ok($$select r.id, r.kind, r.booking_id, r.paymongo_intent_id, r.paymongo_refund_id, r.request_key,
                         r.user_id, r.amount_cents, r.reason, r.status, r.attempts, r.updated_at, r.last_error,
                         r.next_attempt_at, b.paymongo_intent_id
                    from public.venue_refunds r left join public.venue_bookings b on b.id = r.booking_id limit 0$$,
  'every venue_refunds column the processor reads exists, event slot columns and request_key included');

-- C13: the claim update stores the Idempotency-Key it will send
-- (<refund id>:<attempts>) in request_key, and a stale processing reclaim
-- resends the stored key. Nullable: rows claimed before it existed have none.
select has_column('public', 'venue_refunds', 'request_key', 'venue_refunds.request_key exists');
select col_type_is('public', 'venue_refunds', 'request_key', 'text', 'venue_refunds.request_key is text');
select col_is_null('public', 'venue_refunds', 'request_key', 'venue_refunds.request_key is nullable');

select * from finish();
rollback;
