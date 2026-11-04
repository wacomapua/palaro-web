-- 20260531000003_booking_security_and_late_payments.sql
-- P4: the database side of late payments, refunds and booking security that
-- the team-manager app and its edge functions call.
--
--   1. venue_slots_remaining(uuid[]) (C5): venue_slot_remaining for up to 500
--      slots in one call, for the tee sheet.
--   2. release_held_booking_admin (C11): frees an exclusive slot only when
--      the hold is this booking's, and reopens a shared tee time that is no
--      longer full.
--   3. reinstate_venue_booking(text) (C4, C11 note): a payment that lands on
--      a booking cancelled before it was paid puts the booking back when the
--      slot still has room, or returns NULL so payments-webhook refunds it.

-- =============================================================================
-- 1. venue_slots_remaining (C5)
-- =============================================================================
-- Same numbers as venue_slot_remaining (20260529000002):
--   shared    -> max_players minus the party sizes of pending_payment, paid
--                and completed bookings, floored at 0
--   exclusive -> 1 while the slot is 'available', else 0
-- One row per known slot; unknown ids are left out and duplicates collapse.
-- SECURITY DEFINER for the same reason as venue_slot_remaining: clients get
-- counts without RLS access to other players' bookings. One pass over the
-- bookings of the requested slots instead of one probe per slot.
create or replace function public.venue_slots_remaining(_slot_ids uuid[])
returns table (slot_id uuid, remaining int)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if cardinality(_slot_ids) > 500 then
    raise exception 'At most 500 slot ids per call (got %)', cardinality(_slot_ids)
      using errcode = 'invalid_parameter_value';
  end if;

  return query
    with booked as (
      select b.slot_id as id, sum(b.party_size)::int as n
        from public.venue_bookings b
       where b.slot_id = any(_slot_ids)
         and b.status in ('pending_payment', 'paid', 'completed')
       group by b.slot_id
    )
    select s.id,
           case
             when coalesce(s.booking_mode, 'exclusive') = 'shared' then
               greatest(coalesce(s.max_players, 0) - coalesce(bk.n, 0), 0)
             else
               case when s.status = 'available' then 1 else 0 end
           end
      from public.venue_slots s
      left join booked bk on bk.id = s.id
     where s.id = any(_slot_ids);
end;
$$;

revoke execute on function public.venue_slots_remaining(uuid[]) from public;
grant execute on function public.venue_slots_remaining(uuid[]) to anon, authenticated, service_role;

-- =============================================================================
-- 2. release_held_booking_admin (C11)
-- =============================================================================
-- Redefined from 20260529000003. payments-webhook (payment failed) and
-- payments-create-intent (intent creation failed) release one pending booking
-- through it. Changes:
--   * Exclusive slot: freed only while the hold is this booking's. Holds are
--     not tagged with their booking, but every exclusive booking is created by
--     book_venue_slot together with a fresh hold, so a booking made on the
--     slot after this one means the hold (if any) belongs to someone else.
--     This one's own hold may have expired and been retaken meanwhile.
--   * Shared tee time: after the cancel, a 'booked' tee time that is no
--     longer full goes back to 'available' (the venue_slots_respect_closures
--     trigger stores 'closed' instead when a closure overlaps).
--   * A booking that is not pending_payment is still a no op.
-- Lock order as complete_venue_booking: the booking row, then the slot row
-- (which also serialises with book_venue_slot's capacity count).
create or replace function public.release_held_booking_admin(
  _booking_id uuid,
  _reason text default 'Released by admin'
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  _b public.venue_bookings;
  _slot public.venue_slots;
  _booked int;
begin
  update public.venue_bookings
     set status = 'cancelled',
         refund_reason = coalesce(refund_reason, _reason),
         updated_at = now()
   where id = _booking_id
     and status = 'pending_payment'
  returning * into _b;

  if _b.id is null then
    return;
  end if;

  select s.* into _slot from public.venue_slots s where s.id = _b.slot_id for update;

  if coalesce(_slot.booking_mode, 'exclusive') = 'shared' then
    select coalesce(sum(b.party_size), 0) into _booked
      from public.venue_bookings b
     where b.slot_id = _slot.id
       and b.status in ('pending_payment', 'paid', 'completed');

    if _slot.status = 'booked' and _slot.max_players is not null and _booked < _slot.max_players then
      update public.venue_slots
         set status = 'available', held_until = null
       where id = _slot.id;
    end if;
  elsif _slot.status = 'held'
        and not exists (
          select 1 from public.venue_bookings o
           where o.slot_id = _slot.id
             and o.id <> _b.id
             and o.created_at >= _b.created_at
        ) then
    update public.venue_slots
       set status = 'available', held_until = null
     where id = _slot.id;
  end if;
end;
$$;

revoke execute on function public.release_held_booking_admin(uuid, text) from public, anon, authenticated;
grant execute on function public.release_held_booking_admin(uuid, text) to service_role;

-- =============================================================================
-- 3. reinstate_venue_booking (C4)
-- =============================================================================
-- Owner decision 2: a payment that arrives after its hold was released (stale
-- hold sweep, release_stale_shared_bookings, a failed intent, or
-- complete_venue_booking cancelling it because the slot was taken or closed)
-- reinstates the booking if the slot still has room and is not closed;
-- otherwise payments-webhook refunds it in full (queue_venue_refund with
-- 'late_payment').
--
-- Only a booking found by its intent in status 'cancelled' that was never
-- paid qualifies: no venue_booking transactions row carries the intent (the
-- row complete_venue_booking and this function write) and no refund is
-- queued for it (a queued refund means the money is already going back).
-- Under the same locks and checks as book_venue_slot (slot row FOR UPDATE,
-- the venue-hour advisory lock, closures, capacity for shared tee times,
-- status and court tree conflicts for exclusive slots) plus
-- complete_venue_booking's "someone else paid" check and "the slot has not
-- started", it marks the booking paid exactly as complete_venue_booking does:
-- same slot update, same transactions row, same match event for a team
-- booking. It also writes the refund policy snapshot when the booking has
-- none (book_venue_slot's coalesce(slot.refund_policy,
-- venue.default_refund_policy)).
--
-- Returns the booking row when it stands (reinstated now, or already paid by
-- an earlier call, so a retry never refunds a reinstated booking) and NULL
-- when it cannot be reinstated. Never raises for "no room".
-- Lock order as complete_venue_booking: booking row, then slot row.
create or replace function public.reinstate_venue_booking(_intent_id text)
returns public.venue_bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  _booking public.venue_bookings;
  _slot record;
  _venue record;
  _court record;
  _mode text;
  _lock_key bigint;
  _booked int;
  _conflict_count int;
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
    return null;
  end if;

  if _booking.status in ('paid', 'completed') then
    return _booking;
  end if;

  if _booking.status <> 'cancelled' then
    return null;
  end if;

  if exists (
    select 1 from public.transactions t
     where t.type = 'venue_booking' and t.gateway_ref = _intent_id
  ) then
    return null;
  end if;

  if exists (select 1 from public.venue_refunds r where r.booking_id = _booking.id) then
    return null;
  end if;

  select s.*, v.default_refund_policy as v_refund_policy
    into _slot
    from public.venue_slots s
    join public.venues v on v.id = s.venue_id
   where s.id = _booking.slot_id
   for update of s;

  if not found then
    return null;
  end if;

  if public.venue_window_closed(_slot.venue_id, _slot.court_id, _slot.starts_at, _slot.ends_at) then
    return null;
  end if;

  if _slot.starts_at <= now() then
    return null;
  end if;

  _mode := coalesce(_slot.booking_mode, 'exclusive');

  -- Serialise with book_venue_slot on the same venue-hour.
  _lock_key := hashtextextended(
    _slot.venue_id::text || ':' ||
    to_char(date_trunc('hour', _slot.starts_at), 'YYYYMMDDHH24'),
    0
  );
  perform pg_advisory_xact_lock(_lock_key);

  if _mode = 'shared' then
    if _slot.status <> 'available' then
      return null;
    end if;

    select coalesce(sum(b.party_size), 0) into _booked
      from public.venue_bookings b
     where b.slot_id = _slot.id
       and b.status in ('pending_payment', 'paid', 'completed');

    if _slot.max_players is not null and _booked + _booking.party_size > _slot.max_players then
      return null;
    end if;
  else
    if _slot.status <> 'available'
       and not (_slot.status = 'held' and (_slot.held_until is null or _slot.held_until < now())) then
      return null;
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
     where s.id <> _slot.id
       and s.court_id in (select id from related)
       and s.starts_at < _slot.ends_at
       and s.ends_at   > _slot.starts_at
       and (
         s.status = 'booked'
         or (s.status = 'held' and s.held_until is not null and s.held_until > now())
       );

    if _conflict_count > 0 then
      return null;
    end if;

    if exists (
      select 1 from public.venue_bookings b
       where b.slot_id = _slot.id
         and b.id <> _booking.id
         and b.status in ('paid', 'completed')
    ) then
      return null;
    end if;
  end if;

  -- From here on, as complete_venue_booking (20260531000001) marks a booking
  -- paid, plus the snapshot.
  select v.* into _venue from public.venues v where v.id = _booking.venue_id;
  select c.* into _court from public.venue_courts c where c.id = _slot.court_id;

  update public.venue_bookings
     set status = 'paid',
         refund_policy_snapshot = coalesce(refund_policy_snapshot, _slot.refund_policy, _slot.v_refund_policy),
         updated_at = now()
   where id = _booking.id;

  if _mode = 'shared' then
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

  select b.* into _booking from public.venue_bookings b where b.id = _booking.id;
  return _booking;
end;
$$;

revoke execute on function public.reinstate_venue_booking(text) from public, anon, authenticated;
grant execute on function public.reinstate_venue_booking(text) to service_role;
