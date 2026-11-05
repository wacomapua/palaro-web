-- 20260601000001_golf_holes.sql
-- Contract C14 (owner decision 2026-11-06): golf has no driving range bays
-- and no Front 9 / Back 9 split. A course has one tee sheet; each tee time
-- has up to 4 spots and a booking is a single, twosome, threesome or
-- foursome (party_size 1 to 4). The golfer chooses 9 or 18 holes when
-- booking; the owner sets a per golfer price for each.
--
--   1. venue_slots.price_per_player_9_cents (NULL: 9 hole rounds are not
--      offered on that tee time), venue_bookings.holes (9 or 18, default
--      18; every existing booking reads 18), venue_slot_templates.price_9_cents.
--   2. replace_venue_slot_templates accepts an optional price_9_cents per
--      entry (shared groups only, whole cents >= 0) and stores it.
--   3. generate_venue_slots copies price_9_cents into
--      price_per_player_9_cents on shared per player slots.
--   4. book_venue_slot gains a trailing `_holes int default 18`. The 6
--      argument function is dropped (if it exists) and the 7 argument one
--      created or replaced, so PostgREST resolves named argument calls to
--      exactly one function and the migration reapplies cleanly.
--      Shared per player slots charge party_size times the 9 or 18 hole
--      price; 9 holes on a tee time with no 9 hole price, or any value
--      other than 9 or 18, raises 22023. The booking stores holes.
--      Exclusive slots ignore _holes and store 18. Execute for service_role
--      only, as in 20260531000003.
--   reinstate_venue_booking is unchanged: it never recomputes a booking's
--   money and never touches holes, so a reinstated booking keeps the holes
--   and totals it was sold at (supabase/tests/golf_holes.test.sql).
--
-- Every function is redefined from its latest version (book_venue_slot from
-- 20260531000002, the other two from 20260531000001) with only the changes
-- above.

-- =============================================================================
-- 1. Columns
-- =============================================================================
alter table public.venue_slots
  add column if not exists price_per_player_9_cents int
    check (price_per_player_9_cents >= 0);

comment on column public.venue_slots.price_per_player_9_cents is
  'Per golfer price of a 9 hole round on a shared (golf) tee time. NULL: 9 hole rounds are not offered on this tee time. price_per_player_cents is the 18 hole price.';

alter table public.venue_bookings
  add column if not exists holes smallint not null default 18
    check (holes in (9, 18));

comment on column public.venue_bookings.holes is
  'Holes the golfer booked (9 or 18). Written by book_venue_slot; exclusive slots and bookings made before 9 hole rounds store 18.';

alter table public.venue_slot_templates
  add column if not exists price_9_cents int
    check (price_9_cents >= 0);

comment on column public.venue_slot_templates.price_9_cents is
  'Per golfer 9 hole price for a shared (golf) group''s weekly hours; generate_venue_slots copies it into venue_slots.price_per_player_9_cents. NULL: no 9 hole rounds.';

-- =============================================================================
-- 2. replace_venue_slot_templates
-- =============================================================================
-- Body as 20260531000001, plus price_9_cents. _templates entries are
--   {day_of_week 0-6 (0 = Sunday), start_time "HH:MM", end_time "HH:MM"
--    (24:00 allowed), slot_minutes 5-1440, price_cents >= 0,
--    price_9_cents >= 0 or null or absent (shared groups only)}
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
  _price9 int;
  _dows int[] := '{}';
  _starts time[] := '{}';
  _ends time[] := '{}';
  _minss int[] := '{}';
  _prices int[] := '{}';
  _prices9 int[] := '{}';
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
      _price9 := (_e->>'price_9_cents')::int;
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
    if _price9 is not null and _booking_mode <> 'shared' then
      raise exception '%: a 9 hole price applies to tee times only', _day_names[_dow + 1] using errcode = 'invalid_parameter_value';
    end if;
    if _price9 < 0 then
      raise exception '%: 9 hole price cannot be negative', _day_names[_dow + 1] using errcode = 'invalid_parameter_value';
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
    _prices9 := _prices9 || _price9;
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
    venue_id, court_id, day_of_week, start_time, end_time, slot_minutes, price_cents, price_9_cents, active
  )
  select _venue_id, c.id, b.dow, b.s, b.e, b.m, b.p, b.p9, true
    from unnest(_active_ids) as c(id)
   cross join unnest(_dows, _starts, _ends, _minss, _prices, _prices9) as b(dow, s, e, m, p, p9);
  get diagnostics _rows = row_count;

  return _rows;
end;
$$;

revoke execute on function public.replace_venue_slot_templates(uuid, public.venue_sport, text, jsonb) from public, anon;
grant execute on function public.replace_venue_slot_templates(uuid, public.venue_sport, text, jsonb) to authenticated, service_role;

-- =============================================================================
-- 3. generate_venue_slots
-- =============================================================================
-- Body as 20260531000001; templates' price_9_cents lands on shared per player
-- slots as price_per_player_9_cents.
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
      t.price_9_cents,
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
      s.court_id, s.price_cents, s.price_9_cents, s.refund_policy, s.booking_mode, s.pricing_mode, s.max_players,
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
      price_per_player_9_cents,
      currency, status, booking_mode, pricing_mode, max_players, refund_policy,
      generated_from_template_id
    )
    select
      _venue_id, g.court_id, g.starts_at, g.ends_at,
      g.price_cents,
      case when g.pricing_mode = 'per_player' then g.price_cents else null end,
      case when g.booking_mode = 'shared' and g.pricing_mode = 'per_player' then g.price_9_cents else null end,
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

-- =============================================================================
-- 4. book_venue_slot(..., _holes int default 18)
-- =============================================================================
-- Body as 20260531000002 plus the holes check, the 9 or 18 hole per player
-- price on shared slots and holes on both inserts. Callers that do not send
-- _holes (payments-create-intent today) keep booking 18 holes.
drop function if exists public.book_venue_slot(uuid, uuid, uuid, int, int, numeric);

create or replace function public.book_venue_slot(
  _slot_id uuid,
  _captain_user_id uuid,
  _team_id uuid,
  _party_size int default 1,
  _hold_minutes int default 10,
  _platform_fee_pct numeric default 5,
  _holes int default 18
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
  _player_price int;
begin
  if _party_size < 1 then
    raise exception 'party_size must be >= 1' using errcode = 'check_violation';
  end if;

  -- C14: a round is 9 or 18 holes; anything else (NULL included) is refused
  -- for every slot, before anything is read or locked.
  if _holes is null or _holes not in (9, 18) then
    raise exception 'Holes must be 9 or 18 (got %)', coalesce(_holes::text, 'null')
      using errcode = 'invalid_parameter_value';
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

    -- C14: the golfer's per player price for the holes chosen. A tee time
    -- with no 9 hole price does not offer 9 hole rounds.
    if _holes = 9 then
      if _slot.price_per_player_9_cents is null then
        raise exception '9 hole rounds are not offered for this tee time'
          using errcode = 'invalid_parameter_value';
      end if;
      _player_price := _slot.price_per_player_9_cents;
    else
      _player_price := coalesce(_slot.price_per_player_cents, _slot.price_cents);
    end if;

    _total := _player_price * _party_size;
    _fee   := round(_total * _platform_fee_pct / 100);

    insert into public.venue_bookings (
      slot_id, venue_id, team_id, captain_user_id,
      party_size, total_cents, platform_fee_cents, payout_cents, status,
      refund_policy_snapshot, holes
    ) values (
      _slot_id, _slot.venue_id, _team_id, _captain_user_id,
      _party_size, _total, _fee, _total - _fee, 'pending_payment',
      coalesce(_slot.refund_policy, _slot.v_refund_policy), _holes
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

  -- Exclusive slots ignore _holes and store 18 (C14).
  _total := _slot.price_cents;
  _fee   := round(_total * _platform_fee_pct / 100);

  insert into public.venue_bookings (
    slot_id, venue_id, team_id, captain_user_id,
    party_size, total_cents, platform_fee_cents, payout_cents, status,
    refund_policy_snapshot, holes
  ) values (
    _slot_id, _slot.venue_id, _team_id, _captain_user_id,
    _party_size, _total, _fee, _total - _fee, 'pending_payment',
    coalesce(_slot.refund_policy, _slot.v_refund_policy), 18
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

-- Server only (C3 P4 part, 20260531000003): payments-create-intent calls it
-- with the service role.
revoke execute on function public.book_venue_slot(uuid, uuid, uuid, int, int, numeric, int) from public, anon, authenticated;
grant execute on function public.book_venue_slot(uuid, uuid, uuid, int, int, numeric, int) to service_role;
