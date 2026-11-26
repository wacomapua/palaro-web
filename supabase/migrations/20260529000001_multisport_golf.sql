-- 20260529000001_multisport_golf.sql
-- Multi-sport venues + golf tee-time bookings.
--
-- NOTE: this database's sport column is a Postgres ENUM (`venue_sport`), so we
-- extend the enum type rather than use CHECK constraints. New enum values can't
-- be USED in the same transaction that adds them, so this migration is NOT
-- wrapped in a transaction; every statement is individually idempotent and safe
-- to re-run. (The migration only copies existing sport values, never the new
-- ones, so it works in one pass.)
--
-- Apply via the Supabase dashboard SQL editor (recommended for this repo, whose
-- local migration history does not mirror the remote), or `supabase db push`.

-- ---------------------------------------------------------------------------
-- 1) Extend the venue_sport enum. (Auto-commits; unused below, so this is safe.)
-- ---------------------------------------------------------------------------
alter type venue_sport add value if not exists 'golf';
alter type venue_sport add value if not exists 'badminton';
alter type venue_sport add value if not exists 'swimming';
alter type venue_sport add value if not exists 'squash';

-- ---------------------------------------------------------------------------
-- 2) Every court belongs to a specific sport. Backfill from the venue's primary
--    sport (existing enum values only), then require it.
-- ---------------------------------------------------------------------------
alter table venue_courts add column if not exists sport venue_sport;

update venue_courts c
  set sport = v.sport
  from venues v
  where c.venue_id = v.id and c.sport is null;

alter table venue_courts alter column sport set not null;

create index if not exists venue_courts_venue_sport_idx
  on venue_courts (venue_id, sport);

-- ---------------------------------------------------------------------------
-- 3) venue_sports: the set of sports a venue offers (drives discovery / the
--    player-app sport filter). One row per (venue, sport).
-- ---------------------------------------------------------------------------
create table if not exists venue_sports (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references venues(id) on delete cascade,
  sport venue_sport not null,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (venue_id, sport)
);

-- Backfill: each existing venue offers (at minimum) its primary sport, plus any
-- sport that already has courts.
insert into venue_sports (venue_id, sport)
  select id, sport from venues
  on conflict (venue_id, sport) do nothing;

insert into venue_sports (venue_id, sport)
  select distinct venue_id, sport from venue_courts
  on conflict (venue_id, sport) do nothing;

alter table venue_sports enable row level security;

drop policy if exists "venue_sports public read" on venue_sports;
create policy "venue_sports public read" on venue_sports
  for select using (true);

drop policy if exists "venue_sports owner write" on venue_sports;
create policy "venue_sports owner write" on venue_sports
  for all using (
    exists (select 1 from venues v where v.id = venue_sports.venue_id and v.owner_id = auth.uid())
  ) with check (
    exists (select 1 from venues v where v.id = venue_sports.venue_id and v.owner_id = auth.uid())
  );

-- ---------------------------------------------------------------------------
-- 4) Tee-time / shared-slot support on venue_slots. These are NEW columns with
--    no existing enum, so they use text + CHECK (no enum-in-transaction issues).
--    booking_mode = 'exclusive'  -> one booking owns the slot (court sports; existing behaviour)
--    booking_mode = 'shared'     -> multiple bookings share it up to max_players (golf tee times)
--    pricing_mode = 'per_slot'   -> price_cents is the slot total (existing behaviour)
--    pricing_mode = 'per_player' -> price_per_player_cents is charged per player
-- ---------------------------------------------------------------------------
alter table venue_slots add column if not exists max_players int;
alter table venue_slots add column if not exists price_per_player_cents int;

alter table venue_slots add column if not exists booking_mode text not null default 'exclusive';
alter table venue_slots drop constraint if exists venue_slots_booking_mode_check;
alter table venue_slots
  add constraint venue_slots_booking_mode_check
  check (booking_mode in ('exclusive','shared'));

alter table venue_slots add column if not exists pricing_mode text not null default 'per_slot';
alter table venue_slots drop constraint if exists venue_slots_pricing_mode_check;
alter table venue_slots
  add constraint venue_slots_pricing_mode_check
  check (pricing_mode in ('per_slot','per_player'));

-- ---------------------------------------------------------------------------
-- 5) Party size on bookings (number of players this booking brings).
-- ---------------------------------------------------------------------------
alter table venue_bookings add column if not exists party_size int not null default 1;
alter table venue_bookings drop constraint if exists venue_bookings_party_size_check;
alter table venue_bookings
  add constraint venue_bookings_party_size_check
  check (party_size >= 1);

-- ---------------------------------------------------------------------------
-- 6) Overbooking guard. Per slot:
--    - exclusive: at most one active booking
--    - shared:    sum(party_size) of active bookings <= slot.max_players
--    Active = pending_payment | paid | completed.
-- ---------------------------------------------------------------------------
create or replace function check_slot_capacity()
returns trigger
language plpgsql
as $$
declare
  v_mode text;
  v_cap  int;
  v_booked int;
begin
  if NEW.status not in ('pending_payment','paid','completed') then
    return NEW; -- cancelled/refunded bookings never consume capacity
  end if;

  select booking_mode, max_players
    into v_mode, v_cap
    from venue_slots
    where id = NEW.slot_id
    for update;

  if v_mode = 'shared' then
    select coalesce(sum(party_size), 0)
      into v_booked
      from venue_bookings
      where slot_id = NEW.slot_id
        and status in ('pending_payment','paid','completed')
        and id <> NEW.id;

    if v_cap is not null and v_booked + NEW.party_size > v_cap then
      raise exception 'Tee time full: % of % spots already booked', v_booked, v_cap
        using errcode = 'check_violation';
    end if;
  else
    if exists (
      select 1 from venue_bookings
      where slot_id = NEW.slot_id
        and status in ('pending_payment','paid','completed')
        and id <> NEW.id
    ) then
      raise exception 'Slot already booked'
        using errcode = 'check_violation';
    end if;
  end if;

  return NEW;
end;
$$;

drop trigger if exists trg_check_slot_capacity on venue_bookings;
create trigger trg_check_slot_capacity
  before insert or update of party_size, slot_id, status on venue_bookings
  for each row execute function check_slot_capacity();
