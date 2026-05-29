-- 20260529000003_reconcile_review_followups.sql
-- Reconcile: palaro-dev was only ever at migration 0006. Migrations 0007 and
-- 0008 (review follow-ups) were committed to team-manager but never applied
-- here. Their RPC changes (complete_venue_booking race fix; book_venue_slot
-- fee param) are already superseded by 20260529000002. The remaining pieces —
-- still missing on this DB — are folded forward here idempotently:
--   * drop the stale 4-arg book_venue_slot overload (0005) that 0008 would have
--     removed; otherwise two book_venue_slot overloads coexist (ambiguity).
--   * cancel_venue_booking with the hours_before DESC tier sort (0008 item 1).
--   * release_held_booking_admin — edge-function rollback path (0008 item 3).
-- After this, the live schema matches what 0001-0008 + the golf migrations
-- would produce.

-- ---------- drop the stale book_venue_slot(uuid,uuid,uuid,int) overload ----------
-- The current (correct) signature is the 6-arg one from 20260529000002. The old
-- 0005 4-arg version lingers because 0008 (which dropped it) never ran here.
drop function if exists public.book_venue_slot(uuid, uuid, uuid, int);

-- ---------- cancel_venue_booking — sort refund tiers DESC (0008 item 1) ----------
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

  -- Free the slot. For shared (golf) tee times this just returns a spot to the
  -- pool — remaining is computed from active bookings, so 'available' is correct
  -- whether or not the tee time was full.
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

-- ---------- release_held_booking_admin — edge-function rollback (0008 item 3) ----------
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
  update public.venue_bookings
     set status = 'cancelled',
         refund_reason = coalesce(refund_reason, _reason),
         updated_at = now()
   where id = _booking_id
     and status = 'pending_payment'
  returning slot_id into _slot_id;

  -- Release the slot only if still held (exclusive). Shared tee times are never
  -- 'held', so this no-ops for them — the cancelled booking simply stops
  -- consuming a spot.
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
