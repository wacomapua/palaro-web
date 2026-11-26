-- 20260529000004_golf_slot_lifecycle.sql
-- Shared-slot (golf tee-time) lifecycle hygiene — addresses PR #2 review:
--   1. A shared slot MUST declare max_players, else all capacity enforcement is
--      bypassed (every guard is `max_players is not null`).
--   2. Abandoned pending_payment golf bookings have no reclaim path: shared
--      slots are never 'held', so the 0005 release-stale-holds cron can't touch
--      them, and the pending_payment row keeps consuming a foursome spot
--      forever. Add a sweep that cancels them past a TTL and re-opens any tee
--      time that is no longer full.

-- ---------- (1) shared slots require max_players ----------
-- Safe to add directly: every shared slot to date is created via the UI, which
-- always sets max_players; exclusive slots keep max_players NULL (allowed).
alter table public.venue_slots drop constraint if exists venue_slots_shared_needs_max;
alter table public.venue_slots
  add constraint venue_slots_shared_needs_max
  check (booking_mode <> 'shared' or max_players is not null);

-- ---------- (2) reclaim abandoned shared bookings ----------
create or replace function public.release_stale_shared_bookings(_ttl_minutes int default 15)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Cancel pending_payment bookings on shared slots that never completed
  -- payment within the TTL. (A late webhook hitting complete_venue_booking
  -- afterwards is idempotent — it returns 'cancelled' and the webhook refunds,
  -- exactly as for the exclusive stale-hold path.)
  update public.venue_bookings b
     set status = 'cancelled',
         refund_reason = coalesce(b.refund_reason, 'Auto-released: payment not completed'),
         updated_at = now()
    from public.venue_slots s
   where b.slot_id = s.id
     and s.booking_mode = 'shared'
     and b.status = 'pending_payment'
     and b.created_at < now() - make_interval(mins => _ttl_minutes);

  -- Re-open any shared slot that was flipped to 'booked' (full) but is no longer
  -- full once stale bookings are cleared, so the freed spots are resellable.
  update public.venue_slots s
     set status = 'available'
   where s.booking_mode = 'shared'
     and s.status = 'booked'
     and coalesce((
       select sum(b.party_size)
         from public.venue_bookings b
        where b.slot_id = s.id
          and b.status in ('pending_payment','paid','completed')
     ), 0) < s.max_players;
end;
$$;

revoke execute on function public.release_stale_shared_bookings(int) from public;
revoke execute on function public.release_stale_shared_bookings(int) from anon;
revoke execute on function public.release_stale_shared_bookings(int) from authenticated;
grant execute on function public.release_stale_shared_bookings(int) to service_role;

-- Schedule it every minute (mirrors the 0005 release-stale-holds pattern;
-- cron.schedule upserts by job name, so this is idempotent / re-runnable).
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule(
      'release-stale-shared-bookings',
      '* * * * *',
      $cron$ select public.release_stale_shared_bookings(15); $cron$
    );
  end if;
end $$;
