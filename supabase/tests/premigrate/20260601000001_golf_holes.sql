-- Runs just before 20260601000001_golf_holes.sql (see scripts/test-db.mjs).
-- Seeds a golf tee time, its weekly template and a paid foursome the way
-- they existed before 9 hole rounds, so supabase/tests/premigrate_golf_holes.test.sql
-- can check they carry forward as 18 hole rounds with no 9 hole price. Ids
-- share the 00000000-0601- prefix (not 5eed, which other seeds own).

insert into auth.users (id, email) values
  ('00000000-0601-0000-0000-00000000aa01', 'pm-golf-owner@seed.test'),
  ('00000000-0601-0000-0000-00000000aa02', 'pm-golfer@seed.test');

insert into public.venues (id, slug, name, sport, address, owner_id, status) values
  ('00000000-0601-0000-0000-000000000a01', 'pm-golf-seed', 'Golf Seed', 'golf', '1 Fairway Rd',
   '00000000-0601-0000-0000-00000000aa01', 'active');

insert into public.venue_courts (id, venue_id, name, sport, kind, metadata) values
  ('00000000-0601-0000-0000-000000000c01', '00000000-0601-0000-0000-000000000a01', '18-Hole Course', 'golf', 'course',
   '{"slotModel":{"bookingMode":"shared","pricingMode":"per_player","maxPlayers":4,"teeIntervalMinutes":10,"defaultDurationMinutes":10}}');

insert into public.venue_slot_templates (id, venue_id, court_id, day_of_week, start_time, end_time, slot_minutes, price_cents) values
  ('00000000-0601-0000-0000-000000000f01', '00000000-0601-0000-0000-000000000a01', '00000000-0601-0000-0000-000000000c01',
   1, '06:00', '12:00', 10, 250000);

insert into public.venue_slots (id, venue_id, court_id, starts_at, ends_at, price_cents, price_per_player_cents,
                                status, booking_mode, pricing_mode, max_players) values
  ('00000000-0601-0000-0000-000000000e01', '00000000-0601-0000-0000-000000000a01', '00000000-0601-0000-0000-000000000c01',
   date_trunc('hour', now()) + interval '30 days 7 hours', date_trunc('hour', now()) + interval '30 days 7 hours 10 minutes',
   250000, 250000, 'booked', 'shared', 'per_player', 4);

insert into public.venue_bookings (id, slot_id, venue_id, captain_user_id, party_size, total_cents,
                                   platform_fee_cents, payout_cents, status) values
  ('00000000-0601-0000-0000-000000000b01', '00000000-0601-0000-0000-000000000e01', '00000000-0601-0000-0000-000000000a01',
   '00000000-0601-0000-0000-00000000aa02', 4, 1000000, 50000, 950000, 'paid');
