-- replace_venue_slot_templates: validates the whole payload first, then
-- replaces one court group's templates (sport + booking mode) in a single
-- transaction. A golf course (shared tee sheet) and range bays (exclusive,
-- hourly) are separate groups.
begin;
select plan(35);

select (now() at time zone 'Asia/Manila')::date + 1 as tomorrow \gset
select extract(dow from :'tomorrow'::date)::int as tdow \gset
select (:tdow + 1) % 7 as tennis_dow \gset
select tests.create_user() as owner \gset
select tests.create_user() as stranger \gset
select tests.create_venue(:'owner') as venue \gset
select tests.create_court(:'venue', 'Course', null, 'golf', 'shared') as course \gset
select tests.create_court(:'venue', 'Bay 1', null, 'golf', 'exclusive') as bay1 \gset
select tests.create_court(:'venue', 'Bay 2', null, 'golf', 'exclusive') as bay2 \gset
select tests.create_court(:'venue', 'Bay 3', null, 'golf', 'exclusive', false) as bay_off \gset
select tests.create_court(:'venue', 'Tennis 1', null, 'tennis') as tennis \gset

insert into public.venue_slot_templates (venue_id, court_id, day_of_week, start_time, end_time, slot_minutes, price_cents) values
  (:'venue', :'course', 1, '06:00', '18:00', 10, 250000),
  (:'venue', :'bay1', 1, '08:00', '22:00', 60, 40000),
  (:'venue', :'bay2', 1, '08:00', '22:00', 60, 40000),
  (:'venue', :'bay_off', 1, '08:00', '22:00', 60, 40000),
  (:'venue', :'tennis', :tennis_dow, '09:00', '20:00', 60, 80000);

create temp table before_rows on commit drop as
  select court_id, day_of_week, start_time, end_time, slot_minutes, price_cents from public.venue_slot_templates where venue_id = :'venue';
grant select on before_rows to authenticated;

select is(has_function_privilege('anon', 'public.replace_venue_slot_templates(uuid, venue_sport, text, jsonb)', 'execute'), false,
  'anon cannot save templates');
select is(has_function_privilege('authenticated', 'public.replace_venue_slot_templates(uuid, venue_sport, text, jsonb)', 'execute'), true,
  'authenticated can call it (owner is checked inside)');
select is((select prosecdef from pg_proc where oid = 'public.replace_venue_slot_templates(uuid, venue_sport, text, jsonb)'::regprocedure), true,
  'it is SECURITY DEFINER');

set local role authenticated;
select tests.claims(:'stranger');
select throws_ok(format($$select public.replace_venue_slot_templates(%L, 'golf', 'exclusive', '[]')$$, :'venue'),
  '42501', null, 'a non owner cannot replace templates');

-- ---------- validation happens before anything is deleted ----------
select tests.claims(:'owner');
select throws_ok(format($$select public.replace_venue_slot_templates(%L, 'golf', 'exclusive', %L)$$, :'venue', j), '22023', null, d)
  from (values
    ('[{"day_of_week":1,"start_time":"10:00","end_time":"10:00","slot_minutes":60,"price_cents":100}]', 'close must be after open'),
    ('[{"day_of_week":1,"start_time":"20:00","end_time":"08:00","slot_minutes":60,"price_cents":100}]', 'no overnight bands'),
    ('[{"day_of_week":1,"start_time":"08:00","end_time":"20:00","slot_minutes":4,"price_cents":100}]', 'slot length at least 5 minutes'),
    ('[{"day_of_week":1,"start_time":"00:00","end_time":"24:00","slot_minutes":1441,"price_cents":100}]', 'slot length at most 1440 minutes'),
    ('[{"day_of_week":1,"start_time":"08:00","end_time":"09:00","slot_minutes":90,"price_cents":100}]', 'slot length cannot exceed the opening hours'),
    ('[{"day_of_week":1,"start_time":"08:00","end_time":"12:00","slot_minutes":60,"price_cents":100},{"day_of_week":1,"start_time":"11:00","end_time":"14:00","slot_minutes":60,"price_cents":100}]', 'bands on one day cannot overlap'),
    ('[{"day_of_week":7,"start_time":"08:00","end_time":"12:00","slot_minutes":60,"price_cents":100}]', 'day of week is 0 to 6'),
    ('[{"day_of_week":1,"start_time":"08:00","end_time":"12:00","slot_minutes":60,"price_cents":-1}]', 'price cannot be negative'),
    ('[{"day_of_week":1,"start_time":"nine","end_time":"12:00","slot_minutes":60,"price_cents":100}]', 'times must parse'),
    ('[{"day_of_week":1,"start_time":"08:00","end_time":"12:00","slot_minutes":60}]', 'price is required'),
    ('[{"day_of_week":1.5,"start_time":"08:00","end_time":"12:00","slot_minutes":60,"price_cents":100}]', 'day of week must be a whole number'),
    ('{"day_of_week":1}', 'payload must be an array'),
    ('[1]', 'each entry must be an object')
  ) t(j, d);
select throws_ok(format($$select public.replace_venue_slot_templates(%L, 'golf', 'weird', '[]')$$, :'venue'),
  '22023', null, 'booking mode must be exclusive or shared');
select throws_ok(format($$select public.replace_venue_slot_templates(%L, 'swimming', 'exclusive', '[]')$$, :'venue'),
  '22023', null, 'a group with no active courts is rejected');
select is((select count(*)::int from (
    select court_id, day_of_week, start_time, end_time, slot_minutes, price_cents from public.venue_slot_templates where venue_id = :'venue'
    except select * from before_rows) x), 0, 'failed saves change nothing');
select is((select count(*)::int from public.venue_slot_templates where venue_id = :'venue'), 5, 'failed saves delete nothing');

-- ---------- range bays: exclusive golf group ----------
select is(public.replace_venue_slot_templates(:'venue', 'golf', 'exclusive',
  '[{"day_of_week":1,"start_time":"07:00","end_time":"21:00","slot_minutes":60,"price_cents":50000},
    {"day_of_week":2,"start_time":"07:00","end_time":"21:00","slot_minutes":60,"price_cents":50000}]'::jsonb),
  4, 'writes one row per active bay per band');
reset role;
select results_eq(
  format($$select court_id, day_of_week, start_time::text, slot_minutes, price_cents from public.venue_slot_templates
           where court_id in (%L, %L) order by court_id, day_of_week$$, :'bay1', :'bay2'),
  format($$select c::uuid, d, '07:00:00', 60, 50000 from unnest(array[%L, %L]) c, (values (1), (2)) v(d) order by 1, 2$$,
    least(:'bay1', :'bay2'), greatest(:'bay1', :'bay2')),
  'each active bay now has exactly the new bands');
select is((select count(*)::int from public.venue_slot_templates where court_id = :'bay_off'), 0,
  'an inactive court in the group loses its stale templates and gets none');
select results_eq(
  format($$select day_of_week, start_time::text, slot_minutes, price_cents from public.venue_slot_templates where court_id = %L$$, :'course'),
  $$values (1, '06:00:00', 10, 250000)$$, 'the golf course (shared group) is untouched');
select results_eq(
  format($$select day_of_week, start_time::text from public.venue_slot_templates where court_id = %L$$, :'tennis'),
  format($$values (%s, '09:00:00')$$, :tennis_dow), 'other sports are untouched');

-- ---------- golf course: shared group ----------
set local role authenticated;
select tests.claims(:'owner');
select is(public.replace_venue_slot_templates(:'venue', 'golf', 'shared',
  '[{"day_of_week":6,"start_time":"06:00","end_time":"14:00","slot_minutes":10,"price_cents":300000}]'::jsonb),
  1, 'the shared group only covers the course');
reset role;
select results_eq(
  format($$select day_of_week, start_time::text, end_time::text, slot_minutes, price_cents from public.venue_slot_templates where court_id = %L$$, :'course'),
  $$values (6, '06:00:00', '14:00:00', 10, 300000)$$, 'the course has its new tee sheet');
select is((select count(*)::int from public.venue_slot_templates where court_id in (:'bay1', :'bay2')), 4, 'bays are untouched by the course save');

-- ---------- generated slots follow each group ----------
set local role authenticated;
select tests.claims(:'owner');
select public.replace_venue_slot_templates(:'venue', 'golf', 'shared',
  format('[{"day_of_week":%s,"start_time":"06:00","end_time":"07:00","slot_minutes":10,"price_cents":300000}]', :tdow)::jsonb);
select public.replace_venue_slot_templates(:'venue', 'golf', 'exclusive',
  format('[{"day_of_week":%s,"start_time":"06:00","end_time":"08:00","slot_minutes":60,"price_cents":50000}]', :tdow)::jsonb);
select is(public.generate_venue_slots(:'venue', :'tomorrow'::date), 10, '6 tee times on the course plus 2 hours on each of 2 bays');
reset role;
select results_eq(
  format($$select count(*)::int, min(ends_at - starts_at), bool_and(booking_mode = 'shared'), bool_and(price_per_player_cents = 300000)
             from public.venue_slots where court_id = %L$$, :'course'),
  $$values (6, interval '10 minutes', true, true)$$, 'course: 10 minute shared tee times priced per golfer');
select results_eq(
  format($$select count(*)::int, min(ends_at - starts_at), bool_and(booking_mode = 'exclusive'), bool_and(price_cents = 50000)
             from public.venue_slots where court_id in (%L, %L)$$, :'bay1', :'bay2'),
  $$values (4, interval '1 hour', true, true)$$, 'bays: hourly exclusive slots at the bay price');

-- ---------- empty payload clears just that group ----------
set local role authenticated;
select tests.claims(:'owner');
select is(public.replace_venue_slot_templates(:'venue', 'golf', 'exclusive', '[]'::jsonb), 0, 'an empty week clears the group');
reset role;
select is((select count(*)::int from public.venue_slot_templates where court_id in (:'bay1', :'bay2', :'bay_off')), 0, 'bays have no templates');
select is((select count(*)::int from public.venue_slot_templates where court_id in (:'course', :'tennis')), 2, 'other groups keep theirs');

select * from finish();
rollback;
