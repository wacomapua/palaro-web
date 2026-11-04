-- Runs just before 20260531000001_scheduling_closures_fixes.sql (see
-- scripts/test-db.mjs). Seeds closures the old way, as rows written straight
-- to venue_closures with the slots and bookings under them untouched, so
-- supabase/tests/premigrate_closures.test.sql can check what the migration
-- itself does with them. Ids share the 00000000-5eed- prefix; venue A is
-- 5eed...0a01, venue B (no closures) 5eed...0a02.
--
-- Venue A courts: pitch > north > q1, pitch > south, course (shared golf),
-- court_x (separate root). Closures:
--   CL1 north, active          covers pitch, north, q1 (not south)
--   CL2 pitch, active          covers pitch and every court under it
--   CL3 whole venue, active
--   CL4 whole venue, ended an hour ago

insert into auth.users (id, email) values
  ('00000000-5eed-0000-0000-00000000aa01', 'pm-owner@seed.test'),
  ('00000000-5eed-0000-0000-00000000aa02', 'pm-player1@seed.test'),
  ('00000000-5eed-0000-0000-00000000aa03', 'pm-player2@seed.test'),
  ('00000000-5eed-0000-0000-00000000aa04', 'pm-owner-b@seed.test');

insert into public.venues (id, slug, name, sport, address, owner_id, status) values
  ('00000000-5eed-0000-0000-000000000a01', 'pm-seed-a', 'Seed A', 'football', '1 Seed St', '00000000-5eed-0000-0000-00000000aa01', 'active'),
  ('00000000-5eed-0000-0000-000000000a02', 'pm-seed-b', 'Seed B', 'football', '2 Seed St', '00000000-5eed-0000-0000-00000000aa04', 'active');

insert into public.venue_courts (id, venue_id, parent_court_id, name, sport, metadata) values
  ('00000000-5eed-0000-0000-000000000c01', '00000000-5eed-0000-0000-000000000a01', null, 'Pitch', 'football', null),
  ('00000000-5eed-0000-0000-000000000c02', '00000000-5eed-0000-0000-000000000a01', '00000000-5eed-0000-0000-000000000c01', 'North', 'football', null),
  ('00000000-5eed-0000-0000-000000000c03', '00000000-5eed-0000-0000-000000000a01', '00000000-5eed-0000-0000-000000000c02', 'Q1', 'football', null),
  ('00000000-5eed-0000-0000-000000000c04', '00000000-5eed-0000-0000-000000000a01', '00000000-5eed-0000-0000-000000000c01', 'South', 'football', null),
  ('00000000-5eed-0000-0000-000000000c05', '00000000-5eed-0000-0000-000000000a01', null, 'Course', 'golf', '{"slotModel":{"bookingMode":"shared","pricingMode":"per_player","maxPlayers":4}}'),
  ('00000000-5eed-0000-0000-000000000c06', '00000000-5eed-0000-0000-000000000a01', null, 'Court X', 'football', null),
  ('00000000-5eed-0000-0000-000000000c07', '00000000-5eed-0000-0000-000000000a02', null, 'B Court', 'football', null);

-- Windows: W1 day+2, W2 day+3, W3 day+4, each 10:00 to 12:00 after the
-- current hour; CL4 ended an hour ago.
insert into public.venue_closures (id, venue_id, court_id, starts_at, ends_at, reason) values
  ('00000000-5eed-0000-0000-000000000d01', '00000000-5eed-0000-0000-000000000a01', '00000000-5eed-0000-0000-000000000c02',
   date_trunc('hour', now()) + interval '2 days 10 hours', date_trunc('hour', now()) + interval '2 days 12 hours', 'Resurfacing'),
  ('00000000-5eed-0000-0000-000000000d02', '00000000-5eed-0000-0000-000000000a01', '00000000-5eed-0000-0000-000000000c01',
   date_trunc('hour', now()) + interval '3 days 10 hours', date_trunc('hour', now()) + interval '3 days 12 hours', null),
  ('00000000-5eed-0000-0000-000000000d03', '00000000-5eed-0000-0000-000000000a01', null,
   date_trunc('hour', now()) + interval '4 days 10 hours', date_trunc('hour', now()) + interval '4 days 12 hours', 'Typhoon'),
  ('00000000-5eed-0000-0000-000000000d04', '00000000-5eed-0000-0000-000000000a01', null,
   now() - interval '5 hours', now() - interval '1 hour', 'Power cut');

insert into public.venue_slots (id, venue_id, court_id, starts_at, ends_at, price_cents, price_per_player_cents,
                                status, booking_mode, pricing_mode, max_players, held_until)
select id::uuid, venue::uuid, court::uuid, date_trunc('hour', now()) + st, date_trunc('hour', now()) + en, price, ppp,
       status::public.venue_slot_status, mode, pricing, maxp, held
from (values
  -- under CL1 (north)
  ('00000000-5eed-0000-0000-000000000e01', '00000000-5eed-0000-0000-000000000a01', '00000000-5eed-0000-0000-000000000c03', interval '2 days 10 hours', interval '2 days 11 hours', 120000, null::int, 'booked', 'exclusive', 'per_slot', null::int, null::timestamptz),
  ('00000000-5eed-0000-0000-000000000e02', '00000000-5eed-0000-0000-000000000a01', '00000000-5eed-0000-0000-000000000c02', interval '2 days 11 hours', interval '2 days 12 hours', 100000, null, 'held', 'exclusive', 'per_slot', null, now() + interval '5 minutes'),
  ('00000000-5eed-0000-0000-000000000e03', '00000000-5eed-0000-0000-000000000a01', '00000000-5eed-0000-0000-000000000c04', interval '2 days 10 hours', interval '2 days 11 hours', 100000, null, 'booked', 'exclusive', 'per_slot', null, null),
  ('00000000-5eed-0000-0000-000000000e04', '00000000-5eed-0000-0000-000000000a01', '00000000-5eed-0000-0000-000000000c01', interval '2 days 10 hours', interval '2 days 12 hours', 300000, null, 'available', 'exclusive', 'per_slot', null, null),
  -- under CL2 (pitch)
  ('00000000-5eed-0000-0000-000000000e05', '00000000-5eed-0000-0000-000000000a01', '00000000-5eed-0000-0000-000000000c04', interval '3 days 10 hours', interval '3 days 11 hours', 0, null, 'booked', 'exclusive', 'per_slot', null, null),
  ('00000000-5eed-0000-0000-000000000e06', '00000000-5eed-0000-0000-000000000a01', '00000000-5eed-0000-0000-000000000c03', interval '3 days 11 hours', interval '3 days 12 hours', 100000, null, 'available', 'exclusive', 'per_slot', null, null),
  -- under CL3 (whole venue)
  ('00000000-5eed-0000-0000-000000000e07', '00000000-5eed-0000-0000-000000000a01', '00000000-5eed-0000-0000-000000000c05', interval '4 days 10 hours', interval '4 days 10 hours 10 minutes', 50000, 50000, 'available', 'shared', 'per_player', 4, null),
  ('00000000-5eed-0000-0000-000000000e08', '00000000-5eed-0000-0000-000000000a01', '00000000-5eed-0000-0000-000000000c06', interval '4 days 11 hours', interval '4 days 12 hours', 100000, null, 'available', 'exclusive', 'per_slot', null, null),
  -- outside every active closure: court X at W1, venue B at W3
  ('00000000-5eed-0000-0000-000000000e10', '00000000-5eed-0000-0000-000000000a01', '00000000-5eed-0000-0000-000000000c06', interval '2 days 10 hours', interval '2 days 11 hours', 100000, null, 'booked', 'exclusive', 'per_slot', null, null),
  ('00000000-5eed-0000-0000-000000000e11', '00000000-5eed-0000-0000-000000000a02', '00000000-5eed-0000-0000-000000000c07', interval '4 days 10 hours', interval '4 days 11 hours', 100000, null, 'booked', 'exclusive', 'per_slot', null, null)
) v(id, venue, court, st, en, price, ppp, status, mode, pricing, maxp, held);

-- Under CL4 (ended): a game that was already played.
insert into public.venue_slots (id, venue_id, court_id, starts_at, ends_at, price_cents, status)
values ('00000000-5eed-0000-0000-000000000e09', '00000000-5eed-0000-0000-000000000a01', '00000000-5eed-0000-0000-000000000c06',
        now() - interval '4 hours', now() - interval '3 hours', 100000, 'booked');

insert into public.venue_bookings (id, slot_id, venue_id, captain_user_id, party_size, total_cents,
                                   platform_fee_cents, payout_cents, status, paymongo_intent_id)
select id::uuid, slot::uuid, venue::uuid, captain::uuid, party, total, total / 20, total - total / 20,
       status::public.venue_booking_status, intent
from (values
  ('00000000-5eed-0000-0000-000000000b01', '00000000-5eed-0000-0000-000000000e01', '00000000-5eed-0000-0000-000000000a01', '00000000-5eed-0000-0000-00000000aa02', 1, 120000, 'paid', 'pi_pm_b01'),
  ('00000000-5eed-0000-0000-000000000b02', '00000000-5eed-0000-0000-000000000e02', '00000000-5eed-0000-0000-000000000a01', '00000000-5eed-0000-0000-00000000aa03', 1, 100000, 'pending_payment', 'pi_pm_b02'),
  ('00000000-5eed-0000-0000-000000000b03', '00000000-5eed-0000-0000-000000000e03', '00000000-5eed-0000-0000-000000000a01', '00000000-5eed-0000-0000-00000000aa02', 1, 100000, 'paid', 'pi_pm_b03'),
  ('00000000-5eed-0000-0000-000000000b05', '00000000-5eed-0000-0000-000000000e05', '00000000-5eed-0000-0000-000000000a01', '00000000-5eed-0000-0000-00000000aa03', 1, 0, 'paid', 'pi_pm_b05'),
  ('00000000-5eed-0000-0000-000000000b06', '00000000-5eed-0000-0000-000000000e06', '00000000-5eed-0000-0000-000000000a01', '00000000-5eed-0000-0000-00000000aa02', 1, 100000, 'cancelled', 'pi_pm_b06'),
  ('00000000-5eed-0000-0000-000000000b7a', '00000000-5eed-0000-0000-000000000e07', '00000000-5eed-0000-0000-000000000a01', '00000000-5eed-0000-0000-00000000aa02', 2, 100000, 'paid', 'pi_pm_b7a'),
  ('00000000-5eed-0000-0000-000000000b7b', '00000000-5eed-0000-0000-000000000e07', '00000000-5eed-0000-0000-000000000a01', '00000000-5eed-0000-0000-00000000aa03', 1, 50000, 'paid', 'pi_pm_b7b'),
  ('00000000-5eed-0000-0000-000000000b7c', '00000000-5eed-0000-0000-000000000e07', '00000000-5eed-0000-0000-000000000a01', '00000000-5eed-0000-0000-00000000aa04', 1, 50000, 'pending_payment', 'pi_pm_b7c'),
  ('00000000-5eed-0000-0000-000000000b09', '00000000-5eed-0000-0000-000000000e09', '00000000-5eed-0000-0000-000000000a01', '00000000-5eed-0000-0000-00000000aa02', 1, 100000, 'paid', 'pi_pm_b09'),
  ('00000000-5eed-0000-0000-000000000b10', '00000000-5eed-0000-0000-000000000e10', '00000000-5eed-0000-0000-000000000a01', '00000000-5eed-0000-0000-00000000aa03', 1, 100000, 'paid', 'pi_pm_b10'),
  ('00000000-5eed-0000-0000-000000000b11', '00000000-5eed-0000-0000-000000000e11', '00000000-5eed-0000-0000-000000000a02', '00000000-5eed-0000-0000-00000000aa02', 1, 100000, 'paid', 'pi_pm_b11')
) v(id, slot, venue, captain, party, total, status, intent);

-- b01 has its match event, as complete_venue_booking would have made it.
insert into public.teams (id, slug, name, captain_id)
values ('00000000-5eed-0000-0000-00000000f001', 'pm-seed-team', 'Seed Team', '00000000-5eed-0000-0000-00000000aa02');
insert into public.events (id, team_id, title, starts_at, created_by, venue_booking_id)
values ('00000000-5eed-0000-0000-00000000f002', '00000000-5eed-0000-0000-00000000f001', 'Match',
        date_trunc('hour', now()) + interval '2 days 10 hours', '00000000-5eed-0000-0000-00000000aa02', '00000000-5eed-0000-0000-000000000b01');
update public.venue_bookings
   set event_id = '00000000-5eed-0000-0000-00000000f002', team_id = '00000000-5eed-0000-0000-00000000f001'
 where id = '00000000-5eed-0000-0000-000000000b01';
