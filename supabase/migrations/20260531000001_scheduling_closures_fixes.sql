-- 20260531000001_scheduling_closures_fixes.sql
-- PR #7 review fixes for weekly schedules, the slot generator and closures.
--
--   1. venue_refunds queue + queue_venue_refund (contract C1).
--   2. Closures are enforced everywhere, across the court tree (C3, P2 part):
--        * book_venue_slot raises `Slot closed ...` (check_violation) when a
--          closure overlaps the slot's court, an ancestor or descendant, or
--          the whole venue.
--        * a BEFORE trigger on venue_slots turns any write that would leave
--          a slot 'available' inside a closure into 'closed'. That covers
--          every release path in one place: cancel_venue_booking,
--          release_held_booking_admin, release_stale_shared_bookings, the
--          release-stale-venue-holds cron statement, the payments-webhook
--          failure path (a direct service role update) and owner edits.
--   3. create_venue_closure (C2) is the only way to create a closure: one
--      transaction inserts it and runs apply_venue_closure, which closes
--      every overlapping slot, cancels paid bookings with a 100% refund
--      queued (owner decision 3) and pending ones without; it returns what
--      it did. This migration runs apply_venue_closure for every closure
--      that already existed and has not ended.
--   3b. complete_venue_booking cancels instead of completing a payment on a
--      slot under a closure, leaving the slot closed.
--   4. replace_venue_slot_templates validates a whole week first, then
--      replaces one court group's templates (sport + booking mode)
--      atomically, so a golf course and its range bays keep separate hours.
--   5. generate_venue_slots: venue local today, future slots only, no
--      overlaps with live slots or within the run, at most 90 local days
--      and 20,000 rows per run, template courts must belong to the venue,
--      closures respected across the court tree.
--   6. cancel_venue_booking: cast its CASE to venue_booking_status. The
--      untyped CASE resolved to text, so every call failed with "column
--      status is of type venue_booking_status but expression is of type text".

-- =============================================================================
-- 1. Refund queue (C1)
-- =============================================================================
create table if not exists public.venue_refunds (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.venue_bookings(id) on delete restrict,
  amount_cents int not null check (amount_cents > 0),
  reason text not null check (reason in ('venue_closure','late_payment','player_cancel')),
  status text not null default 'pending'
    check (status in ('pending','processing','succeeded','failed')),
  paymongo_refund_id text,
  last_error text,
  attempts int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (booking_id, reason)
);

create index if not exists venue_refunds_open_idx
  on public.venue_refunds (created_at) where status in ('pending', 'failed');

create or replace function public.venue_refunds_touch_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists venue_refunds_touch_updated_at on public.venue_refunds;
create trigger venue_refunds_touch_updated_at
  before update on public.venue_refunds
  for each row execute function public.venue_refunds_touch_updated_at();

alter table public.venue_refunds enable row level security;

-- Clients only ever read; every write goes through definer functions or the
-- service role (payments-process-refunds).
revoke all on public.venue_refunds from public, anon, authenticated;
grant select on public.venue_refunds to authenticated;
grant all on public.venue_refunds to service_role;

drop policy if exists venue_refunds_owner_read on public.venue_refunds;
create policy venue_refunds_owner_read on public.venue_refunds
  for select to authenticated using (
    exists (
      select 1 from public.venue_bookings b
       where b.id = venue_refunds.booking_id
         and public.is_venue_owner(b.venue_id)
    )
  );

drop policy if exists venue_refunds_captain_read on public.venue_refunds;
create policy venue_refunds_captain_read on public.venue_refunds
  for select to authenticated using (
    exists (
      select 1 from public.venue_bookings b
       where b.id = venue_refunds.booking_id
         and b.captain_user_id = (select auth.uid())
    )
  );

-- Idempotent on (booking_id, reason): a second call returns the first row's
-- id. Never more than the booking paid.
create or replace function public.queue_venue_refund(
  _booking_id uuid,
  _amount_cents int,
  _reason text
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  _total int;
  _id uuid;
begin
  select b.total_cents into _total from public.venue_bookings b where b.id = _booking_id;
  if not found then
    raise exception 'Booking % not found', _booking_id using errcode = 'no_data_found';
  end if;
  if _amount_cents > _total then
    raise exception 'Refund of % exceeds the % paid for booking %', _amount_cents, _total, _booking_id
      using errcode = 'invalid_parameter_value';
  end if;

  insert into public.venue_refunds (booking_id, amount_cents, reason)
  values (_booking_id, _amount_cents, _reason)
  on conflict (booking_id, reason) do nothing
  returning id into _id;

  if _id is null then
    select r.id into _id from public.venue_refunds r
     where r.booking_id = _booking_id and r.reason = _reason;
  end if;
  return _id;
end;
$$;

revoke execute on function public.queue_venue_refund(uuid, int, text) from public, anon, authenticated;
grant execute on function public.queue_venue_refund(uuid, int, text) to service_role;

-- =============================================================================
-- 2. Closure helpers and enforcement
-- =============================================================================
-- A court, its ancestors and its descendants. UNION (not UNION ALL) stops on
-- a cycle instead of recursing forever.
create or replace function public.venue_court_tree_ids(_court_id uuid)
returns setof uuid
language sql
stable
set search_path = public
as $$
  with recursive up as (
    select c.id, c.parent_court_id from public.venue_courts c where c.id = _court_id
    union
    select p.id, p.parent_court_id
      from public.venue_courts p
      join up on p.id = up.parent_court_id
  ),
  down as (
    select c.id from public.venue_courts c where c.id = _court_id
    union
    select c.id
      from public.venue_courts c
      join down on c.parent_court_id = down.id
  )
  select id from up
  union
  select id from down
$$;

-- True when any closure overlaps [_starts_at, _ends_at) for this court, a
-- court in its tree, or the whole venue. Touching boundaries do not overlap.
create or replace function public.venue_window_closed(
  _venue_id uuid,
  _court_id uuid,
  _starts_at timestamptz,
  _ends_at timestamptz
) returns boolean
language sql
stable
set search_path = public
as $$
  select exists (
    select 1 from public.venue_closures cl
     where cl.venue_id = _venue_id
       and cl.starts_at < _ends_at
       and cl.ends_at > _starts_at
       and (cl.court_id is null or cl.court_id in (select public.venue_court_tree_ids(_court_id)))
  )
$$;

revoke execute on function public.venue_court_tree_ids(uuid) from public, anon, authenticated;
revoke execute on function public.venue_window_closed(uuid, uuid, timestamptz, timestamptz) from public, anon, authenticated;
grant execute on function public.venue_court_tree_ids(uuid) to service_role;
grant execute on function public.venue_window_closed(uuid, uuid, timestamptz, timestamptz) to service_role;

-- A slot inside a closure is never 'available', whoever writes it.
create or replace function public.venue_slots_respect_closures()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'available'
     and public.venue_window_closed(new.venue_id, new.court_id, new.starts_at, new.ends_at) then
    new.status := 'closed';
    new.held_until := null;
  end if;
  return new;
end;
$$;

revoke execute on function public.venue_slots_respect_closures() from public, anon, authenticated;

drop trigger if exists venue_slots_respect_closures on public.venue_slots;
create trigger venue_slots_respect_closures
  before insert or update of status, starts_at, ends_at, court_id on public.venue_slots
  for each row
  when (new.status = 'available')
  execute function public.venue_slots_respect_closures();

-- Closures are created only through create_venue_closure. Owners may still
-- remove their own.
drop policy if exists "venue_closures owner write" on public.venue_closures;
drop policy if exists "venue_closures owner delete" on public.venue_closures;
create policy "venue_closures owner delete" on public.venue_closures
  for delete using (public.is_venue_owner(venue_id));
revoke insert, update on public.venue_closures from anon, authenticated;

-- =============================================================================
-- 3. book_venue_slot: refuse closed windows
-- =============================================================================
-- Same signature and body as 20260529000002, plus the closure check right
-- after the slot row is locked.
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

  select s.*, v.currency as v_currency
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

-- =============================================================================
-- 4. cancel_venue_booking: typed status (body otherwise as 20260529000003)
-- =============================================================================
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
-- 5. create_venue_closure (C2) and apply_venue_closure
-- =============================================================================
-- apply_venue_closure does everything a closure means for one venue_closures
-- row: every unfinished slot it covers (its court tree, or the whole venue)
-- becomes 'closed', paid bookings on them are cancelled with a 100% refund
-- queued, pending ones are cancelled without one, and their match events are
-- cancelled. Idempotent: slots already closed and bookings already cancelled
-- are skipped, and queue_venue_refund never queues a second refund.
--
-- Lock order matches complete_venue_booking and cancel_venue_booking (booking
-- rows, then slot rows) so they never deadlock. Bookings are read again
-- after the slots are locked, which picks up any hold that committed while
-- this call waited for a slot.
create or replace function public.apply_venue_closure(_closure_id uuid)
returns table (
  closed_slot_count int,
  refunded_booking_ids uuid[]
)
language plpgsql
security definer
set search_path = public
as $$
declare
  _cl public.venue_closures;
  _why text;
  _slot_ids uuid[];
  _closed int := 0;
  _refunded uuid[] := '{}';
  _b record;
begin
  select * into _cl from public.venue_closures where id = _closure_id;
  if not found then
    raise exception 'Closure % not found', _closure_id using errcode = 'no_data_found';
  end if;

  _why := 'Venue closure' || coalesce(': ' || nullif(btrim(_cl.reason), ''), '');

  -- Slots under the closure that have not finished. Games already played keep
  -- their payment.
  select coalesce(array_agg(s.id order by s.id), '{}')
    into _slot_ids
    from public.venue_slots s
   where s.venue_id = _cl.venue_id
     and s.starts_at < _cl.ends_at
     and s.ends_at > _cl.starts_at
     and s.ends_at > now()
     and (_cl.court_id is null or s.court_id in (select public.venue_court_tree_ids(_cl.court_id)));

  perform 1 from public.venue_bookings b
   where b.slot_id = any(_slot_ids) and b.status in ('pending_payment', 'paid')
   order by b.id
   for update;

  perform 1 from public.venue_slots s where s.id = any(_slot_ids) order by s.id for update;

  update public.venue_slots s
     set status = 'closed', held_until = null
   where s.id = any(_slot_ids)
     and s.status not in ('closed', 'cancelled');
  get diagnostics _closed = row_count;

  for _b in
    select b.id, b.status, b.total_cents, b.event_id
      from public.venue_bookings b
     where b.slot_id = any(_slot_ids) and b.status in ('pending_payment', 'paid')
     order by b.id
     for update
  loop
    update public.venue_bookings
       set status = 'cancelled',
           refund_amount_cents = case when _b.status = 'paid' then _b.total_cents else refund_amount_cents end,
           refund_reason = _why,
           updated_at = now()
     where id = _b.id;

    if _b.status = 'paid' then
      if _b.total_cents > 0 then
        perform public.queue_venue_refund(_b.id, _b.total_cents, 'venue_closure');
      end if;
      _refunded := _refunded || _b.id;
    end if;

    if _b.event_id is not null then
      update public.events set status = 'cancelled' where id = _b.event_id;
    end if;
  end loop;

  return query select _closed, _refunded;
end;
$$;

revoke execute on function public.apply_venue_closure(uuid) from public, anon, authenticated;
grant execute on function public.apply_venue_closure(uuid) to service_role;

create or replace function public.create_venue_closure(
  _venue_id uuid,
  _court_id uuid,
  _starts_at timestamptz,
  _ends_at timestamptz,
  _reason text
) returns table (
  closure_id uuid,
  closed_slot_count int,
  refunded_booking_ids uuid[]
)
language plpgsql
security definer
set search_path = public
as $$
declare
  _id uuid;
  _closed int;
  _refunded uuid[];
begin
  if not public.is_venue_owner(_venue_id) then
    raise exception 'Not authorized' using errcode = 'insufficient_privilege';
  end if;
  if _starts_at is null or _ends_at is null or _ends_at <= _starts_at then
    raise exception 'Closure end must be after its start' using errcode = 'invalid_parameter_value';
  end if;
  if _ends_at <= now() then
    raise exception 'That closure has already ended' using errcode = 'invalid_parameter_value';
  end if;
  if _court_id is not null and not exists (
    select 1 from public.venue_courts c where c.id = _court_id and c.venue_id = _venue_id
  ) then
    raise exception 'Court does not belong to this venue' using errcode = 'invalid_parameter_value';
  end if;

  insert into public.venue_closures (venue_id, court_id, starts_at, ends_at, reason)
  values (_venue_id, _court_id, _starts_at, _ends_at, nullif(btrim(_reason), ''))
  returning id into _id;

  select a.closed_slot_count, a.refunded_booking_ids
    into _closed, _refunded
    from public.apply_venue_closure(_id) a;

  return query select _id, _closed, _refunded;
end;
$$;

revoke execute on function public.create_venue_closure(uuid, uuid, timestamptz, timestamptz, text) from public, anon;
grant execute on function public.create_venue_closure(uuid, uuid, timestamptz, timestamptz, text) to authenticated, service_role;

-- Closures written before this migration only closed open slots on their own
-- court and left every booking under them alone. Give each one that has not
-- ended the same treatment a new closure gets.
do $$
declare
  _c uuid;
begin
  for _c in
    select id from public.venue_closures where ends_at > now() order by created_at, id
  loop
    perform public.apply_venue_closure(_c);
  end loop;
end $$;

-- =============================================================================
-- 5b. complete_venue_booking: never complete into a closure
-- =============================================================================
-- Same signature and body as 20260529000002, plus a backstop after the slot
-- row is locked: a payment that lands on a slot a closure covers does not
-- make the booking paid. The booking is cancelled and the slot left closed,
-- returned exactly like the "another booking won the slot" race, so the
-- payments-webhook reinstates or refunds the payer (reinstatement rejects
-- closed slots).
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

  -- Closure backstop.
  if public.venue_window_closed(_slot.venue_id, _slot.court_id, _slot.starts_at, _slot.ends_at) then
    update public.venue_bookings
       set status = 'cancelled',
           refund_reason = 'Venue closed before payment confirmed',
           updated_at = now()
     where id = _booking.id;
    update public.venue_slots vs
       set status = 'closed', held_until = null
     where vs.id = _slot.id
       and vs.status in ('available', 'held');
    return query select _booking.id, _booking.event_id, 'cancelled'::venue_booking_status;
    return;
  end if;

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

-- =============================================================================
-- 6. replace_venue_slot_templates
-- =============================================================================
-- A court group is the venue's courts of one sport with one booking mode,
-- read from venue_courts.metadata.slotModel.bookingMode exactly as
-- generate_venue_slots reads it (missing means 'exclusive'). _templates is a
-- JSON array of
--   {day_of_week 0-6 (0 = Sunday), start_time "HH:MM", end_time "HH:MM"
--    (24:00 allowed), slot_minutes 5-1440, price_cents >= 0}
-- Every entry is validated before anything changes; then the group's
-- templates are deleted and one row per active court per entry is written.
-- Returns the number of template rows written.
create or replace function public.replace_venue_slot_templates(
  _venue_id uuid,
  _sport public.venue_sport,
  _booking_mode text,
  _templates jsonb
) returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  _day_names constant text[] := array['Sun','Mon','Tue','Wed','Thu','Fri','Sat'];
  _e jsonb;
  _i int := 0;
  _j int;
  _dow int;
  _start time;
  _end time;
  _mins int;
  _price int;
  _dows int[] := '{}';
  _starts time[] := '{}';
  _ends time[] := '{}';
  _minss int[] := '{}';
  _prices int[] := '{}';
  _active_ids uuid[];
  _all_ids uuid[];
  _rows int;
begin
  if not public.is_venue_owner(_venue_id) then
    raise exception 'Not authorized' using errcode = 'insufficient_privilege';
  end if;
  if _booking_mode is null or _booking_mode not in ('exclusive', 'shared') then
    raise exception 'Booking mode must be exclusive or shared' using errcode = 'invalid_parameter_value';
  end if;
  if _templates is null or jsonb_typeof(_templates) <> 'array' then
    raise exception 'Templates must be a JSON array' using errcode = 'invalid_parameter_value';
  end if;

  for _e in select t.value from jsonb_array_elements(_templates) t(value) loop
    _i := _i + 1;
    if jsonb_typeof(_e) <> 'object' then
      raise exception 'Entry %: must be an object', _i using errcode = 'invalid_parameter_value';
    end if;
    begin
      _dow := (_e->>'day_of_week')::int;
      _start := (_e->>'start_time')::time;
      _end := (_e->>'end_time')::time;
      _mins := (_e->>'slot_minutes')::int;
      _price := (_e->>'price_cents')::int;
    exception when others then
      raise exception 'Entry %: %', _i, sqlerrm using errcode = 'invalid_parameter_value';
    end;
    if _dow is null or _start is null or _end is null or _mins is null or _price is null then
      raise exception 'Entry %: day_of_week, start_time, end_time, slot_minutes and price_cents are all required', _i
        using errcode = 'invalid_parameter_value';
    end if;
    if _dow not between 0 and 6 then
      raise exception 'Entry %: day_of_week must be 0 (Sunday) to 6 (Saturday)', _i using errcode = 'invalid_parameter_value';
    end if;
    if _end <= _start then
      raise exception '%: closing time must be after opening time', _day_names[_dow + 1] using errcode = 'invalid_parameter_value';
    end if;
    if _mins not between 5 and 1440 then
      raise exception '%: slot length must be 5 to 1440 minutes', _day_names[_dow + 1] using errcode = 'invalid_parameter_value';
    end if;
    if _mins > extract(epoch from (_end - _start)) / 60 then
      raise exception '%: slot length is longer than the opening hours', _day_names[_dow + 1] using errcode = 'invalid_parameter_value';
    end if;
    if _price < 0 then
      raise exception '%: price cannot be negative', _day_names[_dow + 1] using errcode = 'invalid_parameter_value';
    end if;
    for _j in 1 .. coalesce(array_length(_dows, 1), 0) loop
      if _dows[_j] = _dow and _starts[_j] < _end and _ends[_j] > _start then
        raise exception '%: opening hours overlap', _day_names[_dow + 1] using errcode = 'invalid_parameter_value';
      end if;
    end loop;
    _dows := _dows || _dow;
    _starts := _starts || _start;
    _ends := _ends || _end;
    _minss := _minss || _mins;
    _prices := _prices || _price;
  end loop;

  select array_agg(c.id) filter (where c.active), array_agg(c.id)
    into _active_ids, _all_ids
    from public.venue_courts c
   where c.venue_id = _venue_id
     and c.sport = _sport
     and coalesce(c.metadata -> 'slotModel' ->> 'bookingMode', 'exclusive') = _booking_mode;

  if _active_ids is null then
    raise exception 'No active % courts with % booking at this venue', _sport, _booking_mode
      using errcode = 'invalid_parameter_value';
  end if;

  -- One save per group at a time, so two tabs cannot interleave their
  -- delete and insert.
  perform pg_advisory_xact_lock(hashtextextended(
    'slot_templates:' || _venue_id::text || ':' || _sport::text || ':' || _booking_mode, 0));

  delete from public.venue_slot_templates t
   where t.venue_id = _venue_id
     and t.court_id = any(_all_ids);

  insert into public.venue_slot_templates (
    venue_id, court_id, day_of_week, start_time, end_time, slot_minutes, price_cents, active
  )
  select _venue_id, c.id, b.dow, b.s, b.e, b.m, b.p, true
    from unnest(_active_ids) as c(id)
   cross join unnest(_dows, _starts, _ends, _minss, _prices) as b(dow, s, e, m, p);
  get diagnostics _rows = row_count;

  return _rows;
end;
$$;

revoke execute on function public.replace_venue_slot_templates(uuid, public.venue_sport, text, jsonb) from public, anon;
grant execute on function public.replace_venue_slot_templates(uuid, public.venue_sport, text, jsonb) to authenticated, service_role;

-- =============================================================================
-- 7. generate_venue_slots
-- =============================================================================
create or replace function public.generate_venue_slots(_venue_id uuid, _through date)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  _max_days constant int := 90;
  _max_rows constant int := 20000;
  _tz text;
  _currency text;
  _today date;
  _longest interval;
  _candidates int;
  _created int := 0;
begin
  if not exists (select 1 from public.venues where id = _venue_id and owner_id = auth.uid()) then
    raise exception 'Not authorized' using errcode = 'insufficient_privilege';
  end if;

  select timezone, currency into _tz, _currency from public.venues where id = _venue_id;
  _tz := coalesce(_tz, 'Asia/Manila');
  _today := (now() at time zone _tz)::date;

  if _through is null then
    raise exception 'Pick a date to generate through' using errcode = 'invalid_parameter_value';
  end if;
  if _through > _today + _max_days then
    raise exception 'Slots can be generated at most 90 days ahead (through %). Pick an earlier date.',
      _today + _max_days using errcode = 'invalid_parameter_value';
  end if;

  -- One run per venue at a time.
  perform pg_advisory_xact_lock(hashtextextended('generate_venue_slots:' || _venue_id::text, 0));

  -- No live slot is longer than this, so an overlapping one must start after
  -- (candidate start - _longest). Keeps the overlap probe an index range scan.
  select coalesce(max(s.ends_at - s.starts_at), interval '0')
    into _longest
    from public.venue_slots s
    join public.venue_courts c on c.id = s.court_id
   where c.venue_id = _venue_id
     and s.status <> 'cancelled';

  with days as (
    select d::date as gen_date
    from generate_series(_today, _through, interval '1 day') as g(d)
  ),
  spans as (
    select
      t.court_id,
      t.price_cents,
      t.slot_minutes,
      t.refund_policy,
      coalesce(c.metadata -> 'slotModel' ->> 'bookingMode', 'exclusive') as booking_mode,
      coalesce(c.metadata -> 'slotModel' ->> 'pricingMode', 'per_slot') as pricing_mode,
      coalesce(nullif(c.metadata -> 'slotModel' ->> 'maxPlayers', '')::int, 4) as max_players,
      ((days.gen_date::timestamp + t.start_time) at time zone _tz) as day_open,
      ((days.gen_date::timestamp + t.end_time) at time zone _tz) as day_close
    from public.venue_slot_templates t
    join public.venue_courts c on c.id = t.court_id and c.venue_id = _venue_id
    join days on extract(dow from days.gen_date)::int = t.day_of_week
    where t.venue_id = _venue_id
      and t.active
      and c.active
      and (t.paused_until is null or days.gen_date > t.paused_until)
  ),
  gen as (
    select
      s.court_id, s.price_cents, s.refund_policy, s.booking_mode, s.pricing_mode, s.max_players,
      gs as starts_at,
      gs + make_interval(mins => s.slot_minutes) as ends_at
    from spans s
    cross join lateral generate_series(
      s.day_open,
      s.day_close - make_interval(mins => s.slot_minutes),
      make_interval(mins => s.slot_minutes)
    ) as gs
    where s.day_close > s.day_open
  ),
  closed as (
    select cl.starts_at, cl.ends_at, null::uuid as court_id
      from public.venue_closures cl
     where cl.venue_id = _venue_id and cl.court_id is null and cl.ends_at > now()
    union all
    select cl.starts_at, cl.ends_at, tree.id
      from public.venue_closures cl
     cross join lateral public.venue_court_tree_ids(cl.court_id) as tree(id)
     where cl.venue_id = _venue_id and cl.court_id is not null and cl.ends_at > now()
  ),
  fresh as (
    select g.*
      from gen g
     where g.starts_at > now()
       -- OFFSET 0 keeps this a per row index probe. As an anti join the
       -- planner (blind to generate_series row counts) hashes on court_id
       -- and compares every candidate with every slot on its court.
       and not exists (
         select 1 from public.venue_slots vs
          where vs.court_id = g.court_id
            and vs.starts_at < g.ends_at
            and vs.starts_at >= g.starts_at - _longest
            and (
              -- The unique (court, window) index counts cancelled slots too.
              (vs.starts_at = g.starts_at and vs.ends_at = g.ends_at)
              or (vs.status <> 'cancelled' and vs.ends_at > g.starts_at)
            )
         offset 0
       )
       and not exists (
         select 1 from closed cl
          where (cl.court_id is null or cl.court_id = g.court_id)
            and cl.starts_at < g.ends_at
            and cl.ends_at > g.starts_at
       )
  ),
  -- Stop reading candidates one past the cap, so an oversized run fails fast
  -- instead of building every row first.
  capped as (
    select * from fresh limit _max_rows + 1
  ),
  total as (
    select count(*)::int as n from capped
  ),
  -- Overlapping bands on one court (templates written outside the editor):
  -- keep a row only when it starts after every earlier row on that court ends.
  cand as (
    select f.*
      from (
        select f.*,
               max(f.ends_at) over (
                 partition by f.court_id order by f.starts_at, f.ends_at
                 rows between unbounded preceding and 1 preceding
               ) as prev_end
          from capped f
      ) f
     where f.prev_end is null or f.prev_end <= f.starts_at
  ),
  ins as (
    insert into public.venue_slots (
      venue_id, court_id, starts_at, ends_at, price_cents, price_per_player_cents,
      currency, status, booking_mode, pricing_mode, max_players, refund_policy,
      generated_from_template_id
    )
    select
      _venue_id, g.court_id, g.starts_at, g.ends_at,
      g.price_cents,
      case when g.pricing_mode = 'per_player' then g.price_cents else null end,
      _currency, 'available', g.booking_mode, g.pricing_mode,
      case when g.booking_mode = 'shared' then g.max_players else null end,
      g.refund_policy,
      null
    from cand g
    where (select n from total) <= _max_rows
    returning 1
  )
  select (select n from total), (select count(*)::int from ins)
    into _candidates, _created;

  if _candidates > _max_rows then
    raise exception 'This run would create more than 20000 slots, the limit per run. Pick an earlier date.'
      using errcode = 'program_limit_exceeded';
  end if;

  return _created;
end;
$$;

revoke execute on function public.generate_venue_slots(uuid, date) from public, anon;
grant execute on function public.generate_venue_slots(uuid, date) to authenticated, service_role;
