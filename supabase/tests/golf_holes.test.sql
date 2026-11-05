-- C14 (owner decision 2026-11-06): a golf course is one tee sheet. A golfer
-- books 9 or 18 holes; the owner sets a per golfer price for each.
--   venue_slots.price_per_player_9_cents  NULL: no 9 hole rounds on that tee time
--   venue_bookings.holes                  9 or 18, default 18
--   venue_slot_templates.price_9_cents    saved by replace_venue_slot_templates,
--                                         copied by generate_venue_slots
--   book_venue_slot(..., _holes int default 18), service_role only
--   reinstate_venue_booking keeps the stored holes and totals
begin;
select plan(62);

select tests.create_user() as owner \gset
select tests.create_user() as player \gset
select tests.create_venue(:'owner') as venue \gset
select tests.create_court(:'venue', 'Course', null, 'golf', 'shared') as course \gset
select tests.create_court(:'venue', 'Court B') as court_b \gset
select date_trunc('hour', now()) + interval '3 days' as d \gset

-- ---------------------------------------------------------------------------
-- Columns
-- ---------------------------------------------------------------------------
select has_column('public', 'venue_slots', 'price_per_player_9_cents', 'venue_slots.price_per_player_9_cents exists');
select col_type_is('public', 'venue_slots', 'price_per_player_9_cents', 'integer', 'it is an int');
select col_is_null('public', 'venue_slots', 'price_per_player_9_cents', 'it is nullable (NULL: 9 holes not offered)');
select has_column('public', 'venue_bookings', 'holes', 'venue_bookings.holes exists');
select col_type_is('public', 'venue_bookings', 'holes', 'smallint', 'it is a smallint');
select col_not_null('public', 'venue_bookings', 'holes', 'it is not null');
select col_default_is('public', 'venue_bookings', 'holes', '18', 'it defaults to 18');
select has_column('public', 'venue_slot_templates', 'price_9_cents', 'venue_slot_templates.price_9_cents exists');
select col_type_is('public', 'venue_slot_templates', 'price_9_cents', 'integer', 'it is an int');
select col_is_null('public', 'venue_slot_templates', 'price_9_cents', 'it is nullable');

select tests.create_slot(:'venue', :'course', :'d'::timestamptz + interval '7 hours', :'d'::timestamptz + interval '7 hours 10 minutes', 150000, 4) as s_tee \gset

select throws_ok(format('update public.venue_slots set price_per_player_9_cents = -1 where id = %L', :'s_tee'),
  '23514', null, 'a negative 9 hole price is rejected');
select throws_ok(format($$insert into public.venue_slot_templates (venue_id, court_id, day_of_week, start_time, end_time, slot_minutes, price_cents, price_9_cents)
                          values (%L, %L, 1, '06:00', '07:00', 10, 1000, -1)$$, :'venue', :'course'),
  '23514', null, 'a negative template 9 hole price is rejected');
select throws_ok(format($$insert into public.venue_bookings (slot_id, venue_id, captain_user_id, party_size, total_cents, platform_fee_cents, payout_cents, status, holes)
                          values (%L, %L, %L, 1, 100, 5, 95, 'cancelled', 10)$$, :'s_tee', :'venue', :'player'),
  '23514', null, 'a booking for anything but 9 or 18 holes is rejected');

select tests.create_slot(:'venue', :'court_b', :'d'::timestamptz + interval '12 hours', :'d'::timestamptz + interval '13 hours') as s_plain \gset
select tests.create_booking(:'s_plain', :'player', 'cancelled') as b_plain \gset
select is((select holes::int from public.venue_bookings where id = :'b_plain'), 18, 'a booking written without holes reads 18');

-- ---------------------------------------------------------------------------
-- book_venue_slot: signature and grants
-- ---------------------------------------------------------------------------
select has_function('public', 'book_venue_slot', array['uuid', 'uuid', 'uuid', 'integer', 'integer', 'numeric', 'integer'],
  'book_venue_slot takes _holes as its 7th argument');
select hasnt_function('public', 'book_venue_slot', array['uuid', 'uuid', 'uuid', 'integer', 'integer', 'numeric'],
  'the 6 argument version is dropped');
select is((select count(*)::int from pg_proc where pronamespace = 'public'::regnamespace and proname = 'book_venue_slot'), 1,
  'exactly one book_venue_slot, so named argument calls resolve');
select is((select pg_get_function_arguments(oid) from pg_proc where pronamespace = 'public'::regnamespace and proname = 'book_venue_slot'),
  '_slot_id uuid, _captain_user_id uuid, _team_id uuid, _party_size integer DEFAULT 1, _hold_minutes integer DEFAULT 10, _platform_fee_pct numeric DEFAULT 5, _holes integer DEFAULT 18',
  'every earlier default is kept and _holes defaults to 18');
select is(has_function_privilege('anon', 'public.book_venue_slot(uuid, uuid, uuid, int, int, numeric, int)', 'execute'), false,
  'anon cannot execute it');
select is(has_function_privilege('authenticated', 'public.book_venue_slot(uuid, uuid, uuid, int, int, numeric, int)', 'execute'), false,
  'authenticated cannot execute it');
select is(has_function_privilege('service_role', 'public.book_venue_slot(uuid, uuid, uuid, int, int, numeric, int)', 'execute'), true,
  'service_role can execute it');
select is((select count(*)::int from pg_proc p, aclexplode(p.proacl) a
            where p.oid = 'public.book_venue_slot(uuid, uuid, uuid, int, int, numeric, int)'::regprocedure and a.grantee = 0), 0,
  'PUBLIC has no execute grant');
select ok((select prosecdef and proconfig @> array['search_path=public'] from pg_proc
            where oid = 'public.book_venue_slot(uuid, uuid, uuid, int, int, numeric, int)'::regprocedure),
  'it stays SECURITY DEFINER with search_path pinned to public');

-- ---------------------------------------------------------------------------
-- book_venue_slot: 9 and 18 hole totals on a shared tee time
-- ---------------------------------------------------------------------------
update public.venue_slots set price_per_player_9_cents = 90000 where id = :'s_tee';

set local role service_role;
-- payments-create-intent before it sends holes: no _holes means 18.
select * from public.book_venue_slot(:'s_tee', :'player', null, 2) \gset b18_
-- Named arguments, as PostgREST sends them.
select * from public.book_venue_slot(_slot_id => :'s_tee', _captain_user_id => :'player', _team_id => null,
                                     _party_size => 1, _holes => 9) \gset b9_
reset role;

select is(:b18_total_cents, 300000, '18 holes (the default): 2 golfers x the 18 hole price');
select is((select holes::int from public.venue_bookings where id = :'b18_booking_id'), 18, 'and the booking stores 18 holes');
select is(:b9_total_cents, 90000, '9 holes: 1 golfer x the 9 hole price');
select is(:b9_platform_fee_cents, 4500, 'the platform fee is taken on the 9 hole total');
select is(:b9_payout_cents, 85500, 'and the payout is the rest');
select is((select holes::int from public.venue_bookings where id = :'b9_booking_id'), 9, 'the booking stores 9 holes');
select results_eq(
  format('select total_cents, platform_fee_cents, payout_cents, party_size, status::text from public.venue_bookings where id = %L', :'b9_booking_id'),
  $$values (90000, 4500, 85500, 1, 'pending_payment')$$,
  'the stored 9 hole booking matches what was returned');
select is((select status::text from public.venue_slots where id = :'s_tee'), 'available', '3 of 4 spots taken: the tee time stays open');
select throws_ok(format('select * from public.book_venue_slot(%L, %L, null, 2, 10, 5, 9)', :'s_tee', :'player'),
  '23514', null, 'a 9 hole twosome cannot overfill the tee time');
select * from public.book_venue_slot(:'s_tee', :'player', null, 1, 10, 5, 9) \gset last_
select is((select status::text from public.venue_slots where id = :'s_tee'), 'booked', 'the 4th golfer fills it and it is booked');

-- No 9 hole price on the tee time.
select tests.create_slot(:'venue', :'course', :'d'::timestamptz + interval '8 hours', :'d'::timestamptz + interval '8 hours 10 minutes', 150000, 4) as s_no9 \gset
select throws_ok(format('select * from public.book_venue_slot(%L, %L, null, 1, 10, 5, 9)', :'s_no9', :'player'),
  '22023', '9 hole rounds are not offered for this tee time', '9 holes on a tee time without a 9 hole price is refused');
select is((select count(*)::int from public.venue_bookings where slot_id = :'s_no9'), 0, 'and nothing is booked');
select lives_ok(format('select * from public.book_venue_slot(%L, %L, null, 1, 10, 5, 18)', :'s_no9', :'player'),
  '18 holes on the same tee time is booked');

-- Anything but 9 or 18.
select throws_ok(format('select * from public.book_venue_slot(%L, %L, null, 1, 10, 5, %s)', :'s_no9', :'player', h),
  '22023', null, 'holes = ' || h || ' is refused')
  from (values ('0'), ('10'), ('27'), ('-9'), ('null')) t(h);
select throws_like(format('select * from public.book_venue_slot(%L, %L, null, 1, 10, 5, 10)', :'s_no9', :'player'),
  '%9 or 18%', 'the error says 9 or 18');

-- ---------------------------------------------------------------------------
-- Exclusive slots ignore _holes (and store 18), but still refuse bad values
-- ---------------------------------------------------------------------------
select tests.create_slot(:'venue', :'court_b', :'d'::timestamptz + interval '10 hours', :'d'::timestamptz + interval '11 hours', 100000) as s_ex \gset
select throws_ok(format('select * from public.book_venue_slot(%L, %L, null, 1, 10, 5, 10)', :'s_ex', :'player'),
  '22023', null, 'an exclusive slot refuses a bad holes value too');
select * from public.book_venue_slot(:'s_ex', :'player', null, 1, 10, 5, 9) \gset ex_
select is(:ex_total_cents, 100000, 'an exclusive slot ignores _holes: the total is the slot price');
select is((select holes::int from public.venue_bookings where id = :'ex_booking_id'), 18, 'and the booking stores 18');
select is((select status::text from public.venue_slots where id = :'s_ex'), 'held', 'and the slot is held as before');

-- ---------------------------------------------------------------------------
-- reinstate_venue_booking keeps the stored holes and totals
-- ---------------------------------------------------------------------------
select tests.create_slot(:'venue', :'course', :'d'::timestamptz + interval '9 hours', :'d'::timestamptz + interval '9 hours 10 minutes', 150000, 4) as s_re \gset
-- The owner has since changed both prices.
update public.venue_slots set price_per_player_9_cents = 70000, price_per_player_cents = 160000 where id = :'s_re';
insert into public.venue_bookings (slot_id, venue_id, captain_user_id, party_size, total_cents, platform_fee_cents,
                                   payout_cents, status, paymongo_intent_id, holes, refund_reason)
values (:'s_re', :'venue', :'player', 2, 180000, 9000, 171000, 'cancelled', 'pi_golf9', 9, 'Auto-released: payment not completed')
returning id as b_re \gset

set local role service_role;
select r.id as r_id from public.reinstate_venue_booking('pi_golf9') r \gset
reset role;
select is(:'r_id'::uuid, :'b_re'::uuid, 'a late paid 9 hole booking is reinstated');
select results_eq(
  format('select status::text, holes::int, party_size, total_cents, platform_fee_cents, payout_cents from public.venue_bookings where id = %L', :'b_re'),
  $$values ('paid', 9, 2, 180000, 9000, 171000)$$,
  'it keeps its 9 holes and the totals it was sold at');
select is((select amount_cents from public.transactions where gateway_ref = 'pi_golf9'), 180000,
  'the transactions row carries the stored total');

-- ---------------------------------------------------------------------------
-- replace_venue_slot_templates accepts and validates price_9_cents
-- ---------------------------------------------------------------------------
select (now() at time zone 'Asia/Manila')::date + 1 as tomorrow \gset
select extract(dow from :'tomorrow'::date)::int as tdow \gset
select (:tdow + 1) % 7 as dow2 \gset
select (:tdow + 2) % 7 as dow3 \gset
select tests.create_venue(:'owner') as vg \gset
select tests.create_court(:'vg', 'Course', null, 'golf', 'shared') as vg_course \gset
select tests.create_court(:'vg', 'Bay 1', null, 'golf', 'exclusive') as vg_bay \gset

set local role authenticated;
select tests.claims(:'owner');
select throws_ok(format($$select public.replace_venue_slot_templates(%L, 'golf', 'shared', %L)$$, :'vg', j), '22023', null, d)
  from (values
    ('[{"day_of_week":1,"start_time":"06:00","end_time":"07:00","slot_minutes":10,"price_cents":100,"price_9_cents":-1}]', 'a negative 9 hole price is refused'),
    ('[{"day_of_week":1,"start_time":"06:00","end_time":"07:00","slot_minutes":10,"price_cents":100,"price_9_cents":"nine"}]', 'a 9 hole price must be a number'),
    ('[{"day_of_week":1,"start_time":"06:00","end_time":"07:00","slot_minutes":10,"price_cents":100,"price_9_cents":1.5}]', 'a 9 hole price must be whole cents')
  ) t(j, d);
select throws_ok(format($$select public.replace_venue_slot_templates(%L, 'golf', 'exclusive', %L)$$, :'vg',
  '[{"day_of_week":1,"start_time":"08:00","end_time":"10:00","slot_minutes":60,"price_cents":100,"price_9_cents":50}]'),
  '22023', null, 'courts booked whole (exclusive) take no 9 hole price');
select is(public.replace_venue_slot_templates(:'vg', 'golf', 'shared', format('[
    {"day_of_week":%s,"start_time":"06:00","end_time":"07:00","slot_minutes":10,"price_cents":250000,"price_9_cents":140000},
    {"day_of_week":%s,"start_time":"06:00","end_time":"07:00","slot_minutes":10,"price_cents":250000,"price_9_cents":null},
    {"day_of_week":%s,"start_time":"06:00","end_time":"07:00","slot_minutes":10,"price_cents":250000}
  ]', :tdow, :dow2, :dow3)::jsonb), 3, 'a tee sheet week saves with and without a 9 hole price');
select is(public.replace_venue_slot_templates(:'vg', 'golf', 'exclusive',
  format('[{"day_of_week":%s,"start_time":"08:00","end_time":"10:00","slot_minutes":60,"price_cents":40000}]', :tdow)::jsonb), 1,
  'an exclusive group saves without one, as before');
reset role;

select is((select price_9_cents from public.venue_slot_templates where court_id = :'vg_course' and day_of_week = :tdow), 140000,
  'the 9 hole price is stored on the template');
select is((select price_9_cents from public.venue_slot_templates where court_id = :'vg_course' and day_of_week = :dow2), null::int,
  'an explicit null stores no 9 hole price');
select is((select price_9_cents from public.venue_slot_templates where court_id = :'vg_course' and day_of_week = :dow3), null::int,
  'a missing 9 hole price stores none');

-- ---------------------------------------------------------------------------
-- generate_venue_slots copies it into price_per_player_9_cents
-- ---------------------------------------------------------------------------
set local role authenticated;
select tests.claims(:'owner');
select public.generate_venue_slots(:'vg', :'tomorrow'::date) as vg_created \gset
reset role;
select is(:vg_created, 8, 'tomorrow: 6 tee times and 2 bay hours are generated');
select results_eq(
  format('select count(*)::int, min(price_per_player_cents), min(price_per_player_9_cents), max(price_per_player_9_cents) from public.venue_slots where court_id = %L', :'vg_course'),
  $$values (6, 250000, 140000, 140000)$$,
  'every generated tee time carries the template''s 18 and 9 hole prices');
select is((select count(*)::int from public.venue_slots where court_id = :'vg_bay' and price_per_player_9_cents is null), 2,
  'bay hours have no 9 hole price');

select tests.create_venue(:'owner') as vg2 \gset
select tests.create_court(:'vg2', 'Course', null, 'golf', 'shared') as vg2_course \gset
set local role authenticated;
select tests.claims(:'owner');
select public.replace_venue_slot_templates(:'vg2', 'golf', 'shared',
  format('[{"day_of_week":%s,"start_time":"06:00","end_time":"06:30","slot_minutes":10,"price_cents":250000}]', :tdow)::jsonb) as vg2_rows \gset
select public.generate_venue_slots(:'vg2', :'tomorrow'::date) as vg2_created \gset
reset role;
select results_eq(
  format('select count(*)::int, count(price_per_player_9_cents)::int from public.venue_slots where court_id = %L', :'vg2_course'),
  $$values (3, 0)$$,
  'no template 9 hole price: the tee times offer 18 holes only');

select * from finish();
rollback;
