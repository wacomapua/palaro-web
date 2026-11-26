-- =============================================================================
-- Venue marketplace — tables, indexes, RPCs
-- =============================================================================
-- Two-sided marketplace: venues post bookable slots on a hierarchical court
-- tree; team captains (or individuals) book + pay; the platform takes 5% and
-- pays the venue weekly.
--
-- Concurrency: bookings always go through `book_venue_slot` which uses an
-- advisory lock keyed on (venue_id, hour-bucket) plus a recursive CTE that
-- walks ancestors + descendants of the target court — so booking 'Q1' fails
-- if the parent 'Full Pitch' is already taken (and vice versa).
-- =============================================================================

-- ---------- new enums ----------
create type venue_status as enum ('pending_review', 'active', 'suspended');
create type venue_slot_status as enum ('available', 'held', 'booked', 'cancelled', 'closed');
create type venue_booking_status as enum (
  'pending_payment', 'paid', 'cancelled', 'refunded', 'completed'
);
create type venue_payout_status as enum ('pending', 'paid', 'failed');
create type venue_sport as enum ('football', 'basketball', 'tennis', 'pickleball', 'volleyball');

-- ---------- venues ----------
-- A bookable place. Owned by exactly one profile in v1; co-owners come later.
create table public.venues (
  id uuid primary key default gen_random_uuid(),
  slug citext unique not null,
  name text not null,
  sport venue_sport not null,
  address text not null,
  city text,
  -- v1: lat/lng only. PostGIS upgrade comes with the map view in Phase 2.
  lat double precision,
  lng double precision,
  phone text,
  description text,
  cover_image_url text,
  owner_id uuid not null references public.profiles(id) on delete restrict,
  status venue_status not null default 'pending_review',
  currency text not null default 'PHP',
  -- payout_method: { method: 'gcash'|'bank', gcash_number?, bank_name?, account_no?, account_name? }
  payout_method jsonb,
  -- Default refund tiers; venues can override per-slot. Hours are pre-start.
  default_refund_policy jsonb not null default
    '{"tiers":[{"hours_before":48,"refund_pct":100},{"hours_before":24,"refund_pct":50},{"hours_before":0,"refund_pct":0}]}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index venues_owner_idx on public.venues(owner_id);
create index venues_sport_status_idx on public.venues(sport, status) where status = 'active';
create index venues_geo_idx on public.venues(lat, lng) where status = 'active';

-- ---------- venue_courts (the tree) ----------
-- Self-referential: parent_court_id null = root. Booking a node locks all
-- ancestors AND all descendants at the booked timeblock (handled in
-- `book_venue_slot`). Examples:
--   Football: Full Pitch -> {N Half, S Half} -> {Q1, Q2, Q3, Q4}
--   Pickleball derived: Tennis Court 1 -> {PB-1, PB-2, PB-3, PB-4}
create table public.venue_courts (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete cascade,
  parent_court_id uuid references public.venue_courts(id) on delete cascade,
  name text not null,
  -- Free text by design: 'pitch' | 'half' | 'quarter' | 'court' | 'derived' …
  -- A new sport's vocabulary shouldn't require a migration.
  kind text,
  sort_order int not null default 0,
  capacity int,
  metadata jsonb,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  -- A court can't be its own parent. Deeper cycles are blocked at app layer +
  -- by the recursive CTE in `book_venue_slot` (which would loop forever and
  -- error on a real cycle thanks to PG's recursion limit).
  constraint courts_no_self_parent check (id is distinct from parent_court_id)
);

create index venue_courts_venue_idx on public.venue_courts(venue_id, parent_court_id, sort_order);

-- ---------- venue_slot_templates ----------
-- Schema for v1.5; no UI in v1. Lets venues define recurring weekly inventory
-- ('Mon-Fri 6-8pm + 8-10pm at ₱2000 per quarter'). The slot generator (added
-- in 1.5) materialises rows into venue_slots so the booking lock targets a
-- real PK.
create table public.venue_slot_templates (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete cascade,
  court_id uuid not null references public.venue_courts(id) on delete cascade,
  -- 0 = Sunday … 6 = Saturday (matches JS Date.getDay)
  day_of_week int not null check (day_of_week between 0 and 6),
  start_time time not null,
  end_time time not null,
  price_cents int not null check (price_cents >= 0),
  refund_policy jsonb,
  active boolean not null default true,
  paused_until date,
  created_at timestamptz not null default now()
);

create index slot_templates_venue_idx on public.venue_slot_templates(venue_id, active);

-- ---------- venue_slots (the bookable units) ----------
create table public.venue_slots (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete cascade,
  court_id uuid not null references public.venue_courts(id) on delete restrict,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  price_cents int not null check (price_cents >= 0),
  currency text not null default 'PHP',
  status venue_slot_status not null default 'available',
  refund_policy jsonb,                              -- override venue.default_refund_policy
  -- Reserved for ~10 min while PayMongo confirms. Cron releases stale holds.
  held_until timestamptz,
  generated_from_template_id uuid references public.venue_slot_templates(id) on delete set null,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  constraint slot_time_valid check (ends_at > starts_at)
);

create index venue_slots_venue_court_time_idx on public.venue_slots(venue_id, court_id, starts_at);
create index venue_slots_court_status_idx on public.venue_slots(court_id, status, starts_at);
-- Prevents an operator (or buggy template generation) from creating two
-- physical slots on the exact same court+window. Tree-level conflict
-- detection happens in `book_venue_slot`, not here.
create unique index venue_slots_unique_court_window
  on public.venue_slots(court_id, starts_at, ends_at);

-- ---------- venue_bookings ----------
-- team_id is nullable: pickleball/tennis players often book as individuals
-- and don't get an auto-draft event. captain_user_id is who paid.
create table public.venue_bookings (
  id uuid primary key default gen_random_uuid(),
  slot_id uuid not null references public.venue_slots(id) on delete restrict,
  venue_id uuid not null references public.venues(id) on delete restrict,
  team_id uuid references public.teams(id) on delete set null,
  captain_user_id uuid not null references public.profiles(id) on delete restrict,
  event_id uuid references public.events(id) on delete set null,
  total_cents int not null check (total_cents >= 0),
  platform_fee_cents int not null check (platform_fee_cents >= 0),
  payout_cents int not null check (payout_cents >= 0),
  status venue_booking_status not null default 'pending_payment',
  paymongo_intent_id text,
  refund_amount_cents int not null default 0,
  refund_reason text,
  refunded_at timestamptz,
  payout_id uuid,
  metadata jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index bookings_venue_status_idx on public.venue_bookings(venue_id, status, created_at desc);
create index bookings_captain_idx on public.venue_bookings(captain_user_id, created_at desc);
create index bookings_team_idx on public.venue_bookings(team_id);
create index bookings_intent_idx on public.venue_bookings(paymongo_intent_id);

-- ---------- venue_payouts ----------
create table public.venue_payouts (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete restrict,
  period_start date not null,
  period_end date not null,
  gross_cents int not null check (gross_cents >= 0),
  fees_cents int not null check (fees_cents >= 0),
  net_cents int not null check (net_cents >= 0),
  currency text not null default 'PHP',
  status venue_payout_status not null default 'pending',
  -- Snapshot of venue.payout_method at payout time so editing later doesn't
  -- rewrite history.
  payout_method_snapshot jsonb,
  gateway_ref text,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  unique (venue_id, period_start, period_end)
);

alter table public.venue_bookings
  add constraint bookings_payout_fk
  foreign key (payout_id) references public.venue_payouts(id) on delete set null;

-- ---------- events: backlink ----------
-- Captures the 'this event was created from a paid venue booking' link.
-- Nullable: events created the old way (manual /event/new) keep this null.
alter table public.events
  add column venue_booking_id uuid references public.venue_bookings(id) on delete set null;

create index events_venue_booking_idx on public.events(venue_booking_id);

-- =============================================================================
-- RPCs
-- =============================================================================

-- ---------- book_venue_slot ----------
-- Atomically reserves a slot for `_hold_minutes`. Called from the edge
-- function `payments-create-intent` (service role) before the PayMongo intent
-- is created. The webhook confirms (or expiry releases).
create or replace function public.book_venue_slot(
  _slot_id uuid,
  _captain_user_id uuid,
  _team_id uuid,
  _hold_minutes int default 10
) returns table (
  booking_id uuid,
  slot_id uuid,
  total_cents int,
  platform_fee_cents int,
  payout_cents int,
  currency text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  _slot record;
  _conflict_count int;
  _platform_fee_pct numeric;
  _total int;
  _fee int;
  _booking_id uuid;
  _lock_key bigint;
begin
  -- 1. Lock the target slot row (FOR UPDATE serialises with concurrent edits
  --    on this exact row — e.g. owner editing price).
  select s.*, v.currency as v_currency
    into _slot
    from public.venue_slots s
    join public.venues v on v.id = s.venue_id
   where s.id = _slot_id
   for update of s;

  if not found then
    raise exception 'Slot not found' using errcode = 'no_data_found';
  end if;

  -- Slot must be available, OR a stale held that hasn't been cleaned up yet.
  if _slot.status <> 'available'
     and not (_slot.status = 'held' and (_slot.held_until is null or _slot.held_until < now())) then
    raise exception 'Slot is not available (status=%, held_until=%)',
      _slot.status, _slot.held_until using errcode = 'check_violation';
  end if;

  -- 2. Advisory lock keyed on (venue, hour-bucket) — serialises concurrent
  --    bookers touching the same venue+hour regardless of which court row
  --    they target. Auto-releases at COMMIT.
  _lock_key := hashtextextended(
    _slot.venue_id::text || ':' ||
    to_char(date_trunc('hour', _slot.starts_at), 'YYYYMMDDHH24'),
    0
  );
  perform pg_advisory_xact_lock(_lock_key);

  -- 3. Tree walk: ancestors + descendants of the target court.
  with recursive ancestors as (
    select c.id, c.parent_court_id
      from public.venue_courts c
     where c.id = _slot.court_id
    union all
    select c.id, c.parent_court_id
      from public.venue_courts c
      join ancestors a on c.id = a.parent_court_id
  ),
  descendants as (
    select c.id, c.parent_court_id
      from public.venue_courts c
     where c.id = _slot.court_id
    union all
    select c.id, c.parent_court_id
      from public.venue_courts c
      join descendants d on c.parent_court_id = d.id
  ),
  related as (
    select id from ancestors
    union
    select id from descendants
  )
  -- 4. Any overlapping slot on a related court that is booked, or held with
  --    a non-expired hold, is a conflict.
  select count(*) into _conflict_count
    from public.venue_slots s
   where s.id <> _slot_id
     and s.court_id in (select id from related)
     and s.starts_at < _slot.ends_at
     and s.ends_at   > _slot.starts_at
     and (
       s.status = 'booked'
       or (s.status = 'held' and s.held_until is not null and s.held_until > now())
     );

  if _conflict_count > 0 then
    raise exception 'Court conflict: another overlapping booking exists on this court tree'
      using errcode = 'check_violation';
  end if;

  -- 5. Compute fees + write rows.
  -- GUC fallback to 5% if not set. (Edge function sets via `set local`.)
  _platform_fee_pct := coalesce(current_setting('app.platform_fee_pct_venue', true)::numeric, 5);
  _total := _slot.price_cents;
  _fee   := round(_total * _platform_fee_pct / 100);

  insert into public.venue_bookings (
    slot_id, venue_id, team_id, captain_user_id,
    total_cents, platform_fee_cents, payout_cents, status
  ) values (
    _slot_id, _slot.venue_id, _team_id, _captain_user_id,
    _total, _fee, _total - _fee, 'pending_payment'
  )
  returning id into _booking_id;

  update public.venue_slots
     set status = 'held',
         held_until = now() + make_interval(mins => _hold_minutes)
   where id = _slot_id;

  return query
    select _booking_id, _slot_id, _total, _fee, _total - _fee, _slot.v_currency;
end;
$$;

-- ---------- complete_venue_booking ----------
-- Called from the webhook on payment_intent.payment.paid. Single transaction:
-- flips booking + slot, writes the ledger row, and (if team_id set) inserts
-- the auto-draft event. Idempotent: re-invocation on an already-paid booking
-- is a no-op.
create or replace function public.complete_venue_booking(
  _intent_id text
) returns table (
  booking_id uuid,
  event_id uuid,
  status venue_booking_status
)
language plpgsql
security definer
set search_path = public
as $$
declare
  _booking record;
  _slot record;
  _venue record;
  _court record;
  _event_id uuid;
  _slot_count int;
  _slot_fee_cents int;
  _event_title text;
begin
  select b.* into _booking
    from public.venue_bookings b
   where b.paymongo_intent_id = _intent_id
   for update;

  if not found then
    raise exception 'No booking for intent %', _intent_id using errcode = 'no_data_found';
  end if;

  -- Idempotency.
  if _booking.status in ('paid', 'completed', 'cancelled', 'refunded') then
    return query select _booking.id, _booking.event_id, _booking.status;
    return;
  end if;

  select s.* into _slot from public.venue_slots s where s.id = _booking.slot_id for update;
  select v.* into _venue from public.venues v where v.id = _booking.venue_id;
  select c.* into _court from public.venue_courts c where c.id = _slot.court_id;

  -- Race: the hold expired before the webhook arrived AND someone else
  -- booked the slot meanwhile. Mark the booking cancelled; the caller is
  -- responsible for refunding via PayMongo.
  if _slot.status = 'booked' and _slot.id <> _booking.slot_id then
    update public.venue_bookings
       set status = 'cancelled',
           refund_reason = 'Slot taken before payment confirmed',
           updated_at = now()
     where id = _booking.id;
    return query select _booking.id, _booking.event_id, 'cancelled'::venue_booking_status;
    return;
  end if;

  -- Re-grab the slot (idempotent if our hold is still valid).
  update public.venue_slots
     set status = 'booked', held_until = null
   where id = _slot.id;

  update public.venue_bookings
     set status = 'paid', updated_at = now()
   where id = _booking.id;

  -- Ledger: a venue_booking transaction. user_id = captain_user_id.
  insert into public.transactions (
    team_id, user_id, type, amount_cents, currency,
    platform_fee_cents, gateway, gateway_ref, status, metadata
  ) values (
    _booking.team_id, _booking.captain_user_id, 'venue_booking',
    _booking.total_cents, _venue.currency,
    _booking.platform_fee_cents, 'paymongo', _intent_id, 'succeeded',
    jsonb_build_object(
      'booking_id', _booking.id,
      'slot_id', _slot.id,
      'venue_id', _venue.id,
      'court_id', _court.id
    )
  );

  -- Auto-draft event only if a team is attached.
  if _booking.team_id is not null then
    -- Sport-aware default for max players when court.capacity is unset.
    -- Capacity is "total players the court fits"; slot_count (max active
    -- players on the team for this event) is half that, with a sane floor.
    _slot_count := greatest(
      coalesce(_court.capacity / 2, case _venue.sport
        when 'football'   then 11
        when 'basketball' then 5
        when 'tennis'     then 2
        when 'pickleball' then 2
        when 'volleyball' then 6
      end),
      1
    );
    _slot_fee_cents := ceil(_booking.total_cents::numeric / _slot_count)::int;
    _event_title := 'Match at ' || _venue.name;

    insert into public.events (
      team_id, title, type, status, location,
      starts_at, ends_at, slot_count, reserve_count,
      slot_fee_cents, currency, flake_fee_cents,
      created_by, venue_booking_id
    ) values (
      _booking.team_id, _event_title, 'match', 'draft',
      _venue.name || ' · ' || _venue.address,
      _slot.starts_at, _slot.ends_at, _slot_count, 3,
      _slot_fee_cents, _venue.currency, 0,
      _booking.captain_user_id, _booking.id
    )
    returning id into _event_id;

    update public.venue_bookings
       set event_id = _event_id, updated_at = now()
     where id = _booking.id;
  end if;

  return query select _booking.id, _event_id, 'paid'::venue_booking_status;
end;
$$;

-- ---------- cancel_venue_booking ----------
-- Computes the tiered refund amount and flips the booking. Does NOT call
-- PayMongo /refunds (that's the edge function's job). The edge function
-- writes a 'venue_refund' transactions row after PayMongo confirms.
create or replace function public.cancel_venue_booking(
  _booking_id uuid,
  _reason text default null
) returns table (
  booking_id uuid,
  refund_amount_cents int,
  hours_before numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  _booking record;
  _slot record;
  _venue record;
  _policy jsonb;
  _hours_before numeric;
  _refund_pct int;
  _refund_amt int;
  _tier jsonb;
  _is_owner boolean;
  _is_captain boolean;
begin
  select b.* into _booking from public.venue_bookings b where b.id = _booking_id for update;
  if not found then raise exception 'Booking not found' using errcode = 'no_data_found'; end if;

  if _booking.status not in ('pending_payment', 'paid') then
    raise exception 'Booking cannot be cancelled in status %', _booking.status using errcode = 'check_violation';
  end if;

  -- Authorization: captain who paid OR venue owner.
  _is_captain := _booking.captain_user_id = auth.uid();
  _is_owner := exists (
    select 1 from public.venues v
     where v.id = _booking.venue_id and v.owner_id = auth.uid()
  );
  if not (_is_captain or _is_owner) then
    raise exception 'Not authorized to cancel this booking' using errcode = 'insufficient_privilege';
  end if;

  select s.* into _slot from public.venue_slots s where s.id = _booking.slot_id for update;
  select v.* into _venue from public.venues v where v.id = _booking.venue_id;

  -- Slot-level policy beats venue-level default.
  _policy := coalesce(_slot.refund_policy, _venue.default_refund_policy);
  _hours_before := extract(epoch from (_slot.starts_at - now())) / 3600.0;

  -- Walk tiers (already ordered by hours_before desc in the seed). Pick the
  -- first whose threshold is <= hours_before remaining.
  _refund_pct := 0;
  for _tier in select * from jsonb_array_elements(_policy->'tiers') loop
    if _hours_before >= (_tier->>'hours_before')::numeric then
      _refund_pct := (_tier->>'refund_pct')::int;
      exit;
    end if;
  end loop;

  _refund_amt := round(_booking.total_cents * _refund_pct / 100.0)::int;

  update public.venue_bookings
     set status = case when _refund_amt > 0 then 'refunded' else 'cancelled' end,
         refund_amount_cents = _refund_amt,
         refund_reason = coalesce(_reason, _booking.refund_reason),
         refunded_at = case when _refund_amt > 0 then now() else null end,
         updated_at = now()
   where id = _booking.id;

  -- Slot goes back to available so the venue can resell it.
  update public.venue_slots
     set status = 'available', held_until = null
   where id = _slot.id;

  -- Cancel any auto-created event (captain may have already published it,
  -- but the cancellation should still propagate).
  if _booking.event_id is not null then
    update public.events
       set status = 'cancelled'
     where id = _booking.event_id;
  end if;

  return query select _booking.id, _refund_amt, _hours_before;
end;
$$;

-- =============================================================================
-- Cron: release stale holds
-- =============================================================================
-- Every minute, any held slot whose `held_until` has passed flips back to
-- 'available'. The booking row stays in 'pending_payment' so a late webhook
-- can still find it via paymongo_intent_id; `complete_venue_booking` handles
-- the race (re-grab if still free, else cancel + refund).
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule(
      'release-stale-venue-holds',
      '* * * * *',
      $cron$
        update public.venue_slots
           set status = 'available', held_until = null
         where status = 'held'
           and held_until is not null
           and held_until < now()
      $cron$
    );
  end if;
end $$;
