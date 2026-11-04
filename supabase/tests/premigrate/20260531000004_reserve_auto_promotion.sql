-- Runs just before 20260531000004_reserve_auto_promotion.sql (see
-- scripts/test-db.mjs). Seeds event_slots the way the app left them before
-- the promotion trigger existed: a confirmed player who dropped out kept a
-- 'released' row that still holds the seat, and nobody was promoted.
-- supabase/tests/premigrate_reserve_promotion.test.sql checks what the
-- migration does with them. Ids share the 00000000-5eed-0004- prefix.
--
--   E1 upcoming, 2 seats: seat 2 released; reserves joined 30 and 10 minutes
--      ago (tiles 2 and 1); a released reserve.
--   E2 upcoming, 2 seats: seat 2 released, nobody waiting.
--   E3 upcoming, 2 seats: seat 3 (beyond slot_count) released, a reserve
--      waiting, seats 1 and 2 taken.
--   E4 already played: seat 2 released, a reserve waiting. History stays.
--   E5 upcoming but cancelled, E6 upcoming but already marked completed:
--      seat 2 released, a reserve waiting. History stays.

insert into auth.users (id, email) values
  ('00000000-5eed-0004-0000-00000000aa01', 'pm4-captain@seed.test'),
  ('00000000-5eed-0004-0000-00000000aa02', 'pm4-p1@seed.test'),
  ('00000000-5eed-0004-0000-00000000aa03', 'pm4-p2@seed.test'),
  ('00000000-5eed-0004-0000-00000000aa04', 'pm4-p3@seed.test'),
  ('00000000-5eed-0004-0000-00000000aa05', 'pm4-p4@seed.test'),
  ('00000000-5eed-0004-0000-00000000aa06', 'pm4-p5@seed.test');

insert into public.teams (id, slug, name, captain_id, member_limit) values
  ('00000000-5eed-0004-0000-00000000b001', 'pm4-seed-team', 'Seed Team', '00000000-5eed-0004-0000-00000000aa01', 50);

insert into public.events (id, team_id, title, starts_at, slot_count, created_by) values
  ('00000000-5eed-0004-0000-00000000e001', '00000000-5eed-0004-0000-00000000b001', 'E1', now() + interval '3 days', 2, '00000000-5eed-0004-0000-00000000aa01'),
  ('00000000-5eed-0004-0000-00000000e002', '00000000-5eed-0004-0000-00000000b001', 'E2', now() + interval '3 days', 2, '00000000-5eed-0004-0000-00000000aa01'),
  ('00000000-5eed-0004-0000-00000000e003', '00000000-5eed-0004-0000-00000000b001', 'E3', now() + interval '3 days', 2, '00000000-5eed-0004-0000-00000000aa01'),
  ('00000000-5eed-0004-0000-00000000e004', '00000000-5eed-0004-0000-00000000b001', 'E4', now() - interval '2 days', 2, '00000000-5eed-0004-0000-00000000aa01');

insert into public.events (id, team_id, title, starts_at, slot_count, created_by, status) values
  ('00000000-5eed-0004-0000-00000000e005', '00000000-5eed-0004-0000-00000000b001', 'E5', now() + interval '3 days', 2, '00000000-5eed-0004-0000-00000000aa01', 'cancelled'),
  ('00000000-5eed-0004-0000-00000000e006', '00000000-5eed-0004-0000-00000000b001', 'E6', now() + interval '3 days', 2, '00000000-5eed-0004-0000-00000000aa01', 'completed');

insert into public.event_slots (id, event_id, user_id, slot_type, status, position, created_at)
select ('00000000-5eed-0004-0000-00000000' || id)::uuid, ('00000000-5eed-0004-0000-00000000' || ev)::uuid,
       ('00000000-5eed-0004-0000-00000000' || usr)::uuid, st::public.slot_type, ss::public.slot_status, pos, now() - age
from (values
  ('f101', 'e001', 'aa02', 'confirmed', 'paid',     1, interval '2 hours'),
  ('f102', 'e001', 'aa03', 'confirmed', 'released', 2, interval '2 hours'),
  ('f103', 'e001', 'aa04', 'reserve',   'reserved', 2, interval '30 minutes'),
  ('f104', 'e001', 'aa05', 'reserve',   'reserved', 1, interval '10 minutes'),
  ('f105', 'e001', 'aa06', 'reserve',   'released', 3, interval '40 minutes'),
  ('f201', 'e002', 'aa02', 'confirmed', 'paid',     1, interval '2 hours'),
  ('f202', 'e002', 'aa03', 'confirmed', 'released', 2, interval '2 hours'),
  ('f301', 'e003', 'aa02', 'confirmed', 'paid',     1, interval '2 hours'),
  ('f302', 'e003', 'aa03', 'confirmed', 'paid',     2, interval '2 hours'),
  ('f303', 'e003', 'aa04', 'confirmed', 'released', 3, interval '2 hours'),
  ('f304', 'e003', 'aa05', 'reserve',   'reserved', 1, interval '30 minutes'),
  ('f401', 'e004', 'aa02', 'confirmed', 'paid',     1, interval '3 days'),
  ('f402', 'e004', 'aa03', 'confirmed', 'released', 2, interval '3 days'),
  ('f403', 'e004', 'aa04', 'reserve',   'reserved', 1, interval '3 days'),
  ('f501', 'e005', 'aa02', 'confirmed', 'paid',     1, interval '2 hours'),
  ('f502', 'e005', 'aa03', 'confirmed', 'released', 2, interval '2 hours'),
  ('f503', 'e005', 'aa04', 'reserve',   'reserved', 1, interval '30 minutes'),
  ('f601', 'e006', 'aa02', 'confirmed', 'paid',     1, interval '2 hours'),
  ('f602', 'e006', 'aa03', 'confirmed', 'released', 2, interval '2 hours'),
  ('f603', 'e006', 'aa04', 'reserve',   'reserved', 1, interval '30 minutes')
) as v(id, ev, usr, st, ss, pos, age);
