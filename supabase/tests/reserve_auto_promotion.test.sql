-- Reserve auto promotion (C7, owner decision 4). When a confirmed player's
-- row is released, the row is deleted (the seat is free even with nobody
-- waiting) and the reserve who joined first moves into the released seat,
-- unless that seat is beyond the event's slot_count. A reserve who joins
-- while a seat is free is promoted at once. Only OLD values are trusted:
-- under slots_update a member may rewrite every column of their own row.
-- Concurrent releases: reserve_auto_promotion_concurrency.test.sql.
begin;
select plan(32);

select hasnt_trigger('public', 'event_slots', 'event_slots_promote_reserve', 'the team-manager 0009 trigger is not installed');
select has_trigger('public', 'event_slots', 'event_slots_promote_on_release', 'release trigger installed');
select has_trigger('public', 'event_slots', 'event_slots_promote_on_reserve_insert', 'reserve insert trigger installed');
select ok((select bool_and(p.prosecdef and p.proconfig @> array['search_path=public']) and count(*) = 2
             from pg_proc p
            where p.oid in ('public.event_slots_promote_on_release()'::regprocedure,
                            'public.event_slots_promote_on_reserve_insert()'::regprocedure)),
  'both trigger functions are SECURITY DEFINER with search_path pinned');

select tests.create_user() as captain \gset
select tests.create_team(:'captain') as team \gset
create temp table u (n int primary key, id uuid) on commit drop;
insert into u select i, tests.create_user() from generate_series(1, 8) i;
select tests.add_member(:'team', id) from u;
select id as m1 from u where n = 1 \gset
select id as m2 from u where n = 2 \gset
select id as m3 from u where n = 3 \gset
select id as m4 from u where n = 4 \gset
select id as m5 from u where n = 5 \gset
select id as m6 from u where n = 6 \gset
select id as m7 from u where n = 7 \gset
select id as m8 from u where n = 8 \gset

-- ---------------------------------------------------------------------------
-- 1. Promotion into OLD.position, earliest created_at first (not tile order).
-- ---------------------------------------------------------------------------
select tests.create_event(:'team', 2) as e1 \gset
select tests.create_event_slot(:'e1', :'m1', 'confirmed', 1, 'paid') as e1_a \gset
select tests.create_event_slot(:'e1', :'m2', 'confirmed', 2, 'paid') as e1_b \gset
select tests.create_event_slot(:'e1', :'m3', 'reserve', 1, 'reserved', now() - interval '5 minutes') as e1_late \gset
select tests.create_event_slot(:'e1', :'m4', 'reserve', 2, 'paid', now() - interval '30 minutes') as e1_early \gset

-- m2 drops out through the app (useReleaseSlot: RLS update of their own row).
set local role authenticated;
select tests.claims(:'m2');
update public.event_slots set status = 'released', paid_at = null where id = :'e1_b';
reset role;
select is((select count(*)::int from public.event_slots where id = :'e1_b'), 0, 'the released confirmed row is deleted');
select results_eq(format('select user_id, slot_type::text, position, status::text from public.event_slots where id = %L', :'e1_early'),
  format($$values (%L::uuid, 'confirmed', 2, 'paid')$$, :'m4'),
  'the reserve who joined first moves into the released seat (position 2), keeping its status');
select results_eq(format('select slot_type::text, position from public.event_slots where id = %L', :'e1_late'),
  $$values ('reserve', 1)$$, 'the later reserve waits, even though its tile number is lower');
select is((select count(*)::int from public.event_slots where event_id = :'e1' and slot_type = 'confirmed'), 2, 'the event still has 2 confirmed');

-- A reserve dropping out promotes nobody and keeps its row.
set local role authenticated;
select tests.claims(:'m3');
update public.event_slots set status = 'released' where id = :'e1_late';
reset role;
select results_eq(format('select slot_type::text, status::text from public.event_slots where id = %L', :'e1_late'),
  $$values ('reserve', 'released')$$, 'a released reserve row stays a released reserve');

-- ---------------------------------------------------------------------------
-- 2. Nobody waiting: the seat is freed and the next claim succeeds.
-- ---------------------------------------------------------------------------
select tests.create_event(:'team', 2) as e2 \gset
select tests.create_event_slot(:'e2', :'m1', 'confirmed', 1, 'paid') as e2_a \gset
select tests.create_event_slot(:'e2', :'m2', 'confirmed', 2, 'reserved') as e2_b \gset
-- payments-webhook failure path: service role sets the row released.
set local role service_role;
update public.event_slots set status = 'released' where id = :'e2_b';
reset role;
select is((select count(*)::int from public.event_slots where event_id = :'e2'), 1, 'nobody waiting: the released row is gone');
set local role authenticated;
select tests.claims(:'m5');
select lives_ok(format($$insert into public.event_slots (event_id, user_id, slot_type, position) values (%L, %L, 'confirmed', 2)$$, :'e2', :'m5'),
  'another player can claim the freed seat');
select tests.claims(:'m2');
select lives_ok(format($$insert into public.event_slots (event_id, user_id, slot_type, position) values (%L, %L, 'reserve', 1)$$, :'e2', :'m2'),
  'the player who dropped out can rejoin (no leftover row blocks them)');
reset role;
select results_eq(format('select slot_type::text, position from public.event_slots where event_id = %L and user_id = %L', :'e2', :'m2'),
  $$values ('reserve', 1)$$, 'and waits as a reserve, the seats being full');

-- ---------------------------------------------------------------------------
-- 3. A seat beyond slot_count is not refilled.
-- ---------------------------------------------------------------------------
select tests.create_event(:'team', 3) as e3 \gset
select tests.create_event_slot(:'e3', :'m1', 'confirmed', 1, 'paid') \gset
select tests.create_event_slot(:'e3', :'m2', 'confirmed', 2, 'paid') \gset
select tests.create_event_slot(:'e3', :'m3', 'confirmed', 3, 'paid') as e3_over \gset
select tests.create_event_slot(:'e3', :'m4', 'reserve', 1, 'reserved') as e3_res \gset
update public.events set slot_count = 2 where id = :'e3';   -- the captain shrank the event
set local role authenticated;
select tests.claims(:'m3');
update public.event_slots set status = 'released' where id = :'e3_over';
reset role;
select results_eq(format('select slot_type::text, position from public.event_slots where id = %L', :'e3_res'),
  $$values ('reserve', 1)$$, 'releasing seat 3 of a 2 seat event promotes nobody');
select is((select count(*)::int from public.event_slots where event_id = :'e3' and slot_type = 'confirmed'), 2,
  'and leaves the 2 real seats');

-- ---------------------------------------------------------------------------
-- 4. Spoof: a reserve rewrites its own row to a released confirmed seat.
-- ---------------------------------------------------------------------------
select tests.create_event(:'team', 2) as e4 \gset
select tests.create_event_slot(:'e4', :'m1', 'confirmed', 1, 'paid') \gset
select tests.create_event_slot(:'e4', :'m2', 'confirmed', 2, 'paid') \gset
select tests.create_event_slot(:'e4', :'m3', 'reserve', 1, 'paid', now() - interval '1 hour') as e4_victim \gset
select tests.create_event_slot(:'e4', :'m4', 'reserve', 2, 'reserved') as e4_spoof \gset
set local role authenticated;
select tests.claims(:'m4');
update public.event_slots set slot_type = 'confirmed', position = 9, status = 'released' where id = :'e4_spoof';
reset role;
select results_eq(format('select slot_type::text, position, status::text from public.event_slots where id = %L', :'e4_victim'),
  $$values ('reserve', 1, 'paid')$$, 'spoofed "confirmed seat 9 released" by a reserve moves nobody');
select is((select count(*)::int from public.event_slots where event_id = :'e4' and slot_type = 'confirmed' and status <> 'released'), 2,
  'the real seats are untouched');

-- ---------------------------------------------------------------------------
-- 5. Spoof: a confirmed player releases while moving the row to another
--    event and position. Only OLD.event_id and OLD.position count.
-- ---------------------------------------------------------------------------
select tests.create_event(:'team', 2) as e5 \gset
select tests.create_event_slot(:'e5', :'m5', 'confirmed', 1, 'paid') as e5_mover \gset
select tests.create_event_slot(:'e5', :'m6', 'confirmed', 2, 'paid') \gset
select tests.create_event_slot(:'e5', :'m7', 'reserve', 1, 'reserved', now() - interval '10 minutes') as e5_res \gset
select tests.create_event(:'team', 2) as e6 \gset
select tests.create_event_slot(:'e6', :'m1', 'confirmed', 1, 'paid') \gset
select tests.create_event_slot(:'e6', :'m2', 'confirmed', 2, 'paid') \gset
select tests.create_event_slot(:'e6', :'m8', 'reserve', 1, 'reserved', now() - interval '2 hours') as e6_res \gset
set local role authenticated;
select tests.claims(:'m5');
update public.event_slots set status = 'released', event_id = :'e6', position = 7 where id = :'e5_mover';
reset role;
select results_eq(format('select event_id, slot_type::text, position from public.event_slots where id = %L', :'e6_res'),
  format($$values (%L::uuid, 'reserve', 1)$$, :'e6'),
  'the other event''s reserve is not moved (NEW.event_id and NEW.position are ignored)');
select results_eq(format('select event_id, slot_type::text, position from public.event_slots where id = %L', :'e5_res'),
  format($$values (%L::uuid, 'confirmed', 1)$$, :'e5'),
  'the reserve of the event the seat was really released in takes OLD.position');
select is((select count(*)::int from public.event_slots where id = :'e5_mover'), 0, 'the released row is deleted wherever it was moved');
select is((select count(*)::int from public.event_slots where event_id = :'e6' and slot_type = 'confirmed'), 2,
  'the other event still has exactly its 2 confirmed seats');

-- ---------------------------------------------------------------------------
-- 6. A reserve joining while a seat is free is promoted.
-- ---------------------------------------------------------------------------
select tests.create_event(:'team', 3) as e7 \gset
select tests.create_event_slot(:'e7', :'m1', 'confirmed', 1, 'paid') \gset
select tests.create_event_slot(:'e7', :'m2', 'confirmed', 3, 'paid') \gset
set local role authenticated;
select tests.claims(:'m3');
insert into public.event_slots (event_id, user_id, slot_type, position) values (:'e7', :'m3', 'reserve', 1);
reset role;
select results_eq(format('select slot_type::text, position, status::text from public.event_slots where event_id = %L and user_id = %L', :'e7', :'m3'),
  $$values ('confirmed', 2, 'reserved')$$, 'a reserve claimed while seat 2 is free gets seat 2');
set local role authenticated;
select tests.claims(:'m4');
insert into public.event_slots (event_id, user_id, slot_type, position) values (:'e7', :'m4', 'reserve', 1);
reset role;
select results_eq(format('select slot_type::text, position from public.event_slots where event_id = %L and user_id = %L', :'e7', :'m4'),
  $$values ('reserve', 1)$$, 'with every seat taken the next reserve waits');

-- A seat freed without a release (a confirmed row deleted outright) while a
-- reserve waits: the next reserve to join promotes the one who joined first.
select tests.create_event(:'team', 2) as e8 \gset
select tests.create_event_slot(:'e8', :'m1', 'confirmed', 1, 'paid') \gset
select tests.create_event_slot(:'e8', :'m2', 'confirmed', 2, 'paid') as e8_gone \gset
select tests.create_event_slot(:'e8', :'m3', 'reserve', 1, 'paid', now() - interval '1 hour') as e8_first \gset
delete from public.event_slots where id = :'e8_gone';
select tests.create_event_slot(:'e8', :'m4', 'reserve', 2) as e8_new \gset
select results_eq(format('select slot_type::text, position from public.event_slots where id = %L', :'e8_first'),
  $$values ('confirmed', 2)$$, 'the reserve waiting longest takes the free seat');
select results_eq(format('select slot_type::text, position from public.event_slots where id = %L', :'e8_new'),
  $$values ('reserve', 2)$$, 'the newcomer waits');

-- Several free seats: filled in seat order by join order.
select tests.create_event(:'team', 3) as e9 \gset
select tests.create_event_slot(:'e9', :'m1', 'confirmed', 1, 'paid') as e9_a \gset
select tests.create_event_slot(:'e9', :'m2', 'confirmed', 2, 'paid') as e9_b \gset
select tests.create_event_slot(:'e9', :'m3', 'confirmed', 3, 'paid') as e9_c \gset
select tests.create_event_slot(:'e9', :'m4', 'reserve', 1, 'reserved', now() - interval '3 hours') as e9_r1 \gset
select tests.create_event_slot(:'e9', :'m5', 'reserve', 2, 'reserved', now() - interval '2 hours') as e9_r2 \gset
delete from public.event_slots where id in (:'e9_b', :'e9_c');
select tests.create_event_slot(:'e9', :'m6', 'reserve', 3) as e9_r3 \gset
select results_eq(
  format('select user_id, slot_type::text, position from public.event_slots where event_id = %L order by slot_type, position', :'e9'),
  format($$values (%L::uuid, 'confirmed', 1), (%L::uuid, 'confirmed', 2), (%L::uuid, 'confirmed', 3), (%L::uuid, 'reserve', 3)$$,
         :'m1', :'m4', :'m5', :'m6'),
  'two free seats go to the two reserves who joined first, lowest seat to the earliest');

-- ---------------------------------------------------------------------------
-- 7. The captain releasing a player, and a multi row release.
-- ---------------------------------------------------------------------------
select tests.create_event(:'team', 3) as e10 \gset
select tests.create_event_slot(:'e10', :'m1', 'confirmed', 1, 'paid') as e10_a \gset
select tests.create_event_slot(:'e10', :'m2', 'confirmed', 2, 'paid') as e10_b \gset
select tests.create_event_slot(:'e10', :'m3', 'confirmed', 3, 'paid') as e10_c \gset
select tests.create_event_slot(:'e10', :'m4', 'reserve', 1, 'reserved', now() - interval '1 hour') as e10_r1 \gset
select tests.create_event_slot(:'e10', :'m5', 'reserve', 2, 'reserved', now() - interval '3 hours') as e10_r2 \gset
select tests.create_event_slot(:'e10', :'m6', 'reserve', 3, 'reserved', now() - interval '2 hours') as e10_r3 \gset
set local role authenticated;
select tests.claims(:'captain');
update public.event_slots set status = 'released' where id in (:'e10_a', :'e10_c');
reset role;
-- Rows of one statement fire in no particular order, so which released seat
-- each reserve lands in may vary; who gets promoted may not.
select is((select array_agg(user_id order by user_id) from public.event_slots where event_id = :'e10' and slot_type = 'confirmed'),
  (select array_agg(x order by x) from unnest(array[:'m2', :'m5', :'m6']::uuid[]) x),
  'a captain releasing two seats in one statement promotes the two earliest reserves, no reserve twice');
select results_eq(format('select position from public.event_slots where event_id = %L and slot_type = %L order by position', :'e10', 'confirmed'),
  $$values (1), (2), (3)$$, 'into exactly the released seats 1 and 3');
select results_eq(format('select slot_type::text, position from public.event_slots where id = %L', :'e10_r1'),
  $$values ('reserve', 1)$$, 'the latest reserve waits');
select is((select count(*)::int from public.event_slots where event_id = :'e10' and status = 'released'), 0,
  'no released confirmed rows are left');

-- A confirmed row going released by any other status change only.
select tests.create_event(:'team', 2) as e11 \gset
select tests.create_event_slot(:'e11', :'m1', 'confirmed', 1, 'reserved') as e11_a \gset
select tests.create_event_slot(:'e11', :'m2', 'confirmed', 2, 'paid') \gset
select tests.create_event_slot(:'e11', :'m3', 'reserve', 1, 'reserved') as e11_r \gset
update public.event_slots set status = 'paid', paid_at = now() where id = :'e11_a';
update public.event_slots set status = 'flaked' where id = :'e11_a';
select results_eq(format('select slot_type::text, status::text from public.event_slots where id = %L', :'e11_a'),
  $$values ('confirmed', 'flaked')$$, 'paying or flaking does not release a seat');
select results_eq(format('select slot_type::text from public.event_slots where id = %L', :'e11_r'),
  $$values ('reserve')$$, 'and nobody is promoted');

select * from finish();
rollback;
