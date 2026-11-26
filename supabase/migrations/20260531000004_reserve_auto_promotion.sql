-- 20260531000004_reserve_auto_promotion.sql
-- Reserve auto promotion (contract C7, owner decision 4). Replaces
-- team-manager's 0009_reserve_auto_promotion.sql, which team-manager drops.
--
-- When a confirmed player's event_slots row is released:
--   * the released row is deleted, so the seat is free even when nobody waits
--     (a player who drops out can rejoin; unique (event_id, user_id));
--   * the reserve who joined first (earliest created_at, not tile position)
--     moves into the released seat, OLD.position;
--   * nobody moves when OLD.position is beyond events.slot_count.
-- When a reserve joins while a seat 1..slot_count is free, the reserves who
-- joined first fill the free seats, lowest seat first.
--
-- Fixes over the team-manager original:
--   * It trusted NEW. Under slots_update a member may rewrite every column of
--     their own row in the same statement that releases it (event_id,
--     position, slot_type). Only OLD is used here: the trigger fires on
--     OLD.slot_type = 'confirmed', promotes inside OLD.event_id into
--     OLD.position, and so can never move another player's row into a seat
--     or event the updater chose.
--   * It used FOR UPDATE SKIP LOCKED on the reserve, which skips the first
--     reserve whenever anything else has its row locked (its owner editing
--     it), and nothing serialised two releases. Every seat change of an
--     event now takes the event row lock first, and the reserve row is
--     waited for, never skipped.
--   * It ordered by reserve position; owner decision 4 orders by created_at.
--   * With nobody waiting it left the released row holding the seat.
--
-- The event lock is FOR NO KEY UPDATE rather than FOR UPDATE. Claiming a
-- seat inserts an event_slots row, whose foreign key check holds FOR KEY
-- SHARE on the event until commit. FOR UPDATE conflicts with that lock, so
-- two players joining at once would each wait for the other's key share lock
-- (a deadlock); FOR NO KEY UPDATE does not conflict with it and still
-- serialises every promotion of the event.
--
-- SECURITY DEFINER: the promoted reserve belongs to another user, whom the
-- releasing member cannot update under RLS. search_path is pinned and every
-- name is schema qualified.
--
-- Client guard (PR #11 review). slots_claim and slots_update (0002) put no
-- limit on columns, so through PostgREST a member (or a captain, on any row
-- of their team's events) could:
--   * insert or update a row as 'paid', or with paid_at, and hold a seat
--     without paying (only payments-webhook, as the service role, marks a
--     slot paid);
--   * write created_at, the queue order: created_at = 2000-01-01 was
--     promoted first;
--   * move an old row into another event, or hand it to another player,
--     keeping its created_at;
--   * flip a released reserve back to 'reserved' and keep the created_at
--     of when it first joined.
-- One BEFORE INSERT OR UPDATE trigger, for every role but postgres,
-- service_role and supabase_admin (migrations, edge functions, and the
-- definer functions below, which run as their owner postgres): refuses a
-- paid insert, a change to 'paid', a non null paid_at that was not there
-- before, a change of event_id or user_id, and any write of created_at;
-- stamps created_at with now() on insert and when a released row comes
-- back. Every write the team-manager app makes as authenticated passes:
-- the insert of a 'reserved' row, the reclaim (slot_type, position,
-- status 'reserved', paid_at null), the rollback and useReleaseSlot
-- (status 'released', paid_at null, by the player or the captain), and the
-- delete of a released row.

drop trigger if exists event_slots_promote_reserve on public.event_slots;
drop function if exists public.promote_reserve_on_release();

-- SECURITY INVOKER on purpose: current_user is the caller's role.
create or replace function public.event_slots_client_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user in ('postgres', 'service_role', 'supabase_admin') then
    return new;
  end if;

  if tg_op = 'INSERT' then
    if new.status = 'paid' or new.paid_at is not null then
      raise exception 'event_slots: only a payment marks a slot paid' using errcode = 'insufficient_privilege';
    end if;
    new.created_at := now();
    return new;
  end if;

  if new.created_at is distinct from old.created_at then
    raise exception 'event_slots.created_at is set by the server' using errcode = 'insufficient_privilege';
  end if;
  if new.event_id is distinct from old.event_id or new.user_id is distinct from old.user_id then
    raise exception 'event_slots: a slot cannot change event or player' using errcode = 'insufficient_privilege';
  end if;
  if (new.status = 'paid' and old.status is distinct from 'paid')
     or (new.paid_at is not null and new.paid_at is distinct from old.paid_at) then
    raise exception 'event_slots: only a payment marks a slot paid' using errcode = 'insufficient_privilege';
  end if;

  -- Back from released: it joins the reserve queue now, not when it first did.
  if old.status = 'released' and new.status <> 'released' then
    new.created_at := now();
  end if;
  return new;
end;
$$;

revoke execute on function public.event_slots_client_guard() from public, anon, authenticated;

drop trigger if exists event_slots_server_created_at on public.event_slots;
drop function if exists public.event_slots_server_created_at();
drop trigger if exists event_slots_client_guard on public.event_slots;
create trigger event_slots_client_guard
  before insert or update on public.event_slots
  for each row
  execute function public.event_slots_client_guard();

-- The earliest waiting reserve of an event, row locked; NULL when nobody
-- waits. A reserve row locked elsewhere is waited for. If it changed while
-- we waited (released, promoted) it no longer qualifies and the next one is
-- tried.
create or replace function public.event_slots_next_reserve(_event_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  _id uuid;
begin
  loop
    select s.id into _id
      from public.event_slots s
     where s.event_id = _event_id
       and s.slot_type = 'reserve'
       and s.status in ('reserved', 'paid')
     order by s.created_at, s.id
     limit 1;

    if _id is null then
      return null;
    end if;

    perform 1
       from public.event_slots s
      where s.id = _id
        and s.event_id = _event_id
        and s.slot_type = 'reserve'
        and s.status in ('reserved', 'paid')
        for update;

    if found then
      return _id;
    end if;
  end loop;
end;
$$;

create or replace function public.event_slots_promote_on_release()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  _slot_count int;
  _reserve uuid;
begin
  select e.slot_count into _slot_count
    from public.events e
   where e.id = OLD.event_id
     for no key update;

  delete from public.event_slots s where s.id = OLD.id;

  if _slot_count is null or OLD.position < 1 or OLD.position > _slot_count then
    return null;
  end if;

  -- Another row of the same statement may already sit in that seat.
  if exists (
    select 1 from public.event_slots s
     where s.event_id = OLD.event_id
       and s.slot_type = 'confirmed'
       and s.position = OLD.position
  ) then
    return null;
  end if;

  _reserve := public.event_slots_next_reserve(OLD.event_id);
  if _reserve is null then
    return null;
  end if;

  begin
    update public.event_slots
       set slot_type = 'confirmed', position = OLD.position
     where id = _reserve;
  exception when unique_violation then
    -- A direct claim took the seat first. The release itself stands; the
    -- reserve keeps waiting.
    null;
  end;

  return null;
end;
$$;

-- Fills every free seat 1..slot_count of an event with the reserves who
-- joined first, lowest seat first, under the event lock. Used when a reserve
-- joins and by the backfill below.
create or replace function public.event_slots_fill_free_seats(_event_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  _slot_count int;
  _seat int;
  _reserve uuid;
  _taken int[] := '{}';
begin
  select e.slot_count into _slot_count
    from public.events e
   where e.id = _event_id
     for no key update;

  if _slot_count is null then
    return;
  end if;

  loop
    select p into _seat
      from generate_series(1, _slot_count) p
     where p <> all(_taken)
       and not exists (
         select 1 from public.event_slots s
          where s.event_id = _event_id
            and s.slot_type = 'confirmed'
            and s.position = p
       )
     order by p
     limit 1;

    exit when _seat is null;

    _reserve := public.event_slots_next_reserve(_event_id);
    exit when _reserve is null;

    begin
      update public.event_slots
         set slot_type = 'confirmed', position = _seat
       where id = _reserve;
    exception when unique_violation then
      -- A direct claim of this seat committed while we waited for it; try
      -- the next free seat.
      _taken := _taken || _seat;
    end;
  end loop;
end;
$$;

create or replace function public.event_slots_promote_on_reserve_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.event_slots_fill_free_seats(NEW.event_id);
  return null;
end;
$$;

revoke execute on function public.event_slots_next_reserve(uuid) from public, anon, authenticated;
revoke execute on function public.event_slots_fill_free_seats(uuid) from public, anon, authenticated;
revoke execute on function public.event_slots_promote_on_release() from public, anon, authenticated;
revoke execute on function public.event_slots_promote_on_reserve_insert() from public, anon, authenticated;

-- Fires on a real transition to 'released' of a row that WAS confirmed. The
-- promotion updates slot_type and position only (never status) and deletes,
-- so it does not fire this trigger again.
drop trigger if exists event_slots_promote_on_release on public.event_slots;
create trigger event_slots_promote_on_release
  after update of status on public.event_slots
  for each row
  when (OLD.slot_type = 'confirmed' and NEW.status = 'released' and OLD.status is distinct from 'released')
  execute function public.event_slots_promote_on_release();

drop trigger if exists event_slots_promote_on_reserve_insert on public.event_slots;
create trigger event_slots_promote_on_reserve_insert
  after insert on public.event_slots
  for each row
  when (NEW.slot_type = 'reserve')
  execute function public.event_slots_promote_on_reserve_insert();

-- Seats released before this trigger existed (PR #11 review, finding 5):
-- the old flow left a confirmed 'released' row holding its seat, so the seat
-- stayed blocked and nobody was promoted. For events still to come, delete
-- those rows as a release now does and fill the freed seats in join order.
-- Events already played or cancelled keep their history.
do $$
declare
  _events uuid[];
  _e uuid;
begin
  with gone as (
    delete from public.event_slots s
     using public.events e
     where e.id = s.event_id
       and s.slot_type = 'confirmed'
       and s.status = 'released'
       and e.starts_at > now()
       and e.status not in ('cancelled', 'completed')
    returning s.event_id
  )
  select coalesce(array_agg(distinct event_id), '{}') into _events from gone;

  foreach _e in array _events loop
    perform public.event_slots_fill_free_seats(_e);
  end loop;
end $$;
