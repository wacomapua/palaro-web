-- book_venue_slot refuses any slot a closure overlaps: its own court, any
-- ancestor or descendant in the court tree, or the whole venue (C3, P2).
begin;
select plan(18);

select tests.create_user() as owner \gset
select tests.create_user() as player \gset
select tests.create_venue(:'owner') as venue \gset
select tests.create_venue(:'owner') as other_venue \gset
select tests.create_court(:'venue', 'Full Pitch') as pitch \gset
select tests.create_court(:'venue', 'North Half', :'pitch') as north \gset
select tests.create_court(:'venue', 'Q1', :'north') as q1 \gset
select tests.create_court(:'venue', 'South Half', :'pitch') as south \gset
select tests.create_court(:'venue', 'Course', null, 'golf', 'shared') as course \gset
select tests.create_court(:'other_venue', 'Elsewhere') as elsewhere \gset
select date_trunc('day', now()) + interval '3 days' as d \gset

-- Closures written straight to the table, as older rows were: the slots they
-- cover are still 'available', so only the booking RPC stands in the way.
insert into public.venue_closures (venue_id, court_id, starts_at, ends_at)
values
  (:'venue', :'q1', :'d'::timestamptz + interval '10 hours', :'d'::timestamptz + interval '11 hours'),
  (:'venue', :'pitch', :'d'::timestamptz + interval '12 hours', :'d'::timestamptz + interval '13 hours'),
  (:'venue', null, :'d'::timestamptz + interval '14 hours', :'d'::timestamptz + interval '15 hours'),
  (:'other_venue', null, :'d'::timestamptz + interval '16 hours', :'d'::timestamptz + interval '17 hours');

select tests.create_slot(:'venue', :'q1', :'d'::timestamptz + interval '10 hours', :'d'::timestamptz + interval '11 hours') as q1_10 \gset
select tests.create_slot(:'venue', :'north', :'d'::timestamptz + interval '10 hours 30 minutes', :'d'::timestamptz + interval '11 hours 30 minutes') as north_10 \gset
select tests.create_slot(:'venue', :'pitch', :'d'::timestamptz + interval '10 hours', :'d'::timestamptz + interval '11 hours') as pitch_10 \gset
select tests.create_slot(:'venue', :'south', :'d'::timestamptz + interval '10 hours', :'d'::timestamptz + interval '11 hours') as south_10 \gset
select tests.create_slot(:'venue', :'q1', :'d'::timestamptz + interval '11 hours', :'d'::timestamptz + interval '12 hours') as q1_11 \gset
select tests.create_slot(:'venue', :'q1', :'d'::timestamptz + interval '12 hours', :'d'::timestamptz + interval '13 hours') as q1_12 \gset
select tests.create_slot(:'venue', :'south', :'d'::timestamptz + interval '14 hours', :'d'::timestamptz + interval '15 hours') as south_14 \gset
select tests.create_slot(:'venue', :'course', :'d'::timestamptz + interval '14 hours', :'d'::timestamptz + interval '14 hours 10 minutes', 50000, 4) as tee_14 \gset
select tests.create_slot(:'venue', :'south', :'d'::timestamptz + interval '16 hours', :'d'::timestamptz + interval '17 hours') as south_16 \gset

-- Own court.
select throws_ok(
  format('select * from public.book_venue_slot(%L, %L, null)', :'q1_10', :'player'),
  '23514', null, 'own court closure: check_violation');
select throws_like(
  format('select * from public.book_venue_slot(%L, %L, null)', :'q1_10', :'player'),
  'Slot closed%', 'own court closure: message starts with Slot closed');

-- Ancestors of the closed court (partial overlap counts too).
select throws_like(
  format('select * from public.book_venue_slot(%L, %L, null)', :'north_10', :'player'),
  'Slot closed%', 'parent of a closed court is closed (partial overlap)');
select throws_like(
  format('select * from public.book_venue_slot(%L, %L, null)', :'pitch_10', :'player'),
  'Slot closed%', 'grandparent of a closed court is closed');

-- Descendants of a closed court.
select throws_like(
  format('select * from public.book_venue_slot(%L, %L, null)', :'q1_12', :'player'),
  'Slot closed%', 'grandchild of a closed court is closed');
select throws_ok(
  format('select * from public.book_venue_slot(%L, %L, null)', :'q1_12', :'player'),
  '23514', null, 'descendant closure: check_violation');

-- Whole venue, exclusive and shared.
select throws_like(
  format('select * from public.book_venue_slot(%L, %L, null)', :'south_14', :'player'),
  'Slot closed%', 'whole venue closure closes every court');
select throws_like(
  format('select * from public.book_venue_slot(%L, %L, null, 2)', :'tee_14', :'player'),
  'Slot closed%', 'whole venue closure closes shared tee times');
select throws_ok(
  format('select * from public.book_venue_slot(%L, %L, null, 2)', :'tee_14', :'player'),
  '23514', null, 'shared closure: check_violation');

-- The message still reads as a conflict to payments-create-intent.
select throws_like(
  format('select * from public.book_venue_slot(%L, %L, null)', :'south_14', :'player'),
  '%not available%', 'message keeps the "not available" wording the edge function maps to 409');

-- Not covered: sibling branch, touching boundary, another venue's closure.
select lives_ok(
  format('select * from public.book_venue_slot(%L, %L, null)', :'south_10', :'player'),
  'sibling branch of a closed court stays bookable');
select lives_ok(
  format('select * from public.book_venue_slot(%L, %L, null)', :'q1_11', :'player'),
  'slot that only touches the closure boundary stays bookable');
select lives_ok(
  format('select * from public.book_venue_slot(%L, %L, null)', :'south_16', :'player'),
  'another venue''s closure does not apply');

select is((select status::text from public.venue_slots where id = :'south_10'), 'held',
  'a bookable slot is still held as before');
select is(
  (select count(*)::int from public.venue_bookings where slot_id in (:'q1_10', :'north_10', :'pitch_10', :'q1_12', :'south_14', :'tee_14')),
  0, 'no booking row is left behind for a closed slot');

-- A closure created after a slot is held blocks the next booking too.
insert into public.venue_closures (venue_id, court_id, starts_at, ends_at)
values (:'venue', :'south', :'d'::timestamptz + interval '10 hours', :'d'::timestamptz + interval '10 hours 1 minute');
update public.venue_slots set status = 'available', held_until = null where id = :'south_10';
select is((select status::text from public.venue_slots where id = :'south_10'), 'closed',
  'freeing a slot inside a closure leaves it closed');
update public.venue_slots set status = 'held', held_until = now() - interval '1 minute' where id = :'south_10';
select throws_like(
  format('select * from public.book_venue_slot(%L, %L, null)', :'south_10', :'player'),
  'Slot closed%', 'a stale hold inside a closure cannot be rebooked');
select throws_like(
  format('select * from public.book_venue_slot(%L, %L, null)', :'elsewhere', :'player'),
  'Slot not found%', 'unknown slot still reports Slot not found');

select * from finish();
rollback;
