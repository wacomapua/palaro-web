-- generate_venue_slots: venue local today, future slots only, no overlaps,
-- run caps, template courts must belong to the venue, closures across the
-- court tree.
begin;
select plan(25);

-- Pick a fixed offset zone whose local date differs from the UTC date right
-- now, so starting from the server's current_date is always caught.
select case when extract(hour from now() at time zone 'UTC') >= 11 then 'Etc/GMT-14' else 'Etc/GMT+12' end as tz \gset
select (now() at time zone :'tz')::date as today \gset
select extract(hour from now() at time zone :'tz')::int as lh \gset
select is(:'today'::date <> (now() at time zone 'UTC')::date, true, 'fixture: venue local date differs from the UTC date');

select tests.create_user() as owner \gset
select tests.create_user() as stranger \gset

-- ---------- A: local today, future only ----------
select tests.create_venue(:'owner', :'tz') as va \gset
select tests.create_court(:'va', 'A1') as a1 \gset
insert into public.venue_slot_templates (venue_id, court_id, day_of_week, start_time, end_time, slot_minutes, price_cents)
select :'va', :'a1', dow, '00:00', '24:00', 60, 100000 from generate_series(0, 6) dow;

set local role authenticated;
select tests.claims(:'owner');
select public.generate_venue_slots(:'va', :'today'::date) as a_created \gset
reset role;
select is(:'a_created'::int, 23 - :lh, 'creates only the hours still ahead today');
select is((select count(*)::int from public.venue_slots where venue_id = :'va' and starts_at <= now()), 0,
  'no slot that already started is created');
select is((select min((starts_at at time zone :'tz')::date) from public.venue_slots where venue_id = :'va'), :'today'::date,
  'starts from the venue local today');
select is((select max((starts_at at time zone :'tz')::date) from public.venue_slots where venue_id = :'va'), :'today'::date,
  'and stops at the through date');
select is((select min(starts_at) from public.venue_slots where venue_id = :'va'),
  (:'today'::date + make_interval(hours => :lh + 1)) at time zone :'tz',
  'first slot is the next whole hour in venue time');

-- ---------- B: caps ----------
select tests.create_venue(:'owner', :'tz') as vb \gset
set local role authenticated;
select tests.claims(:'owner');
select throws_ok(format('select public.generate_venue_slots(%L, %L)', :'vb', :'today'::date + 91),
  '22023', null, 'more than 90 local days ahead is rejected');
select throws_like(format('select public.generate_venue_slots(%L, %L)', :'vb', :'today'::date + 91),
  '%90 days%', 'the error says the limit');
select lives_ok(format('select public.generate_venue_slots(%L, %L)', :'vb', :'today'::date + 90),
  'exactly 90 days ahead is allowed');
reset role;

select tests.create_venue(:'owner', :'tz') as vbig \gset
insert into public.venue_courts (venue_id, name, sport) select :'vbig', 'Bay ' || n, 'golf' from generate_series(1, 10) n;
insert into public.venue_slot_templates (venue_id, court_id, day_of_week, start_time, end_time, slot_minutes, price_cents)
select :'vbig', c.id, dow, '00:00', '24:00', 5, 1000
  from public.venue_courts c cross join generate_series(0, 6) dow where c.venue_id = :'vbig';
set local role authenticated;
select tests.claims(:'owner');
select throws_ok(format('select public.generate_venue_slots(%L, %L)', :'vbig', :'today'::date + 7),
  '54000', null, 'a run above 20,000 slots is rejected');
select throws_like(format('select public.generate_venue_slots(%L, %L)', :'vbig', :'today'::date + 7),
  '%20000%', 'the error names the 20,000 limit');
reset role;
select is((select count(*)::int from public.venue_slots where venue_id = :'vbig'), 0, 'a rejected run writes nothing');

-- ---------- C: overlap with existing slots and within the run ----------
select tests.create_venue(:'owner', :'tz') as vc \gset
select tests.create_court(:'vc', 'C1') as c1 \gset
select tests.create_court(:'vc', 'C2') as c2 \gset
select tests.create_court(:'vc', 'C3') as c3 \gset
select :'today'::date + 1 as tomorrow \gset
select extract(dow from :'tomorrow'::date)::int as tdow \gset
-- Tee interval cut from 10 to 8 minutes: 10:00, 10:08, 10:16, 10:24, 10:32.
insert into public.venue_slot_templates (venue_id, court_id, day_of_week, start_time, end_time, slot_minutes, price_cents)
values (:'vc', :'c1', :tdow, '10:00', '10:40', 8, 5000);
select tests.create_slot(:'vc', :'c1', (:'tomorrow'::date + time '10:00') at time zone :'tz', (:'tomorrow'::date + time '10:10') at time zone :'tz') \gset
select tests.create_slot(:'vc', :'c1', (:'tomorrow'::date + time '10:16') at time zone :'tz', (:'tomorrow'::date + time '10:24') at time zone :'tz', 5000, null, 'cancelled') \gset
select tests.create_slot(:'vc', :'c1', (:'tomorrow'::date + time '10:30') at time zone :'tz', (:'tomorrow'::date + time '10:35') at time zone :'tz', 5000, null, 'cancelled') \gset
-- Two bands on one court that overlap each other.
insert into public.venue_slot_templates (venue_id, court_id, day_of_week, start_time, end_time, slot_minutes, price_cents)
values (:'vc', :'c2', :tdow, '10:00', '11:00', 60, 5000), (:'vc', :'c2', :tdow, '10:30', '11:30', 60, 5000);
-- Another court at the same time is not an overlap.
insert into public.venue_slot_templates (venue_id, court_id, day_of_week, start_time, end_time, slot_minutes, price_cents)
values (:'vc', :'c3', :tdow, '10:00', '11:00', 60, 5000);

set local role authenticated;
select tests.claims(:'owner');
select public.generate_venue_slots(:'vc', :'tomorrow'::date) as c_created \gset
reset role;
select is(:'c_created'::int, 4, 'creates only the non overlapping rows');
select results_eq(
  format($$select to_char(starts_at at time zone %L, 'HH24:MI') from public.venue_slots
            where court_id = %L and status = 'available' and generated_from_template_id is null
              and starts_at > (%L::date + time '10:10') at time zone %L order by starts_at$$,
         :'tz', :'c1', :'tomorrow', :'tz'),
  $$values ('10:24'), ('10:32')$$,
  'skips rows overlapping a live slot and rows matching a cancelled slot''s exact window');
select is((select count(*)::int from public.venue_slots where court_id = :'c1'), 5, 'C1 holds the 3 existing slots plus 2 new');
select results_eq(
  format($$select to_char(starts_at at time zone %L, 'HH24:MI') from public.venue_slots where court_id = %L order by starts_at$$, :'tz', :'c2'),
  $$values ('10:00')$$, 'overlapping bands on one court do not produce overlapping slots');
select is((select count(*)::int from public.venue_slots where court_id = :'c3'), 1, 'slots on other courts never block');
select is((select count(*)::int from public.venue_slots s1 join public.venue_slots s2
            on s1.court_id = s2.court_id and s1.id < s2.id
           and s1.status <> 'cancelled' and s2.status <> 'cancelled'
           and s1.starts_at < s2.ends_at and s2.starts_at < s1.ends_at
          where s1.venue_id = :'vc'), 0, 'no two live slots overlap on any court');
set local role authenticated;
select tests.claims(:'owner');
select is(public.generate_venue_slots(:'vc', :'tomorrow'::date), 0, 'rerunning creates nothing');
reset role;

-- ---------- D: template court must belong to the venue ----------
select tests.create_venue(:'owner', :'tz') as vd \gset
select tests.create_venue(:'stranger', :'tz') as ve \gset
select tests.create_court(:'ve', 'Someone else''s court') as e1 \gset
insert into public.venue_slot_templates (venue_id, court_id, day_of_week, start_time, end_time, slot_minutes, price_cents)
values (:'vd', :'e1', :tdow, '10:00', '12:00', 60, 5000);
set local role authenticated;
select tests.claims(:'owner');
select is(public.generate_venue_slots(:'vd', :'tomorrow'::date), 0, 'a template pointing at another venue''s court creates nothing');
reset role;
select is((select count(*)::int from public.venue_slots where court_id = :'e1'), 0, 'no slot lands on the other venue''s court');

-- ---------- F: closures across the court tree ----------
select tests.create_venue(:'owner', :'tz') as vf \gset
select tests.create_court(:'vf', 'Full Pitch') as f_pitch \gset
select tests.create_court(:'vf', 'North Half', :'f_pitch') as f_north \gset
select tests.create_court(:'vf', 'Q1', :'f_north') as f_q1 \gset
select tests.create_court(:'vf', 'South Half', :'f_pitch') as f_south \gset
insert into public.venue_slot_templates (venue_id, court_id, day_of_week, start_time, end_time, slot_minutes, price_cents)
select :'vf', c, :tdow, b.s, b.e, 60, 5000
  from unnest(array[:'f_pitch', :'f_north', :'f_q1', :'f_south']::uuid[]) c
 cross join (values (time '10:00', time '11:00'), (time '12:00', time '13:00')) b(s, e);
insert into public.venue_closures (venue_id, court_id, starts_at, ends_at) values
  (:'vf', :'f_north', (:'tomorrow'::date + time '10:00') at time zone :'tz', (:'tomorrow'::date + time '11:00') at time zone :'tz'),
  (:'vf', null, (:'tomorrow'::date + time '12:30') at time zone :'tz', (:'tomorrow'::date + time '12:31') at time zone :'tz');
set local role authenticated;
select tests.claims(:'owner');
select is(public.generate_venue_slots(:'vf', :'tomorrow'::date), 1, 'only the South Half 10:00 slot is outside every closure');
reset role;
select is((select array_agg(court_id) from public.venue_slots where venue_id = :'vf'), array[:'f_south'::uuid],
  'closing North Half also skips its parent and child, not its sibling; the venue closure skips all');

-- ---------- authorization ----------
set local role authenticated;
select tests.claims(:'stranger');
select throws_ok(format('select public.generate_venue_slots(%L, %L)', :'vf', :'tomorrow'),
  '42501', null, 'only the owner can generate');
reset role;
select is(has_function_privilege('anon', 'public.generate_venue_slots(uuid, date)', 'execute'), false, 'anon cannot generate');

select * from finish();
rollback;
