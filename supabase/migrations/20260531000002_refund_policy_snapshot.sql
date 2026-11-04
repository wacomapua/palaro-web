-- 20260531000002_refund_policy_snapshot.sql
-- PR #8 review fixes (P3).
--
--   1. Refund policy snapshot (owner decision 1, contract C3 P3 part). A
--      booking is refunded under the policy in force when it was made, so
--      editing the venue default or a slot override never changes the refund
--      on a booking already sold.
--        * venue_bookings.refund_policy_snapshot jsonb (new column).
--        * book_venue_slot writes
--          coalesce(slot.refund_policy, venue.default_refund_policy).
--        * cancel_venue_booking resolves
--          coalesce(booking.refund_policy_snapshot, slot.refund_policy, venue.default_refund_policy).
--        * Existing bookings that are not cancelled are backfilled with the
--          policy in force now, so later edits do not change them either.
--      Both functions are redefined from their 20260531000001 versions with
--      only those changes.
--   2. swap_venue_court_sort_order (PR #8 review, finding 4): a court move
--      swaps two sibling courts' sort_order in one owner checked transaction
--      (section 4).

-- =============================================================================
-- 1. Column and backfill
-- =============================================================================
alter table public.venue_bookings add column if not exists refund_policy_snapshot jsonb;

comment on column public.venue_bookings.refund_policy_snapshot is
  'Refund policy in force when the booking was made: coalesce(slot.refund_policy, venue.default_refund_policy) at book time. cancel_venue_booking prefers it over the slot and venue policies. Written only by definer functions.';

-- Bookings made before this column existed: freeze the policy in force now.
-- Cancelled bookings are finished and keep none. Only rows without a snapshot
-- are touched, so a rerun changes nothing.
update public.venue_bookings b
   set refund_policy_snapshot = coalesce(s.refund_policy, v.default_refund_policy)
  from public.venue_slots s, public.venues v
 where s.id = b.slot_id
   and v.id = b.venue_id
   and b.status <> 'cancelled'
   and b.refund_policy_snapshot is null;

-- =============================================================================
-- 2. book_venue_slot: snapshot the effective policy
-- =============================================================================
-- Body as 20260531000001; the venue's default policy is read with the slot and
-- both inserts write refund_policy_snapshot.
create or replace function public.book_venue_slot(
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

  select s.*, v.currency as v_currency, v.default_refund_policy as v_refund_policy
    into _slot
    from public.venue_slots s
    join public.venues v on v.id = s.venue_id
   where s.id = _slot_id
   for update of s;

  if not found then
    raise exception 'Slot not found' using errcode = 'no_data_found';
  end if;

  -- Closures win over every other state. The wording keeps "not available"
  -- so payments-create-intent maps it to a 409 like other conflicts.
  if public.venue_window_closed(_slot.venue_id, _slot.court_id, _slot.starts_at, _slot.ends_at) then
    raise exception 'Slot closed: the venue is not available at this time'
      using errcode = 'check_violation';
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
      party_size, total_cents, platform_fee_cents, payout_cents, status,
      refund_policy_snapshot
    ) values (
      _slot_id, _slot.venue_id, _team_id, _captain_user_id,
      _party_size, _total, _fee, _total - _fee, 'pending_payment',
      coalesce(_slot.refund_policy, _slot.v_refund_policy)
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
    party_size, total_cents, platform_fee_cents, payout_cents, status,
    refund_policy_snapshot
  ) values (
    _slot_id, _slot.venue_id, _team_id, _captain_user_id,
    _party_size, _total, _fee, _total - _fee, 'pending_payment',
    coalesce(_slot.refund_policy, _slot.v_refund_policy)
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

-- =============================================================================
-- 3. cancel_venue_booking: refund under the snapshot
-- =============================================================================
-- Body as 20260531000001; only the policy resolution changes.
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

  _policy := coalesce(_booking.refund_policy_snapshot, _slot.refund_policy, _venue.default_refund_policy);
  _hours_before := extract(epoch from (_slot.starts_at - now())) / 3600.0;

  _refund_pct := 0;
  for _tier in
    select t.value
      from jsonb_array_elements(_policy->'tiers') t(value)
     order by (t.value->>'hours_before')::numeric desc
  loop
    if _hours_before >= (_tier->>'hours_before')::numeric then
      _refund_pct := (_tier->>'refund_pct')::int;
      exit;
    end if;
  end loop;

  _refund_amt := round(_booking.total_cents * _refund_pct / 100.0)::int;

  update public.venue_bookings
     set status = (case when _refund_amt > 0 then 'refunded' else 'cancelled' end)::venue_booking_status,
         refund_amount_cents = _refund_amt,
         refund_reason = coalesce(_reason, _booking.refund_reason),
         refunded_at = case when _refund_amt > 0 then now() else null end,
         updated_at = now()
   where id = _booking.id;

  -- Free the slot. For shared (golf) tee times this just returns a spot to the
  -- pool. Inside a closure the venue_slots_respect_closures trigger stores
  -- 'closed' instead.
  update public.venue_slots
     set status = 'available', held_until = null
   where id = _slot.id;

  if _booking.event_id is not null then
    update public.events
       set status = 'cancelled'
     where id = _booking.event_id;
  end if;

  return query select _booking.id, _refund_amt, _hours_before;
end;
$$;

-- =============================================================================
-- 4. swap_venue_court_sort_order
-- =============================================================================
-- venue_courts.sort_order is one sequence across the whole venue: the layout
-- builder numbers every sport in one run and the calendar orders all roots by
-- it. A move therefore swaps the two courts' existing values and no other
-- court changes. The courts must be siblings: same venue, same parent, same
-- sport. If the venue holds duplicate values (the earlier per group
-- renumbering left some), the whole venue is first renumbered 0..n-1 in its
-- current order (sort_order, created_at, id; the courts page sorts the same
-- way). Every court row of the venue is locked before anything is read for
-- the swap, so concurrent moves run one after the other.
create or replace function public.swap_venue_court_sort_order(
  _court_id uuid,
  _other_court_id uuid
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  _venue_id uuid;
  _a public.venue_courts;
  _b public.venue_courts;
begin
  if _court_id is null or _other_court_id is null or _court_id = _other_court_id then
    raise exception 'Pick two different courts to swap' using errcode = 'invalid_parameter_value';
  end if;

  select c.venue_id into _venue_id from public.venue_courts c where c.id = _court_id;
  if _venue_id is null then
    raise exception 'Court not found' using errcode = 'no_data_found';
  end if;

  if not public.is_venue_owner(_venue_id) then
    raise exception 'Not authorized to reorder these courts' using errcode = 'insufficient_privilege';
  end if;

  perform 1 from public.venue_courts c where c.venue_id = _venue_id order by c.id for update;

  select c.* into _a from public.venue_courts c where c.id = _court_id;
  select c.* into _b from public.venue_courts c where c.id = _other_court_id;
  if _a.id is null or _b.id is null then
    raise exception 'Court not found' using errcode = 'no_data_found';
  end if;

  if _b.venue_id <> _a.venue_id
     or _b.parent_court_id is distinct from _a.parent_court_id
     or _b.sport <> _a.sport then
    raise exception 'Only courts in the same list can swap places'
      using errcode = 'invalid_parameter_value';
  end if;

  if exists (
    select 1 from public.venue_courts c
     where c.venue_id = _venue_id
     group by c.sort_order
    having count(*) > 1
  ) then
    update public.venue_courts c
       set sort_order = r.rn
      from (
        select x.id, (row_number() over (order by x.sort_order, x.created_at, x.id) - 1)::int as rn
          from public.venue_courts x
         where x.venue_id = _venue_id
      ) r
     where c.id = r.id
       and c.sort_order <> r.rn;

    select c.* into _a from public.venue_courts c where c.id = _court_id;
    select c.* into _b from public.venue_courts c where c.id = _other_court_id;
  end if;

  update public.venue_courts c
     set sort_order = case when c.id = _a.id then _b.sort_order else _a.sort_order end
   where c.id in (_a.id, _b.id);
end;
$$;

revoke execute on function public.swap_venue_court_sort_order(uuid, uuid) from public, anon;
grant execute on function public.swap_venue_court_sort_order(uuid, uuid) to authenticated, service_role;
