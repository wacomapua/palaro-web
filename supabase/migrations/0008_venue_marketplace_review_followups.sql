-- =============================================================================
-- Venue marketplace — IMPORTANT review follow-ups
-- =============================================================================
-- Five SQL changes that close out the IMPORTANT findings + new observations
-- from PR #6 re-review:
--   1. cancel_venue_booking sorts refund tiers by hours_before DESC inside the
--      walk so an asc-sorted policy still computes correctly.
--   2. book_venue_slot takes _platform_fee_pct as a parameter (default 5);
--      eliminates the GUC fallback and removes the duplicate 5% sprinkled
--      across edge function + SQL + client.
--   3. New release_held_booking_admin(_booking_id) — atomic rollback for the
--      payments-create-intent error path. Both updates in one transaction
--      with idempotency guards (only flips pending_payment + held). Runs
--      under service_role only.
-- =============================================================================

-- ---------- (1) cancel_venue_booking — sort tiers DESC ----------
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

  _policy := coalesce(_slot.refund_policy, _venue.default_refund_policy);
  _hours_before := extract(epoch from (_slot.starts_at - now())) / 3600.0;

  -- Walk tiers in hours_before DESC order regardless of jsonb storage order.
  -- An asc-sorted policy [{0, 0}, {24, 50}, {48, 100}] would always pick the
  -- 0% tier first under the original implementation.
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
     set status = case when _refund_amt > 0 then 'refunded' else 'cancelled' end,
         refund_amount_cents = _refund_amt,
         refund_reason = coalesce(_reason, _booking.refund_reason),
         refunded_at = case when _refund_amt > 0 then now() else null end,
         updated_at = now()
   where id = _booking.id;

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

-- ---------- (2) book_venue_slot — accept platform fee as a parameter ----------
-- DROP + CREATE rather than CREATE OR REPLACE because Postgres won't allow
-- changing a function's argument signature in place. The old function isn't
-- callable from anywhere outside the edge function, so this is safe.
drop function if exists public.book_venue_slot(uuid, uuid, uuid, int);

create function public.book_venue_slot(
  _slot_id uuid,
  _captain_user_id uuid,
  _team_id uuid,
  _hold_minutes int default 10,
  _platform_fee_pct numeric default 5
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
  _total int;
  _fee int;
  _booking_id uuid;
  _lock_key bigint;
begin
  select s.*, v.currency as v_currency
    into _slot
    from public.venue_slots s
    join public.venues v on v.id = s.venue_id
   where s.id = _slot_id
   for update of s;

  if not found then
    raise exception 'Slot not found' using errcode = 'no_data_found';
  end if;

  if _slot.status <> 'available'
     and not (_slot.status = 'held' and (_slot.held_until is null or _slot.held_until < now())) then
    raise exception 'Slot is not available (status=%, held_until=%)',
      _slot.status, _slot.held_until using errcode = 'check_violation';
  end if;

  _lock_key := hashtextextended(
    _slot.venue_id::text || ':' ||
    to_char(date_trunc('hour', _slot.starts_at), 'YYYYMMDDHH24'),
    0
  );
  perform pg_advisory_xact_lock(_lock_key);

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

  -- Platform fee % now comes in as a parameter from the edge function, which
  -- reads it from PLATFORM_FEE_PCT_VENUE env. Single source of truth at the
  -- env level; default 5 keeps the function callable from psql without args.
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

-- ---------- (3) atomic rollback RPC for edge-function error path ----------
create or replace function public.release_held_booking_admin(
  _booking_id uuid,
  _reason text default 'Released by admin'
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  _slot_id uuid;
begin
  -- Cancel only if still pending_payment — idempotent against state change.
  update public.venue_bookings
     set status = 'cancelled',
         refund_reason = coalesce(refund_reason, _reason),
         updated_at = now()
   where id = _booking_id
     and status = 'pending_payment'
  returning slot_id into _slot_id;

  -- Release the slot only if still held. Other states are someone else's
  -- problem (paid/booked = legitimate; available = already released).
  if _slot_id is not null then
    update public.venue_slots
       set status = 'available',
           held_until = null
     where id = _slot_id
       and status = 'held';
  end if;
end;
$$;

revoke execute on function public.release_held_booking_admin(uuid, text) from public;
revoke execute on function public.release_held_booking_admin(uuid, text) from anon;
revoke execute on function public.release_held_booking_admin(uuid, text) from authenticated;
grant execute on function public.release_held_booking_admin(uuid, text) to service_role;
