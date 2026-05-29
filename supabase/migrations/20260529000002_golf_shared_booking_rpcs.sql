-- 20260529000002_golf_shared_booking_rpcs.sql
-- Make the booking RPCs shared-slot (golf tee-time) aware.
--
-- Builds on 20260529000001 (which added venue_slots.booking_mode/pricing_mode/
-- max_players/price_per_player_cents, venue_bookings.party_size, and the
-- check_slot_capacity trigger).
--
-- Contract delivered to the mobile/edge layer:
--   book_venue_slot(_slot_id, _captain_user_id, _team_id,
--                   _party_size int default 1, _hold_minutes int default 10,
--                   _platform_fee_pct numeric default 5)
--     -> (booking_id, slot_id, total_cents, platform_fee_cents,
--         payout_cents, currency, party_size)
--   venue_slot_remaining(_slot_id) -> int   (spots left; callable by clients)
--
-- Idempotent: drop/create-or-replace throughout.

-- ---------------------------------------------------------------------------
-- 1) Scope the capacity trigger to SHARED slots only.
--    Exclusive (court-sport) availability is governed by slot.status + the
--    court-tree conflict check inside book_venue_slot, exactly as before — the
--    trigger must NOT second-guess it (stale pending_payment rows would
--    otherwise wrongly block a legitimately-released slot from re-booking).
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
    return NEW; -- cancelled/refunded never consume capacity
  end if;

  select booking_mode, max_players
    into v_mode, v_cap
    from venue_slots
    where id = NEW.slot_id
    for update;

  -- Only shared (tee-time) slots are capacity-pooled. Exclusive slots are
  -- left entirely to book_venue_slot's status/conflict logic.
  if coalesce(v_mode, 'exclusive') = 'shared' then
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
  end if;

  return NEW;
end;
$$;

-- ---------------------------------------------------------------------------
-- 2) Remaining-spots read path. SECURITY DEFINER so clients get a spots-left
--    count without RLS access to individual venue_bookings rows.
--      shared    -> max_players - sum(active party_size), floored at 0
--      exclusive -> 1 if the slot is still 'available', else 0
-- ---------------------------------------------------------------------------
create or replace function public.venue_slot_remaining(_slot_id uuid)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select case
    when coalesce(s.booking_mode, 'exclusive') = 'shared' then
      greatest(
        coalesce(s.max_players, 0) - coalesce((
          select sum(b.party_size)
            from public.venue_bookings b
           where b.slot_id = s.id
             and b.status in ('pending_payment','paid','completed')
        ), 0),
        0
      )
    else
      case when s.status = 'available' then 1 else 0 end
  end
  from public.venue_slots s
  where s.id = _slot_id;
$$;

grant execute on function public.venue_slot_remaining(uuid) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3) book_venue_slot v2 — adds _party_size and a shared-slot branch.
--    Signature changes (new arg + new return column) => drop the old one first.
-- ---------------------------------------------------------------------------
drop function if exists public.book_venue_slot(uuid, uuid, uuid, int, numeric);

create function public.book_venue_slot(
  _slot_id uuid,
  _captain_user_id uuid,
  _team_id uuid,
  _party_size int default 1,
  _hold_minutes int default 10,
  _platform_fee_pct numeric default 5
) returns table (
  booking_id uuid,
  slot_id uuid,
  total_cents int,
  platform_fee_cents int,
  payout_cents int,
  currency text,
  party_size int
)
language plpgsql
security definer
set search_path = public
as $$
declare
  _slot record;
  _conflict_count int;
  _booked int;
  _total int;
  _fee int;
  _booking_id uuid;
  _lock_key bigint;
  _mode text;
begin
  if _party_size < 1 then
    raise exception 'party_size must be >= 1' using errcode = 'check_violation';
  end if;

  select s.*, v.currency as v_currency
    into _slot
    from public.venue_slots s
    join public.venues v on v.id = s.venue_id
   where s.id = _slot_id
   for update of s;

  if not found then
    raise exception 'Slot not found' using errcode = 'no_data_found';
  end if;

  _mode := coalesce(_slot.booking_mode, 'exclusive');

  -- Serialise concurrent bookings on the same venue-hour.
  _lock_key := hashtextextended(
    _slot.venue_id::text || ':' ||
    to_char(date_trunc('hour', _slot.starts_at), 'YYYYMMDDHH24'),
    0
  );
  perform pg_advisory_xact_lock(_lock_key);

  -- ===================== SHARED (golf tee time) =====================
  if _mode = 'shared' then
    if _slot.status <> 'available' then
      raise exception 'Tee time not open (status=%)', _slot.status
        using errcode = 'check_violation';
    end if;

    select coalesce(sum(b.party_size), 0) into _booked
      from public.venue_bookings b
     where b.slot_id = _slot_id
       and b.status in ('pending_payment','paid','completed');

    if _slot.max_players is not null and _booked + _party_size > _slot.max_players then
      raise exception 'Tee time full: % of % spots already booked', _booked, _slot.max_players
        using errcode = 'check_violation';
    end if;

    _total := coalesce(_slot.price_per_player_cents, _slot.price_cents) * _party_size;
    _fee   := round(_total * _platform_fee_pct / 100);

    insert into public.venue_bookings (
      slot_id, venue_id, team_id, captain_user_id,
      party_size, total_cents, platform_fee_cents, payout_cents, status
    ) values (
      _slot_id, _slot.venue_id, _team_id, _captain_user_id,
      _party_size, _total, _fee, _total - _fee, 'pending_payment'
    )
    returning id into _booking_id;

    -- Flip to 'booked' only once the tee time is full; otherwise it stays open
    -- for more players. (trg_check_slot_capacity is the hard backstop.)
    if _slot.max_players is not null and _booked + _party_size >= _slot.max_players then
      update public.venue_slots set status = 'booked', held_until = null where id = _slot_id;
    end if;

    return query
      select _booking_id, _slot_id, _total, _fee, _total - _fee, _slot.v_currency, _party_size;
    return;
  end if;

  -- ===================== EXCLUSIVE (court sports) =====================
  -- Unchanged from 0008 except booking now stores party_size.
  if _slot.status <> 'available'
     and not (_slot.status = 'held' and (_slot.held_until is null or _slot.held_until < now())) then
    raise exception 'Slot is not available (status=%, held_until=%)',
      _slot.status, _slot.held_until using errcode = 'check_violation';
  end if;

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

  _total := _slot.price_cents;
  _fee   := round(_total * _platform_fee_pct / 100);

  insert into public.venue_bookings (
    slot_id, venue_id, team_id, captain_user_id,
    party_size, total_cents, platform_fee_cents, payout_cents, status
  ) values (
    _slot_id, _slot.venue_id, _team_id, _captain_user_id,
    _party_size, _total, _fee, _total - _fee, 'pending_payment'
  )
  returning id into _booking_id;

  update public.venue_slots
     set status = 'held',
         held_until = now() + make_interval(mins => _hold_minutes)
   where id = _slot_id;

  return query
    select _booking_id, _slot_id, _total, _fee, _total - _fee, _slot.v_currency, _party_size;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4) complete_venue_booking — shared-aware. Same signature, so CREATE OR REPLACE.
--    Differences for shared slots:
--      * NO self-cancel race check (multiple paid parties legitimately coexist)
--      * slot flips to 'booked' only when the tee time becomes full
-- ---------------------------------------------------------------------------
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
  _other_booking uuid;
  _mode text;
  _booked int;
begin
  select b.* into _booking
    from public.venue_bookings b
   where b.paymongo_intent_id = _intent_id
   for update;

  if not found then
    raise exception 'No booking for intent %', _intent_id using errcode = 'no_data_found';
  end if;

  if _booking.status in ('paid', 'completed', 'cancelled', 'refunded') then
    return query select _booking.id, _booking.event_id, _booking.status;
    return;
  end if;

  select s.* into _slot from public.venue_slots s where s.id = _booking.slot_id for update;
  select v.* into _venue from public.venues v where v.id = _booking.venue_id;
  select c.* into _court from public.venue_courts c where c.id = _slot.court_id;

  _mode := coalesce(_slot.booking_mode, 'exclusive');

  -- Race detection applies to EXCLUSIVE slots only. On a shared tee time,
  -- several bookings being 'paid' on the same slot is the normal case.
  if _mode <> 'shared' then
    select b.id into _other_booking
      from public.venue_bookings b
     where b.slot_id = _booking.slot_id
       and b.id <> _booking.id
       and b.status in ('paid', 'completed')
     limit 1;

    if _other_booking is not null then
      update public.venue_bookings
         set status = 'cancelled',
             refund_reason = 'Slot taken before payment confirmed',
             updated_at = now()
       where id = _booking.id;
      return query select _booking.id, _booking.event_id, 'cancelled'::venue_booking_status;
      return;
    end if;
  end if;

  update public.venue_bookings
     set status = 'paid', updated_at = now()
   where id = _booking.id;

  if _mode = 'shared' then
    -- Mark the tee time booked only when full; otherwise keep it open.
    select coalesce(sum(b.party_size), 0) into _booked
      from public.venue_bookings b
     where b.slot_id = _slot.id
       and b.status in ('pending_payment','paid','completed');
    if _slot.max_players is not null and _booked >= _slot.max_players then
      update public.venue_slots set status = 'booked', held_until = null where id = _slot.id;
    end if;
  else
    update public.venue_slots
       set status = 'booked', held_until = null
     where id = _slot.id;
  end if;

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
      'court_id', _court.id,
      'party_size', _booking.party_size
    )
  );

  -- Auto-create a match event only for team bookings (golf walk-ups have no team).
  if _booking.team_id is not null then
    _slot_count := greatest(
      coalesce(_court.capacity / 2, case _venue.sport
        when 'football'   then 11
        when 'basketball' then 5
        when 'tennis'     then 2
        when 'pickleball' then 2
        when 'volleyball' then 6
        else 2
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

-- Preserve the security posture from 0007: only service_role may complete.
revoke execute on function public.complete_venue_booking(text) from public;
revoke execute on function public.complete_venue_booking(text) from anon;
revoke execute on function public.complete_venue_booking(text) from authenticated;
grant execute on function public.complete_venue_booking(text) to service_role;
