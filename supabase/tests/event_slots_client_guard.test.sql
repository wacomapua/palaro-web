-- event_slots client guard (PR #11 review). Since 0002, slots_claim and
-- slots_update let a member (or a captain) insert or update a row with any
-- column values through PostgREST, so a player could take a seat as 'paid'
-- without paying, and could move an old row (with its old created_at) into
-- another event or back out of 'released' to jump the reserve queue. For
-- anon and authenticated, one BEFORE trigger now refuses:
--   * inserting a row as 'paid' or with paid_at;
--   * changing status to 'paid', or setting or changing paid_at to a value;
--   * changing event_id or user_id;
-- and stamps created_at with now() on insert and when a released row comes
-- back (refusing any client write of created_at). postgres, service_role
-- (payments-webhook marks slots paid) and SECURITY DEFINER functions owned
-- by postgres (reserve promotion) are not limited.
-- Every write the team-manager app makes as authenticated (79082c3) must
-- still work: useSlotPayment insert, reclaim (reserved or released back to
-- reserved, paid_at null), rollback (to released), delete of its own
-- released row; useReleaseSlot (released, paid_at null) by the player or by
-- the captain on someone else's slot.
begin;
select plan(41);

-- ---------------------------------------------------------------------------
-- 0. One guard, running as the caller.
-- ---------------------------------------------------------------------------
select is((select array_agg(t.tgname::text order by t.tgname)
             from pg_trigger t
            where t.tgrelid = 'public.event_slots'::regclass
              and not t.tgisinternal
              and (t.tgtype & 2) = 2),
  array['event_slots_client_guard'],
  'event_slots has exactly one BEFORE trigger, the client guard');
create temp view guard_fn as
  select p.* from pg_proc p
   where p.pronamespace = 'public'::regnamespace and p.proname = 'event_slots_client_guard' and p.pronargs = 0;
select ok(coalesce((select not g.prosecdef and g.proconfig @> array['search_path=public'] from guard_fn g), false),
  'the guard is SECURITY INVOKER (current_user is the caller) with search_path pinned');
select ok(coalesce((select not has_function_privilege('authenticated', g.oid, 'execute') from guard_fn g), false),
  'clients cannot call the guard function directly');

select tests.create_user() as captain \gset
select tests.create_team(:'captain') as team \gset
create temp table u (n int primary key, id uuid) on commit drop;
insert into u select i, tests.create_user() from generate_series(1, 12) i;
select tests.add_member(:'team', id) from u;
select id as m1 from u where n = 1 \gset
select id as m2 from u where n = 2 \gset
select id as m3 from u where n = 3 \gset
select id as m4 from u where n = 4 \gset
select id as m5 from u where n = 5 \gset
select id as m6 from u where n = 6 \gset
select id as m7 from u where n = 7 \gset
select id as m8 from u where n = 8 \gset
select id as m9 from u where n = 9 \gset
select id as m10 from u where n = 10 \gset
select id as m11 from u where n = 11 \gset
select id as m12 from u where n = 12 \gset

select tests.create_event(:'team', 6) as ins \gset
select tests.create_event(:'team', 6) as ev \gset
select tests.create_event(:'team', 6) as other \gset
-- One seat, taken: reserve rows here stay reserves.
select tests.create_event(:'team', 1) as r \gset
select tests.create_event_slot(:'r', :'m1', 'confirmed', 1, 'paid') \gset

-- ---------------------------------------------------------------------------
-- 1. Nobody pays through PostgREST.
-- ---------------------------------------------------------------------------
set local role authenticated;
select tests.claims(:'m1');
select throws_ok(format($$insert into public.event_slots (event_id, user_id, slot_type, position, status)
                          values (%L, %L, 'confirmed', 1, 'paid')$$, :'ins', :'m1'),
  '42501', null, 'a member cannot insert their own row as paid');
select tests.claims(:'m2');
select throws_ok(format($$insert into public.event_slots (event_id, user_id, slot_type, position, status, paid_at)
                          values (%L, %L, 'confirmed', 2, 'reserved', now())$$, :'ins', :'m2'),
  '42501', null, 'a member cannot insert their own row with paid_at');
select tests.claims(:'captain');
select throws_ok(format($$insert into public.event_slots (event_id, user_id, slot_type, position, status, paid_at)
                          values (%L, %L, 'confirmed', 3, 'paid', now())$$, :'ins', :'m3'),
  '42501', null, 'a captain cannot insert a paid row for a member');
reset role;
select is((select count(*)::int from public.event_slots where event_id = :'ins'), 0, 'no paid row was taken');

select tests.create_event_slot(:'ev', :'m4', 'confirmed', 1) as held \gset
select tests.create_event_slot(:'ev', :'m5', 'confirmed', 2, 'paid') as paid_row \gset
update public.event_slots set paid_at = now() - interval '1 hour' where id = :'paid_row';
select tests.create_event_slot(:'ev', :'m6', 'confirmed', 3) as held2 \gset

set local role authenticated;
select tests.claims(:'m4');
select throws_ok(format($$update public.event_slots set status = 'paid', paid_at = now() where id = %L$$, :'held'),
  '42501', null, 'a member cannot mark their own hold paid');
select throws_ok(format($$update public.event_slots set status = 'paid' where id = %L$$, :'held'),
  '42501', null, 'a member cannot set status paid without paid_at either');
select throws_ok(format($$update public.event_slots set paid_at = now() where id = %L$$, :'held'),
  '42501', null, 'a member cannot set paid_at on their hold');
select tests.claims(:'m5');
select throws_ok(format($$update public.event_slots set paid_at = now() + interval '1 day' where id = %L$$, :'paid_row'),
  '42501', null, 'a member cannot change paid_at on their paid row');
select tests.claims(:'captain');
select throws_ok(format($$update public.event_slots set status = 'paid', paid_at = now() where id = %L$$, :'held2'),
  '42501', null, 'a captain cannot mark a member''s hold paid');
reset role;
select results_eq(format($$select status::text, paid_at is null from public.event_slots where id in (%L, %L) order by position$$, :'held', :'held2'),
  $$values ('reserved', true), ('reserved', true)$$, 'both holds are still unpaid');
select is((select paid_at from public.event_slots where id = :'paid_row'), now() - interval '1 hour', 'the paid row keeps its paid_at');

-- payments-webhook (service role) is the one that marks a slot paid.
set local role service_role;
select lives_ok(format($$update public.event_slots set status = 'paid', paid_at = now() where id = %L$$, :'held2'),
  'the service role marks a slot paid');
reset role;
select is((select status::text from public.event_slots where id = :'held2'), 'paid', 'and it is paid');

-- ---------------------------------------------------------------------------
-- 2. A row stays in its event and with its player.
-- ---------------------------------------------------------------------------
set local role authenticated;
select tests.claims(:'m4');
select throws_ok(format($$update public.event_slots set event_id = %L where id = %L$$, :'other', :'held'),
  '42501', null, 'a member cannot move their row into another event');
select throws_ok(format($$update public.event_slots set status = 'released', event_id = %L, position = 6 where id = %L$$, :'other', :'held'),
  '42501', null, 'not even while releasing it');
select tests.claims(:'captain');
select throws_ok(format($$update public.event_slots set user_id = %L where id = %L$$, :'m7', :'held'),
  '42501', null, 'a captain cannot hand a member''s row to another player');
select throws_ok(format($$update public.event_slots set event_id = %L where id = %L$$, :'other', :'held'),
  '42501', null, 'nor move it into another event');
reset role;
select results_eq(format($$select event_id, user_id, status::text from public.event_slots where id = %L$$, :'held'),
  format($$values (%L::uuid, %L::uuid, 'reserved')$$, :'ev', :'m4'), 'the row is where it was');

-- ---------------------------------------------------------------------------
-- 3. Every write the app makes as authenticated still works.
-- ---------------------------------------------------------------------------
-- useSlotPayment insert (a confirmed tile, and a reserve tile).
set local role authenticated;
select tests.claims(:'m8');
select lives_ok(format($$insert into public.event_slots (event_id, user_id, slot_type, position, status)
                         values (%L, %L, 'confirmed', 4, 'reserved')$$, :'ev', :'m8'),
  'app: a member claims a seat (reserved)');
select tests.claims(:'m9');
select lives_ok(format($$insert into public.event_slots (event_id, user_id, slot_type, position, status)
                         values (%L, %L, 'confirmed', 5, 'reserved')$$, :'ev', :'m9'),
  'app: another member claims a seat');
reset role;
select id as m8_row from public.event_slots where event_id = :'ev' and user_id = :'m8' \gset
select id as m9_row from public.event_slots where event_id = :'ev' and user_id = :'m9' \gset

-- useSlotPayment reclaim of an unpaid hold on the same tile, guarded on its status.
set local role authenticated;
select tests.claims(:'m8');
select lives_ok(format($$update public.event_slots set slot_type = 'confirmed', position = 4, status = 'reserved', paid_at = null
                          where id = %L and status = 'reserved'$$, :'m8_row'),
  'app: reclaim of a reserved row (slot_type, position, status reserved, paid_at null)');
reset role;
select results_eq(format($$select status::text, position from public.event_slots where id = %L$$, :'m8_row'),
  $$values ('reserved', 4)$$, 'the reclaimed row is the player''s hold');

-- useSlotPayment rollback of a failed intent: reserved -> released. A
-- released confirmed row is deleted by the promotion trigger.
set local role authenticated;
select tests.claims(:'m9');
select lives_ok(format($$update public.event_slots set status = 'released' where id = %L and status = 'reserved'$$, :'m9_row'),
  'app: rollback of a hold to released');
reset role;
select is((select count(*)::int from public.event_slots where id = :'m9_row'), 0, 'the rolled back seat is free');

-- useReleaseSlot by the player on their own paid seat.
set local role authenticated;
select tests.claims(:'m5');
select lives_ok(format($$update public.event_slots set status = 'released', paid_at = null where id = %L$$, :'paid_row'),
  'app: a player releases their own paid seat (paid_at null)');
reset role;
select is((select count(*)::int from public.event_slots where id = :'paid_row'), 0, 'the released seat is free');

-- useReleaseSlot by the captain on another player's paid reserve row.
select tests.create_event_slot(:'r', :'m10', 'reserve', 1, 'paid') as res_paid \gset
update public.event_slots set paid_at = now() where id = :'res_paid';
set local role authenticated;
select tests.claims(:'captain');
select lives_ok(format($$update public.event_slots set status = 'released', paid_at = null where id = %L$$, :'res_paid'),
  'app: the captain releases another player''s slot');
reset role;
select results_eq(format($$select user_id, status::text, paid_at is null from public.event_slots where id = %L$$, :'res_paid'),
  format($$values (%L::uuid, 'released', true)$$, :'m10'), 'it is released, paid_at cleared, still that player''s');

-- useSlotPayment reclaim of a released row back to reserved (paid_at null).
set local role authenticated;
select tests.claims(:'m10');
select lives_ok(format($$update public.event_slots set slot_type = 'reserve', position = 1, status = 'reserved', paid_at = null
                          where id = %L and status = 'released'$$, :'res_paid'),
  'app: reclaim of a released row back to reserved');
reset role;
select is((select status::text from public.event_slots where id = :'res_paid'), 'reserved', 'the row is a hold again');

-- useSlotPayment replace: delete the player's own released row, then insert.
select tests.create_event_slot(:'r', :'m11', 'reserve', 2, 'released') as stale \gset
set local role authenticated;
select tests.claims(:'m11');
select lives_ok(format($$delete from public.event_slots where id = %L and status = 'released'$$, :'stale'),
  'app: a player deletes their own released row');
select lives_ok(format($$insert into public.event_slots (event_id, user_id, slot_type, position, status)
                         values (%L, %L, 'reserve', 2, 'reserved')$$, :'r', :'m11'),
  'app: and joins again');
reset role;
select is((select count(*)::int from public.event_slots where event_id = :'r' and user_id = :'m11' and status = 'reserved'), 1,
  'the player holds one fresh row');

-- ---------------------------------------------------------------------------
-- 4. A released row that comes back joins the queue now (review: un-release
--    kept the original created_at and was promoted first).
-- ---------------------------------------------------------------------------
select tests.create_event(:'team', 1) as q \gset
select tests.create_event_slot(:'q', :'m1', 'confirmed', 1, 'paid') as q_seat \gset
select tests.create_event_slot(:'q', :'m2', 'reserve', 1, 'released', now() - interval '2 hours') as q_old \gset
select tests.create_event_slot(:'q', :'m3', 'reserve', 2, 'reserved', now() - interval '1 hour') as q_mid \gset

set local role authenticated;
select tests.claims(:'m2');
select lives_ok(format($$update public.event_slots set status = 'reserved' where id = %L$$, :'q_old'),
  'a released reserve may come back');
select throws_ok(format($$update public.event_slots set status = 'released', created_at = '2000-01-01' where id = %L$$, :'q_old'),
  '42501', null, 'without choosing its join time');
reset role;
select is((select created_at from public.event_slots where id = :'q_old'), now(),
  'coming back from released stamps created_at with now()');

set local role authenticated;
select tests.claims(:'m1');
update public.event_slots set status = 'released', paid_at = null where id = :'q_seat';
reset role;
select results_eq(format($$select user_id, slot_type::text from public.event_slots where event_id = %L order by slot_type, created_at$$, :'q'),
  format($$values (%L::uuid, 'confirmed'), (%L::uuid, 'reserve')$$, :'m3', :'m2'),
  'the reserve who joined before the comeback is promoted first');

-- A hold that never left (reserved -> reserved) keeps its place.
select tests.create_event_slot(:'q', :'m12', 'reserve', 3, 'reserved', now() - interval '3 hours') as q_keep \gset
set local role authenticated;
select tests.claims(:'m12');
update public.event_slots set slot_type = 'reserve', position = 3, status = 'reserved', paid_at = null
 where id = :'q_keep' and status = 'reserved';
reset role;
select is((select created_at from public.event_slots where id = :'q_keep'), now() - interval '3 hours',
  'a reclaim of a hold that was never released keeps its created_at');

select * from finish();
rollback;
