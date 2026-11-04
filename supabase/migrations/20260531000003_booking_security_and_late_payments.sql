-- 20260531000003_booking_security_and_late_payments.sql
-- P4: the database side of late payments, refunds and booking security that
-- the team-manager app and its edge functions call.
--
--   1. venue_bookings(slot_id) index, and venue_slots_remaining(uuid[]) (C5):
--      venue_slot_remaining for up to 500 slots in one call, for the tee
--      sheet.
--   2. release_held_booking_admin (C11): frees an exclusive slot only when
--      the hold is this booking's, and reopens a shared tee time that is no
--      longer full.
--   3. reinstate_venue_booking(text) (C4, C11 note): a payment that lands on
--      a booking cancelled before it was paid puts the booking back when the
--      slot still has room, or returns NULL so payments-webhook refunds it.
--   4. Refund queue (C12): queue_venue_refund never queues a late_payment
--      refund for a booking that stands and records the captured payment
--      (a, b); venue_refunds also holds event slot refunds, queued by
--      queue_event_slot_refund (c).
--   5. Refund outcomes (C10, C12 c, C13): record_venue_refund_result records
--      each PayMongo outcome of either kind (a success lands on the booking
--      and in transactions; a failure is retried with backoff), and
--      record_venue_refund_submitted a refund PayMongo has accepted but not
--      finished.
--   6. book_venue_slot (C3, P4 part): service_role only. It was executable by
--      PUBLIC, so anyone with the anon key could hold any slot in any
--      player's name without paying.
--   7. pg_cron and pg_net: installed here; both release jobs and the refund
--      processor job (C13) (re)scheduled by name.
--   8. complete_venue_booking (C13): the newest booking on an exclusive slot
--      owns its hold, so an expired hold's late payment returns 'cancelled'.

-- =============================================================================
-- 1. venue_bookings(slot_id) index; venue_slots_remaining (C5)
-- =============================================================================
-- Capacity counts (book_venue_slot, check_slot_capacity, venue_slot_remaining,
-- venue_slots_remaining), releases (release_held_booking_admin,
-- release_stale_shared_bookings every minute) and reinstate_venue_booking all
-- find bookings by slot, and nothing indexed slot_id: at 200k bookings
-- release_stale_shared_bookings took 42 s per run, 12 ms with this index.
create index if not exists venue_bookings_slot_id_idx on public.venue_bookings (slot_id);

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

-- =============================================================================
-- 4. Refund queue: late payments and event slots (C12)
-- =============================================================================
-- 4a. Event slot refunds (C12 c). A slot fee captured after the payer's
-- event_slots row was released, deleted or taken over goes back through the
-- same queue and processor. An event_slot row has no booking; it carries the
-- PayMongo intent (payments-process-refunds reads it from the row) and the
-- paying user (who may read it). One per (intent, reason). An event slot is
-- never refunded for a venue closure.
alter table public.venue_refunds add column if not exists kind text not null default 'venue_booking';
alter table public.venue_refunds add column if not exists paymongo_intent_id text;
alter table public.venue_refunds add column if not exists user_id uuid references public.profiles(id) on delete restrict;
alter table public.venue_refunds alter column booking_id drop not null;

alter table public.venue_refunds drop constraint if exists venue_refunds_kind_check;
alter table public.venue_refunds
  add constraint venue_refunds_kind_check check (kind in ('venue_booking', 'event_slot'));

alter table public.venue_refunds drop constraint if exists venue_refunds_kind_refs_check;
alter table public.venue_refunds
  add constraint venue_refunds_kind_refs_check check (
    (kind = 'venue_booking' and booking_id is not null)
    or (kind = 'event_slot'
        and booking_id is null
        and paymongo_intent_id is not null
        and user_id is not null
        and reason in ('late_payment', 'player_cancel'))
  );

create unique index if not exists venue_refunds_event_slot_intent_reason_key
  on public.venue_refunds (paymongo_intent_id, reason)
  where kind = 'event_slot';

drop policy if exists venue_refunds_user_read on public.venue_refunds;
create policy venue_refunds_user_read on public.venue_refunds
  for select to authenticated using (
    kind = 'event_slot' and user_id = (select auth.uid())
  );

-- 4b. queue_venue_refund: late payments (C12 a, b).
-- Redefined from 20260531000001 (C1); idempotent on (booking_id, reason) and
-- capped at the booking total as before. Two deliveries of one late "paid"
-- event can run at once: one reinstates the booking while the other, having
-- seen it cancelled, queues a late_payment refund. Both now take the booking
-- row lock first (reinstate_venue_booking already did), and a late_payment
-- refund for a booking that stands ('paid' or 'completed') returns NULL and
-- queues nothing; payments-webhook reads NULL as "paid, nothing to refund".
-- The reverse order was already safe: reinstate refuses a booking with a
-- refund queued.
-- C12 b: a late payment was captured but never completed, so the intent has
-- no transactions row. Queueing its refund also records the payment as the
-- intent's venue_booking row, exactly as complete_venue_booking writes it,
-- so receipts show the payment and then the refund. Only when the intent has
-- no row at all: one row per intent, because payments-webhook resolves
-- gateway_ref with maybeSingle(). reinstate_venue_booking and
-- complete_venue_booking write nothing for such a booking (it is cancelled
-- and has a refund), and the booking lock keeps concurrent calls from both
-- writing it.
-- Caps (PR #11 review, finding 1): refunds of all reasons for one booking
-- never add up to more than its total (invalid_parameter_value), and a
-- late_payment refund is also NULL when the intent already has its
-- venue_booking payment row and no late_payment refund exists yet: the
-- booking was paid through complete_venue_booking or reinstate_venue_booking
-- (and maybe cancelled since, by a closure or the captain), so the payment
-- is not late and any refund it is owed is queued or decided elsewhere.
-- A repeat of a refund already queued returns it as before.
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
  _b public.venue_bookings;
  _slot public.venue_slots;
  _venue public.venues;
  _id uuid;
begin
  -- Bad input is an error whatever the booking's state (the table's own
  -- checks, raised before the late payment short cut and the cap below).
  if _amount_cents is null or _amount_cents <= 0 then
    raise exception 'Refund amount must be positive' using errcode = 'check_violation';
  end if;
  if _reason is null or _reason not in ('venue_closure', 'late_payment', 'player_cancel') then
    raise exception 'Unknown refund reason %', _reason using errcode = 'check_violation';
  end if;

  select b.* into _b from public.venue_bookings b where b.id = _booking_id for update;
  if not found then
    raise exception 'Booking % not found', _booking_id using errcode = 'no_data_found';
  end if;
  if _amount_cents > _b.total_cents then
    raise exception 'Refund of % exceeds the % paid for booking %', _amount_cents, _b.total_cents, _booking_id
      using errcode = 'invalid_parameter_value';
  end if;

  if _reason = 'late_payment' then
    if _b.status in ('paid', 'completed') then
      return null;
    end if;
    if _b.paymongo_intent_id is not null
       and not exists (
         select 1 from public.venue_refunds r
          where r.booking_id = _b.id and r.reason = 'late_payment'
       )
       and exists (
         select 1 from public.transactions t
          where t.type = 'venue_booking' and t.gateway_ref = _b.paymongo_intent_id
       ) then
      return null;
    end if;
  end if;

  select r.id into _id from public.venue_refunds r
   where r.booking_id = _booking_id and r.reason = _reason;

  if _id is null then
    if _amount_cents + coalesce((
         select sum(r.amount_cents) from public.venue_refunds r where r.booking_id = _booking_id
       ), 0) > _b.total_cents then
      raise exception 'Refunds for booking % would add up to more than the % it paid', _booking_id, _b.total_cents
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
  end if;

  if _reason = 'late_payment'
     and _b.paymongo_intent_id is not null
     and not exists (select 1 from public.transactions t where t.gateway_ref = _b.paymongo_intent_id) then
    select s.* into _slot from public.venue_slots s where s.id = _b.slot_id;
    select v.* into _venue from public.venues v where v.id = _b.venue_id;

    insert into public.transactions (
      team_id, user_id, type, amount_cents, currency,
      platform_fee_cents, gateway, gateway_ref, status, metadata
    ) values (
      _b.team_id, _b.captain_user_id, 'venue_booking',
      _b.total_cents, _venue.currency,
      _b.platform_fee_cents, 'paymongo', _b.paymongo_intent_id, 'succeeded',
      jsonb_build_object(
        'booking_id', _b.id,
        'slot_id', _slot.id,
        'venue_id', _venue.id,
        'court_id', _slot.court_id,
        'party_size', _b.party_size
      )
    );
  end if;

  return _id;
end;
$$;

revoke execute on function public.queue_venue_refund(uuid, int, text) from public, anon, authenticated;
grant execute on function public.queue_venue_refund(uuid, int, text) to service_role;

-- 4c. queue_event_slot_refund (C12 c). payments-webhook calls it for a paid
-- event slot intent whose event_slots row is missing, released or no longer
-- the payer's. It records the captured payment as the app's event slot
-- payment row, then queues the refund; returns the refund id, idempotent on
-- (intent, reason).
-- The payment row is the one payments-create-intent writes for the intent
-- (transactions type 'slot', team_id the event's team, gateway 'paymongo',
-- gateway_ref the intent id, status 'pending' until payments-webhook settles
-- it). If it is still 'pending', or 'failed' from an earlier attempt, it is
-- marked 'succeeded': the money was captured. If the intent has no row at
-- all, one is written for the payer with what is known (amount, no team,
-- no fee). Never a second row for an intent. An intent whose row is not an
-- event slot payment, or was paid by someone else, or refunds of all
-- reasons for the intent adding up to more than its payment, are rejected
-- (invalid_parameter_value). Calls for one intent run one at a time
-- (advisory lock on the intent; without it two calls for an intent with no
-- row would each write one).
-- The payment row is also marked with its refund:
-- metadata.event_slot_refund_id = the refund id. The captain's income
-- screens leave marked slot payments out, and under RLS they cannot read
-- the payer's refund rows to find out otherwise. payments-webhook writes the
-- same key with the same id; an existing marker is kept as it is.
create or replace function public.queue_event_slot_refund(
  _intent_id text,
  _amount_cents int,
  _user_id uuid,
  _reason text
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  _pay public.transactions;
  _has_pay boolean;
  _id uuid;
begin
  if _intent_id is null or btrim(_intent_id) = '' then
    raise exception 'A PayMongo intent id is required' using errcode = 'invalid_parameter_value';
  end if;
  if _user_id is null then
    raise exception 'The paying user is required' using errcode = 'invalid_parameter_value';
  end if;

  perform pg_advisory_xact_lock(hashtextextended('payment_intent:' || _intent_id, 0));

  select t.* into _pay
    from public.transactions t
   where t.gateway_ref = _intent_id
   order by t.created_at, t.id
   limit 1
     for update;
  _has_pay := found;

  if _has_pay then
    if _pay.type <> 'slot' then
      raise exception 'Intent % did not pay for an event slot', _intent_id using errcode = 'invalid_parameter_value';
    end if;
    if _pay.user_id <> _user_id then
      raise exception 'Intent % was paid by another user', _intent_id using errcode = 'invalid_parameter_value';
    end if;
    if _amount_cents > _pay.amount_cents then
      raise exception 'Refund of % exceeds the % paid on intent %', _amount_cents, _pay.amount_cents, _intent_id
        using errcode = 'invalid_parameter_value';
    end if;
  end if;

  select r.id into _id from public.venue_refunds r
   where r.kind = 'event_slot' and r.paymongo_intent_id = _intent_id and r.reason = _reason;

  if _id is null then
    if _amount_cents + coalesce((
         select sum(r.amount_cents) from public.venue_refunds r
          where r.kind = 'event_slot' and r.paymongo_intent_id = _intent_id
       ), 0) > (case when _has_pay then _pay.amount_cents else _amount_cents end) then
      raise exception 'Refunds for intent % would add up to more than it paid', _intent_id
        using errcode = 'invalid_parameter_value';
    end if;

    insert into public.venue_refunds (kind, paymongo_intent_id, user_id, amount_cents, reason)
    values ('event_slot', _intent_id, _user_id, _amount_cents, _reason)
    on conflict (paymongo_intent_id, reason) where kind = 'event_slot' do nothing
    returning id into _id;

    if _id is null then
      select r.id into _id from public.venue_refunds r
       where r.kind = 'event_slot' and r.paymongo_intent_id = _intent_id and r.reason = _reason;
    end if;
  end if;

  if not _has_pay then
    insert into public.transactions (
      team_id, user_id, type, amount_cents, platform_fee_cents,
      gateway, gateway_ref, status, metadata
    ) values (
      null, _user_id, 'slot', _amount_cents, 0,
      'paymongo', _intent_id, 'succeeded',
      jsonb_build_object('recorded_by', 'queue_event_slot_refund', 'event_slot_refund_id', _id)
    );
  else
    update public.transactions t
       set status = case when t.status in ('pending', 'failed') then 'succeeded'::public.txn_status else t.status end,
           metadata = case
             when jsonb_typeof(t.metadata) = 'object' and t.metadata ? 'event_slot_refund_id' then t.metadata
             else (case when jsonb_typeof(t.metadata) = 'object' then t.metadata else '{}'::jsonb end)
                  || jsonb_build_object('event_slot_refund_id', _id)
           end
     where t.id = _pay.id;
  end if;

  return _id;
end;
$$;

revoke execute on function public.queue_event_slot_refund(text, int, uuid, text) from public, anon, authenticated;
grant execute on function public.queue_event_slot_refund(text, int, uuid, text) to service_role;

-- =============================================================================
-- 5. Refund outcomes: record_venue_refund_result (C10, C12 c, C13) and
--    record_venue_refund_submitted (C13)
-- =============================================================================
-- C13 refund lifecycle: 'submitted' is a refund PayMongo accepted but has
-- not finished (the processor polls it), and next_attempt_at is when a
-- failed refund may be tried again (the processor claims failed rows under
-- its attempts cap of 8 only once it has passed).
alter table public.venue_refunds add column if not exists next_attempt_at timestamptz not null default now();
-- C13: payments-process-refunds stores the Idempotency-Key it sends
-- (<refund id>:<attempts>) in the same update that claims a row, and a stale
-- 'processing' reclaim resends the stored key instead of computing a new
-- one. NULL for a row never claimed (or claimed before the column existed).
alter table public.venue_refunds add column if not exists request_key text;
alter table public.venue_refunds drop constraint if exists venue_refunds_status_check;
alter table public.venue_refunds
  add constraint venue_refunds_status_check
  check (status in ('pending', 'processing', 'submitted', 'succeeded', 'failed'));

-- venue_bookings.refund_amount_cents and refunded_at exist since 0005, and
-- txn_type 'venue_refund' since 0004; the column statements are no ops kept
-- for databases that skipped 0005's columns.
alter table public.venue_bookings add column if not exists refund_amount_cents int not null default 0;
alter table public.venue_bookings add column if not exists refunded_at timestamptz;

-- Success: the refund row becomes 'succeeded' with the PayMongo refund id;
-- the booking's refund_amount_cents is SET to the sum of its succeeded
-- refunds (apply_venue_closure already wrote the full amount when it queued
-- one, so adding would double it) and refunded_at to now; one 'venue_refund'
-- transactions row is written for the player's receipts
-- (useMyTransactions reads the user's rows by user_id):
--   user_id = the booking's captain, amount_cents = the refund (positive,
--   as every transactions amount is), currency = the venue's, gateway
--   'paymongo', status 'succeeded', gateway_ref = the PayMongo refund id,
--   metadata = refund, booking, intent, slot, venue and court ids, reason.
-- gateway_ref is deliberately not the intent id: payments-webhook resolves
-- transactions by gateway_ref = intent id with maybeSingle(), so a second
-- row on the intent would make every redelivery of a paid event fail.
-- team_id is left null: the captain's team revenue screens (team-manager
-- useTeamTransactions) sum every succeeded team row as income, so a team
-- tagged refund would be counted as money in. Venue payouts (palaro-web
-- payouts page) read venue_bookings, where refunded bookings are already
-- cancelled or refunded and so out of the next payout.
-- An event slot refund (C12 c) touches no booking: its row is written for
-- the paying user with team_id null and type 'venue_refund' too (receipts
-- label it "Refund"; no new txn_type for team-manager to learn), currency
-- from the intent's payment row, and metadata with the refund, kind, reason,
-- intent and the payment's event and slot.
-- A repeat success is a no op, and a failure never downgrades a success.
-- Failure: 'failed' with last_error, and next_attempt_at = now() +
-- 5 minutes * 2^(attempts - 1) (5, 10, 20 ... 640 minutes; the seven
-- retries under the cap of 8 fit inside PayMongo's 24 hour idempotency key
-- lifetime). attempts belong to the claim; a row never claimed counts as 1.
-- Lock order: booking row, then refund row (as apply_venue_closure, which
-- locks bookings before queueing refunds).
create or replace function public.record_venue_refund_result(
  _refund_id uuid,
  _succeeded boolean,
  _paymongo_refund_id text,
  _error text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  _b public.venue_bookings;
  _r public.venue_refunds;
  _slot public.venue_slots;
  _pay public.transactions;
  _currency text;
begin
  if _succeeded is null then
    raise exception 'Refund outcome must be true or false' using errcode = 'invalid_parameter_value';
  end if;
  if _succeeded and nullif(btrim(_paymongo_refund_id), '') is null then
    raise exception 'A successful refund needs its PayMongo refund id' using errcode = 'invalid_parameter_value';
  end if;

  select r.* into _r from public.venue_refunds r where r.id = _refund_id;
  if not found then
    raise exception 'Refund % not found', _refund_id using errcode = 'no_data_found';
  end if;

  if _r.kind = 'venue_booking' then
    select b.* into _b from public.venue_bookings b where b.id = _r.booking_id for update;
  end if;
  select r.* into _r from public.venue_refunds r where r.id = _refund_id for update;

  if _r.status = 'succeeded' then
    return;
  end if;

  if not _succeeded then
    update public.venue_refunds
       set status = 'failed',
           last_error = coalesce(nullif(btrim(_error), ''), 'Refund failed'),
           next_attempt_at = now() + interval '5 minutes' * power(2, greatest(_r.attempts, 1) - 1)
     where id = _r.id;
    return;
  end if;

  update public.venue_refunds
     set status = 'succeeded',
         paymongo_refund_id = btrim(_paymongo_refund_id),
         last_error = null
   where id = _r.id;

  if _r.kind = 'event_slot' then
    select t.* into _pay
      from public.transactions t
     where t.gateway_ref = _r.paymongo_intent_id and t.type = 'slot'
     order by t.created_at, t.id
     limit 1;

    insert into public.transactions (
      team_id, user_id, type, amount_cents, currency,
      platform_fee_cents, gateway, gateway_ref, status, metadata
    ) values (
      null, _r.user_id, 'venue_refund', _r.amount_cents, coalesce(_pay.currency, 'PHP'),
      0, 'paymongo', btrim(_paymongo_refund_id), 'succeeded',
      jsonb_strip_nulls(jsonb_build_object(
        'refund_id', _r.id,
        'kind', 'event_slot',
        'reason', _r.reason,
        'intent_id', _r.paymongo_intent_id,
        'event_id', _pay.metadata -> 'event_id',
        'slot_id', _pay.metadata -> 'slot_id'
      ))
    );
    return;
  end if;

  update public.venue_bookings b
     set refund_amount_cents = (
           select coalesce(sum(r.amount_cents), 0)::int
             from public.venue_refunds r
            where r.booking_id = b.id and r.status = 'succeeded'
         ),
         refunded_at = now(),
         updated_at = now()
   where b.id = _b.id;

  select s.* into _slot from public.venue_slots s where s.id = _b.slot_id;
  select v.currency into _currency from public.venues v where v.id = _b.venue_id;

  insert into public.transactions (
    team_id, user_id, type, amount_cents, currency,
    platform_fee_cents, gateway, gateway_ref, status, metadata
  ) values (
    null, _b.captain_user_id, 'venue_refund', _r.amount_cents, coalesce(_currency, 'PHP'),
    0, 'paymongo', btrim(_paymongo_refund_id), 'succeeded',
    jsonb_build_object(
      'refund_id', _r.id,
      'booking_id', _b.id,
      'reason', _r.reason,
      'intent_id', _b.paymongo_intent_id,
      'slot_id', _b.slot_id,
      'venue_id', _b.venue_id,
      'court_id', _slot.court_id
    )
  );
end;
$$;

revoke execute on function public.record_venue_refund_result(uuid, boolean, text, text) from public, anon, authenticated;
grant execute on function public.record_venue_refund_result(uuid, boolean, text, text) to service_role;

-- PayMongo accepted the refund but reports it pending: 'submitted' with its
-- PayMongo id, until a poll records it succeeded or failed through
-- record_venue_refund_result. Idempotent; never downgrades a success. Only
-- the refund row is locked.
create or replace function public.record_venue_refund_submitted(
  _refund_id uuid,
  _paymongo_refund_id text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  _r public.venue_refunds;
begin
  if nullif(btrim(_paymongo_refund_id), '') is null then
    raise exception 'A submitted refund needs its PayMongo refund id' using errcode = 'invalid_parameter_value';
  end if;

  select r.* into _r from public.venue_refunds r where r.id = _refund_id for update;
  if not found then
    raise exception 'Refund % not found', _refund_id using errcode = 'no_data_found';
  end if;

  if _r.status = 'succeeded'
     or (_r.status = 'submitted' and _r.paymongo_refund_id = btrim(_paymongo_refund_id)) then
    return;
  end if;

  update public.venue_refunds
     set status = 'submitted',
         paymongo_refund_id = btrim(_paymongo_refund_id),
         last_error = null
   where id = _r.id;
end;
$$;

revoke execute on function public.record_venue_refund_submitted(uuid, text) from public, anon, authenticated;
grant execute on function public.record_venue_refund_submitted(uuid, text) to service_role;

-- =============================================================================
-- 6. book_venue_slot: service_role only (C3, P4 part)
-- =============================================================================
-- 20260529000002 created it with plain CREATE FUNCTION, so PUBLIC (and the
-- anon and authenticated defaults) could execute it. Its only caller is
-- payments-create-intent with the service role. Body unchanged
-- (20260531000002).
revoke execute on function public.book_venue_slot(uuid, uuid, uuid, int, int, numeric) from public, anon, authenticated;
grant execute on function public.book_venue_slot(uuid, uuid, uuid, int, int, numeric) to service_role;

-- =============================================================================
-- 7. Release jobs (team-manager PR #7 review, finding 8)
-- =============================================================================
-- 0005 (release-stale-venue-holds) and 20260529000004
-- (release-stale-shared-bookings) only scheduled their jobs when pg_cron was
-- already installed and silently skipped otherwise, leaving held slots and
-- abandoned tee time bookings unreleased forever. Install pg_cron and
-- schedule both, dropping any job of the same name first so a rerun (or a
-- database where the earlier migrations did schedule them) ends with exactly
-- one of each. Commands as in those migrations.
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

select cron.unschedule(j.jobid)
  from cron.job j
 where j.jobname in ('release-stale-venue-holds', 'release-stale-shared-bookings', 'process-venue-refunds');

select cron.schedule(
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

select cron.schedule(
  'release-stale-shared-bookings',
  '* * * * *',
  $cron$ select public.release_stale_shared_bookings(15); $cron$
);

-- C13: nothing else runs payments-process-refunds on a schedule, and PayMongo
-- does not redeliver an event answered with 200, so a refund whose first run
-- failed was never retried. Every 5 minutes this posts {} to the function
-- with the service role key. Both values come from Vault (runbook: create
-- the secrets 'project_url', e.g. https://<ref>.supabase.co, and
-- 'service_role_key' after a restore). Until both exist the job sends
-- nothing and does not fail; scheduling it never reads them. The request
-- timeout covers a full processor batch.
select cron.schedule(
  'process-venue-refunds',
  '*/5 * * * *',
  $cron$
    select net.http_post(
             url := rtrim(s.project_url, '/') || '/functions/v1/payments-process-refunds',
             body := '{}'::jsonb,
             headers := jsonb_build_object(
               'Content-Type', 'application/json',
               'Authorization', 'Bearer ' || s.service_role_key
             ),
             timeout_milliseconds := 60000
           )
      from (
        select (select d.decrypted_secret from vault.decrypted_secrets d where d.name = 'project_url') as project_url,
               (select d.decrypted_secret from vault.decrypted_secrets d where d.name = 'service_role_key') as service_role_key
      ) s
     where s.project_url is not null
       and s.service_role_key is not null
  $cron$
);

-- =============================================================================
-- 8. complete_venue_booking: the newest booking owns the hold (C13)
-- =============================================================================
-- Redefined from 20260531000001 with one change: on an exclusive slot, a
-- booking made after this one (any status) means this booking's hold expired
-- and was retaken, so its payment returns 'cancelled' exactly like the "slot
-- taken" race. payments-webhook then reinstates it if the slot is free again
-- (reinstate_venue_booking's checks) or refunds it, instead of this payment
-- taking the slot from the player who holds it now. Same rule as
-- release_held_booking_admin (C11). Shared tee times are unchanged.
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

    -- C13: the newest booking on an exclusive slot owns its hold (the C11
    -- rule). A booking made after this one means this one's hold expired
    -- and was retaken; its late payment must not take the slot.
    if exists (
      select 1 from public.venue_bookings b
       where b.slot_id = _booking.slot_id
         and b.id <> _booking.id
         and b.created_at >= _booking.created_at
    ) then
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
