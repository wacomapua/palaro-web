-- 20260531000003_booking_security_and_late_payments.sql
-- P4: the database side of late payments, refunds and booking security that
-- the team-manager app and its edge functions call.
--
--   1. venue_slots_remaining(uuid[]) (C5): venue_slot_remaining for up to 500
--      slots in one call, for the tee sheet.
--   2. release_held_booking_admin (C11): frees an exclusive slot only when
--      the hold is this booking's, and reopens a shared tee time that is no
--      longer full.

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
