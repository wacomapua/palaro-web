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

drop trigger if exists event_slots_promote_reserve on public.event_slots;
drop function if exists public.promote_reserve_on_release();

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

create or replace function public.event_slots_promote_on_reserve_insert()
returns trigger
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
   where e.id = NEW.event_id
     for no key update;

  if _slot_count is null then
    return null;
  end if;

  loop
    select p into _seat
      from generate_series(1, _slot_count) p
     where p <> all(_taken)
       and not exists (
         select 1 from public.event_slots s
          where s.event_id = NEW.event_id
            and s.slot_type = 'confirmed'
            and s.position = p
       )
     order by p
     limit 1;

    exit when _seat is null;

    _reserve := public.event_slots_next_reserve(NEW.event_id);
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

  return null;
end;
$$;

revoke execute on function public.event_slots_next_reserve(uuid) from public, anon, authenticated;
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
