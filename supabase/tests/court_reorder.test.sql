-- swap_venue_court_sort_order (PR #8 review, finding 4). sort_order is one
-- sequence across the whole venue (court-layout-builder numbers every sport
-- in one run and the calendar orders all roots by it), so a move swaps the
-- two courts' existing values and never renumbers a sibling group from 0.
-- A venue with duplicate values is renumbered first, keeping its order.
begin;
select plan(21);

create function pg_temp.court(_venue uuid, _name text, _sport public.venue_sport, _sort int,
                              _parent uuid default null, _created timestamptz default now())
returns uuid language sql as $$
  insert into public.venue_courts (venue_id, parent_court_id, name, sport, sort_order, created_at)
  values (_venue, _parent, _name, _sport, _sort, _created)
  returning id
$$;

-- Courts of a venue as name:sort_order in display order.
create function pg_temp.layout(_venue uuid) returns text language sql as $$
  select string_agg(name || ':' || sort_order, ',' order by sort_order, created_at, id)
    from public.venue_courts where venue_id = _venue
$$;

-- ---------- shape and grants ----------
select has_function('public', 'swap_venue_court_sort_order', array['uuid', 'uuid'],
  'swap_venue_court_sort_order(uuid, uuid) exists');
select is_definer('public', 'swap_venue_court_sort_order', array['uuid', 'uuid'], 'it is security definer');
select ok(
  (select proconfig from pg_proc where oid = 'public.swap_venue_court_sort_order(uuid, uuid)'::regprocedure)
    @> array['search_path=public'],
  'its search_path is pinned to public');
select is(has_function_privilege('anon', 'public.swap_venue_court_sort_order(uuid, uuid)', 'execute'),
  false, 'anon cannot execute it');
select is(has_function_privilege('authenticated', 'public.swap_venue_court_sort_order(uuid, uuid)', 'execute'),
  true, 'authenticated can execute it');

-- ---------- fixtures ----------
select tests.create_user() as owner \gset
select tests.create_user() as stranger \gset
select tests.create_venue(:'owner') as va \gset
select tests.create_venue(:'owner') as vb \gset
select tests.create_venue(:'stranger') as vs \gset

-- Venue A: football T1..T3 at 0..2, tennis P1, P2 at 3, 4, halves of T1 at 5, 6.
select pg_temp.court(:'va', 'T1', 'football', 0) as a_t1 \gset
select pg_temp.court(:'va', 'T2', 'football', 1) as a_t2 \gset
select pg_temp.court(:'va', 'T3', 'football', 2) as a_t3 \gset
select pg_temp.court(:'va', 'P1', 'tennis', 3) as a_p1 \gset
select pg_temp.court(:'va', 'P2', 'tennis', 4) as a_p2 \gset
select pg_temp.court(:'va', 'H1', 'football', 5, :'a_t1') as a_h1 \gset
select pg_temp.court(:'va', 'H2', 'football', 6, :'a_t1') as a_h2 \gset

-- Venue B: what the old per group renumbering left behind, with distinct
-- created_at so the current order is well defined.
select pg_temp.court(:'vb', 'T1', 'football', 0, null, now() - interval '5 minutes') as b_t1 \gset
select pg_temp.court(:'vb', 'P2', 'tennis', 0, null, now() - interval '4 minutes') as b_p2 \gset
select pg_temp.court(:'vb', 'T2', 'football', 1, null, now() - interval '3 minutes') as b_t2 \gset
select pg_temp.court(:'vb', 'P1', 'tennis', 1, null, now() - interval '2 minutes') as b_p1 \gset
select pg_temp.court(:'vb', 'T3', 'football', 2, null, now() - interval '1 minute') as b_t3 \gset

select pg_temp.court(:'vs', 'S1', 'football', 0) as s_1 \gset
select pg_temp.court(:'vs', 'S2', 'football', 1) as s_2 \gset

-- ---------- swaps ----------
set local role authenticated;
select tests.claims(:'owner');

select public.swap_venue_court_sort_order(:'a_p2', :'a_p1');
select is(pg_temp.layout(:'va'), 'T1:0,T2:1,T3:2,P2:3,P1:4,H1:5,H2:6',
  'moving P2 up swaps P1 and P2 only; football keeps 0..2 (the review example)');

select public.swap_venue_court_sort_order(:'a_t1', :'a_t2');
select is(pg_temp.layout(:'va'), 'T2:0,T1:1,T3:2,P2:3,P1:4,H1:5,H2:6', 'swapping two roots of one sport');

select public.swap_venue_court_sort_order(:'a_h2', :'a_h1');
select is(pg_temp.layout(:'va'), 'T2:0,T1:1,T3:2,P2:3,P1:4,H2:5,H1:6', 'swapping two sub courts of one parent');

-- ---------- duplicates ----------
select public.swap_venue_court_sort_order(:'b_t2', :'b_t3');
select is(pg_temp.layout(:'vb'), 'T1:0,P2:1,T3:2,P1:3,T2:4',
  'duplicates: the venue is renumbered 0..4 in its current order, then T2 and T3 swap');
select is((select count(distinct sort_order)::int from public.venue_courts where venue_id = :'vb'), 5,
  'duplicates: every court in the venue now has its own sort_order');

select public.swap_venue_court_sort_order(:'b_p1', :'b_p2');
select is(pg_temp.layout(:'vb'), 'T1:0,P1:1,T3:2,P2:3,T2:4',
  'tennis swaps keep the football courts at their places in the venue wide order');
select is(pg_temp.layout(:'va'), 'T2:0,T1:1,T3:2,P2:3,P1:4,H2:5,H1:6',
  'renumbering venue B leaves venue A alone');

-- ---------- refusals ----------
select throws_ok(format('select public.swap_venue_court_sort_order(%L, %L)', :'a_t3', :'a_p2'),
  '22023', null, 'roots of different sports cannot swap');
select throws_ok(format('select public.swap_venue_court_sort_order(%L, %L)', :'a_t1', :'a_h1'),
  '22023', null, 'a root and a sub court cannot swap');
select throws_ok(format('select public.swap_venue_court_sort_order(%L, %L)', :'a_t1', :'b_t1'),
  '22023', null, 'courts of two venues cannot swap');
select throws_ok(format('select public.swap_venue_court_sort_order(%L, %L)', :'a_t1', :'a_t1'),
  '22023', null, 'a court cannot swap with itself');
select throws_ok(format('select public.swap_venue_court_sort_order(%L, %L)', :'a_t1', gen_random_uuid()),
  'P0002', null, 'an unknown court is reported as not found');

select tests.claims(:'stranger');
select throws_ok(format('select public.swap_venue_court_sort_order(%L, %L)', :'a_p1', :'a_p2'),
  '42501', null, 'another owner cannot reorder this venue');
select tests.claims(:'owner');
select throws_ok(format('select public.swap_venue_court_sort_order(%L, %L)', :'s_1', :'s_2'),
  '42501', null, 'and this owner cannot reorder the other venue');

reset role;
set local role anon;
select tests.claims(null, 'anon');
select throws_ok(format('select public.swap_venue_court_sort_order(%L, %L)', :'a_p1', :'a_p2'),
  '42501', null, 'anon cannot call it');
reset role;

select is(pg_temp.layout(:'va') || ' ' || pg_temp.layout(:'vs'), 'T2:0,T1:1,T3:2,P2:3,P1:4,H2:5,H1:6 S1:0,S2:1',
  'refused calls changed nothing');

select * from finish();
rollback;
