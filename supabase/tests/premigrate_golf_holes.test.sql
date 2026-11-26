-- What 20260601000001_golf_holes.sql does to golf rows that already existed.
-- Seeded by supabase/tests/premigrate/20260601000001_golf_holes.sql before the
-- migration ran.
begin;
select plan(4);

select results_eq(
  $$select holes::int, party_size, total_cents, status::text from public.venue_bookings
     where id = '00000000-0601-0000-0000-000000000b01'$$,
  $$values (18, 4, 1000000, 'paid')$$,
  'an existing golf booking reads as an 18 hole round, money and status untouched');
select results_eq(
  $$select price_per_player_cents, price_per_player_9_cents, status::text from public.venue_slots
     where id = '00000000-0601-0000-0000-000000000e01'$$,
  $$values (250000, null::int, 'booked')$$,
  'an existing tee time offers no 9 hole rounds until the owner sets a price');
select results_eq(
  $$select price_cents, price_9_cents from public.venue_slot_templates
     where id = '00000000-0601-0000-0000-000000000f01'$$,
  $$values (250000, null::int)$$,
  'an existing weekly template has no 9 hole price');
select is(
  (select count(*)::int from public.venue_bookings where holes is distinct from 18
      and id::text like '00000000-0601-%'),
  0, 'no seeded booking became a 9 hole round');

select * from finish();
rollback;
