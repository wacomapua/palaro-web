-- What 20260531000004 itself did to seats released before the promotion
-- trigger existed (review finding 5). The rows were seeded by
-- supabase/tests/premigrate/20260531000004_reserve_auto_promotion.sql.
begin;
select plan(9);

create temp view pm4 as
  select right(event_id::text, 4) as e, right(user_id::text, 4) as u, slot_type::text as t, position as p, status::text as s
    from public.event_slots where id::text like '00000000-5eed-0004-%';

select results_eq($$select u, t, p, s from pm4 where e = 'e001' order by t, p$$,
  $$values ('aa02', 'confirmed', 1, 'paid'), ('aa04', 'confirmed', 2, 'reserved'),
           ('aa05', 'reserve', 1, 'reserved'), ('aa06', 'reserve', 3, 'released')$$,
  'E1: the released seat is freed and the reserve who joined first takes it; a released reserve stays');
select is((select count(*)::int from pm4 where e = 'e001' and u = 'aa03'), 0, 'E1: the dropped out player''s row is gone');

select results_eq($$select u, t, p from pm4 where e = 'e002' order by t, p$$,
  $$values ('aa02', 'confirmed', 1)$$, 'E2: nobody waiting, the released row is gone and seat 2 is free');

select results_eq($$select u, t, p from pm4 where e = 'e003' order by t, p$$,
  $$values ('aa02', 'confirmed', 1), ('aa03', 'confirmed', 2), ('aa05', 'reserve', 1)$$,
  'E3: a released seat beyond slot_count is removed and nobody is promoted into it');

select results_eq($$select u, t, p, s from pm4 where e = 'e004' order by t, p$$,
  $$values ('aa02', 'confirmed', 1, 'paid'), ('aa03', 'confirmed', 2, 'released'), ('aa04', 'reserve', 1, 'reserved')$$,
  'E4: an event already played is left as it was');

select is((select count(*)::int from public.event_slots s join public.events e on e.id = s.event_id
            where s.slot_type = 'confirmed' and s.status = 'released' and e.starts_at > now()), 0,
  'no upcoming event keeps a released confirmed row');

-- The seat freed in E2 can be claimed now.
select tests.create_user() as newcomer \gset
select lives_ok(format($$insert into public.event_slots (event_id, user_id, slot_type, position) values ('00000000-5eed-0004-0000-00000000e002', %L, 'confirmed', 2)$$, :'newcomer'),
  'E2: seat 2 can be claimed');
select lives_ok($$insert into public.event_slots (event_id, user_id, slot_type, position) values ('00000000-5eed-0004-0000-00000000e002', '00000000-5eed-0004-0000-00000000aa03', 'reserve', 1)$$,
  'E2: the player who dropped out can rejoin');
select results_eq($$select slot_type::text, position from public.event_slots
                     where event_id = '00000000-5eed-0004-0000-00000000e002' order by slot_type, position$$,
  $$values ('confirmed', 1), ('confirmed', 2), ('reserve', 1)$$, 'E2: both seats taken and the rejoined player waits');

select * from finish();
rollback;
