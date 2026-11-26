-- Recurring weekly schedule (P2) + blackout/closure dates (P3).
--
-- venue_slot_templates already existed (day_of_week, start_time, end_time,
-- price_cents, active, paused_until); we add slot_minutes so a band like
-- "9am-8pm" expands into hourly (or any-length) slots. A SQL generator
-- materialises venue_slots from the templates, in the venue's timezone, skipping
-- existing slots and anything inside a closure.

-- ---------- slot length on templates ----------
alter table public.venue_slot_templates add column if not exists slot_minutes int not null default 60;
alter table public.venue_slot_templates drop constraint if exists slot_templates_minutes_check;
alter table public.venue_slot_templates
  add constraint slot_templates_minutes_check check (slot_minutes between 5 and 1440);

-- ---------- blackout / closure windows ----------
create table if not exists public.venue_closures (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete cascade,
  court_id uuid references public.venue_courts(id) on delete cascade, -- null = whole venue
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  reason text,
  created_at timestamptz not null default now(),
  constraint closure_time_valid check (ends_at > starts_at)
);
create index if not exists venue_closures_venue_idx on public.venue_closures(venue_id, starts_at);

alter table public.venue_closures enable row level security;

drop policy if exists "venue_closures public read" on public.venue_closures;
create policy "venue_closures public read" on public.venue_closures
  for select using (true);

drop policy if exists "venue_closures owner write" on public.venue_closures;
create policy "venue_closures owner write" on public.venue_closures
  for all using (
    exists (select 1 from public.venues v where v.id = venue_closures.venue_id and v.owner_id = auth.uid())
  ) with check (
    exists (select 1 from public.venues v where v.id = venue_closures.venue_id and v.owner_id = auth.uid())
  );

-- ---------- generator: materialise venue_slots from templates ----------
-- Expands every active template across matching weekdays from today through
-- _through, at the venue's local wall-clock times (via AT TIME ZONE), honouring
-- each court's booking model (golf course → shared/per-player tee times; other
-- courts → exclusive/per-slot blocks). Skips slots that already exist and any
-- that fall inside a closure. Returns the number of slots created.
create or replace function public.generate_venue_slots(_venue_id uuid, _through date)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  _tz text;
  _currency text;
  _created int := 0;
begin
  if not exists (select 1 from public.venues where id = _venue_id and owner_id = auth.uid()) then
    raise exception 'Not authorized' using errcode = 'insufficient_privilege';
  end if;
  if _through > current_date + 366 then
    raise exception 'Cannot generate more than a year ahead';
  end if;

  select timezone, currency into _tz, _currency from public.venues where id = _venue_id;
  _tz := coalesce(_tz, 'Asia/Manila');

  with days as (
    select d::date as gen_date
    from generate_series(current_date, _through, interval '1 day') as g(d)
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
    join public.venue_courts c on c.id = t.court_id
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
  )
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
  from gen g
  where not exists (
    select 1 from public.venue_slots vs
     where vs.court_id = g.court_id and vs.starts_at = g.starts_at
  )
  and not exists (
    select 1 from public.venue_closures cl
     where cl.venue_id = _venue_id
       and (cl.court_id is null or cl.court_id = g.court_id)
       and cl.starts_at < g.ends_at and cl.ends_at > g.starts_at
  );

  get diagnostics _created = row_count;
  return _created;
end;
$$;

revoke execute on function public.generate_venue_slots(uuid, date) from public, anon;
grant execute on function public.generate_venue_slots(uuid, date) to authenticated, service_role;
