-- 20260531000003_booking_security_and_late_payments.sql
-- P4: the database side of late payments, refunds and booking security that
-- the team-manager app and its edge functions call.
--
--   1. venue_slots_remaining(uuid[]) (C5): venue_slot_remaining for up to 500
--      slots in one call, for the tee sheet.

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
