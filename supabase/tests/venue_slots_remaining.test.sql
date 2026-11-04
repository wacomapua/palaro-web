-- venue_slots_remaining(_slot_ids uuid[]) (C5): the batch form of
-- venue_slot_remaining for the team-manager tee sheet. Same numbers, one row
-- per known slot, at most 500 ids per call, callable by anon and
-- authenticated.
begin;
select plan(11);

select tests.create_user() as owner \gset
select tests.create_user() as player \gset
select tests.create_venue(:'owner') as venue \gset
select tests.create_court(:'venue', 'Course', null, 'golf', 'shared') as course \gset
select tests.create_court(:'venue', 'Court 1') as court \gset
select date_trunc('hour', now()) + interval '5 days' as d \gset

-- 60 tee times (max 4) with a mix of booking statuses and party sizes, and
-- 20 exclusive slots in every slot status.
create temp table made (id uuid) on commit drop;
insert into made
select tests.create_slot(:'venue', :'course',
         :'d'::timestamptz + make_interval(mins => 10 * i), :'d'::timestamptz + make_interval(mins => 10 * i + 10),
         50000, 4,
         case when i % 7 = 0 then 'booked' when i % 11 = 0 then 'closed' else 'available' end::public.venue_slot_status)
  from generate_series(0, 59) i;
insert into made
select tests.create_slot(:'venue', :'court',
         :'d'::timestamptz + make_interval(hours => i), :'d'::timestamptz + make_interval(hours => i + 1),
         100000, null,
         (array['available', 'held', 'booked', 'cancelled', 'closed'])[1 + i % 5]::public.venue_slot_status)
  from generate_series(0, 19) i;

-- Bookings: status cycles through every value, party size 1..3; capacity
-- (trg_check_slot_capacity) caps active ones at 4 per tee time.
do $$
declare
  _s record;
  _n int := 0;
  _st public.venue_booking_status;
begin
  for _s in
    select v.id from public.venue_slots v join made m on m.id = v.id where v.booking_mode = 'shared' order by v.starts_at
  loop
    for k in 1..3 loop
      _n := _n + 1;
      _st := (array['pending_payment', 'paid', 'completed', 'cancelled', 'refunded'])[1 + _n % 5]::public.venue_booking_status;
      begin
        perform tests.create_booking(_s.id, (select id from auth.users order by id limit 1), _st, 1 + _n % 3, 50000);
      exception when check_violation then
        null; -- tee time full
      end;
    end loop;
  end loop;
end $$;

select results_eq(
  $$select r.slot_id, r.remaining from public.venue_slots_remaining(array(select id from made)) r order by r.slot_id$$,
  $$select id, public.venue_slot_remaining(id) from made order by id$$,
  'matches venue_slot_remaining for 80 shared and exclusive slots');
select ok((select count(distinct remaining) from public.venue_slots_remaining(array(select id from made)) where remaining between 1 and 3) >= 2,
  'the fixture really mixes partial capacities');

select is((select count(*)::int from public.venue_slots_remaining(array[gen_random_uuid(), gen_random_uuid()])), 0,
  'unknown ids return no rows');
select is((select count(*)::int from public.venue_slots_remaining(array(select id from made limit 3) || array(select id from made limit 3))), 3,
  'duplicate ids return one row each');
select is((select count(*)::int from public.venue_slots_remaining('{}'::uuid[])), 0, 'an empty array returns no rows');
select is((select count(*)::int from public.venue_slots_remaining(null)), 0, 'NULL returns no rows');

select lives_ok($$select * from public.venue_slots_remaining(array(select gen_random_uuid() from generate_series(1, 500)))$$,
  '500 ids are accepted');
select throws_ok($$select * from public.venue_slots_remaining(array(select gen_random_uuid() from generate_series(1, 501)))$$,
  '22023', null, '501 ids are rejected');

select is((select provolatile from pg_proc where oid = 'public.venue_slots_remaining(uuid[])'::regprocedure), 's', 'declared stable');

-- Callable by the app before and after sign in; bookings stay hidden by RLS
-- but the counts are right.
select array(select id from made order by id) as all_ids \gset
set local role anon;
select results_eq(
  format($$select r.slot_id, r.remaining from public.venue_slots_remaining(%L::uuid[]) r order by r.slot_id$$, :'all_ids'),
  format($$select id, public.venue_slot_remaining(id) from unnest(%L::uuid[]) id order by id$$, :'all_ids'),
  'anon gets the same numbers');
reset role;
set local role authenticated;
select tests.claims(:'player');
select results_eq(
  format($$select r.slot_id, r.remaining from public.venue_slots_remaining(%L::uuid[]) r order by r.slot_id$$, :'all_ids'),
  format($$select id, public.venue_slot_remaining(id) from unnest(%L::uuid[]) id order by id$$, :'all_ids'),
  'authenticated gets the same numbers');
reset role;

select * from finish();
rollback;
