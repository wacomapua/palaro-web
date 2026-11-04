-- Fixture helpers for supabase/tests/*.test.sql. Applied by scripts/test-db.mjs
-- after the migrations, in the throwaway test database only (never a
-- migration). Tests call these as postgres inside begin ... rollback.
create schema if not exists tests;
grant usage on schema tests to anon, authenticated, service_role;

create or replace function tests.create_user(_email text default null)
returns uuid language plpgsql as $$
declare _id uuid := gen_random_uuid();
begin
  insert into auth.users (id, email, aud, role)
  values (_id, coalesce(_email, _id::text || '@test.local'), 'authenticated', 'authenticated');
  return _id;
end $$;

create or replace function tests.create_venue(_owner uuid, _tz text default 'Asia/Manila')
returns uuid language sql as $$
  insert into public.venues (slug, name, sport, address, owner_id, status, timezone)
  values ('v-' || substr(md5(random()::text), 1, 12), 'Test Venue', 'football', '1 Test St', _owner, 'active', _tz)
  returning id
$$;

create or replace function tests.create_court(
  _venue uuid,
  _name text,
  _parent uuid default null,
  _sport public.venue_sport default 'football',
  _booking_mode text default null,
  _active boolean default true
) returns uuid language sql as $$
  insert into public.venue_courts (venue_id, parent_court_id, name, sport, active, metadata)
  values (
    _venue, _parent, _name, _sport, _active,
    case
      when _booking_mode = 'shared' then
        '{"slotModel":{"bookingMode":"shared","pricingMode":"per_player","maxPlayers":4,"teeIntervalMinutes":10,"defaultDurationMinutes":10}}'::jsonb
      when _booking_mode = 'exclusive' then
        '{"slotModel":{"bookingMode":"exclusive","pricingMode":"per_slot","defaultDurationMinutes":60}}'::jsonb
      else null
    end
  )
  returning id
$$;

-- An exclusive slot by default; pass _max_players for a shared tee time.
create or replace function tests.create_slot(
  _venue uuid,
  _court uuid,
  _starts timestamptz,
  _ends timestamptz,
  _price int default 100000,
  _max_players int default null,
  _status public.venue_slot_status default 'available'
) returns uuid language sql as $$
  insert into public.venue_slots (
    venue_id, court_id, starts_at, ends_at, price_cents, price_per_player_cents,
    status, booking_mode, pricing_mode, max_players
  ) values (
    _venue, _court, _starts, _ends, _price,
    case when _max_players is null then null else _price end,
    _status,
    case when _max_players is null then 'exclusive' else 'shared' end,
    case when _max_players is null then 'per_slot' else 'per_player' end,
    _max_players
  )
  returning id
$$;

-- A booking in any status, written directly (as the RPCs would leave it).
create or replace function tests.create_booking(
  _slot uuid,
  _captain uuid,
  _status public.venue_booking_status default 'paid',
  _party int default 1,
  _total int default 100000,
  _intent text default null
) returns uuid language sql as $$
  insert into public.venue_bookings (
    slot_id, venue_id, captain_user_id, party_size, total_cents,
    platform_fee_cents, payout_cents, status, paymongo_intent_id
  )
  select _slot, s.venue_id, _captain, _party, _total, _total / 20, _total - _total / 20, _status, _intent
    from public.venue_slots s where s.id = _slot
  returning id
$$;

-- Act as a signed in user (or anon when _uid is null) for the rest of the
-- transaction. Call `set local role ...` yourself; a function cannot.
create or replace function tests.claims(_uid uuid, _role text default 'authenticated')
returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(_uid::text, ''), true);
  perform set_config('request.jwt.claims',
    json_build_object('sub', _uid, 'role', _role)::text, true);
end $$;

-- A team (the captain becomes its first member through the teams trigger),
-- extra members, an event and its event_slots rows.
create or replace function tests.create_team(_captain uuid, _member_limit int default 50)
returns uuid language sql as $$
  insert into public.teams (slug, name, captain_id, member_limit)
  values ('t-' || substr(md5(random()::text), 1, 12), 'Test Team', _captain, _member_limit)
  returning id
$$;

create or replace function tests.add_member(_team uuid, _user uuid)
returns void language sql as $$
  insert into public.team_memberships (team_id, user_id, role, status)
  values (_team, _user, 'member', 'active')
$$;

create or replace function tests.create_event(_team uuid, _slot_count int default 2)
returns uuid language sql as $$
  insert into public.events (team_id, title, starts_at, slot_count, reserve_count, created_by)
  select _team, 'Test Match', now() + interval '3 days', _slot_count, 3, t.captain_id
    from public.teams t where t.id = _team
  returning id
$$;

-- created_at defaults to clock_timestamp() so rows made in one test
-- transaction still have a join order; pass it to set the order explicitly.
create or replace function tests.create_event_slot(
  _event uuid,
  _user uuid,
  _type public.slot_type,
  _position int,
  _status public.slot_status default 'reserved',
  _created_at timestamptz default null
) returns uuid language sql as $$
  insert into public.event_slots (event_id, user_id, slot_type, status, position, created_at)
  values (_event, _user, _type, _status, _position, coalesce(_created_at, clock_timestamp()))
  returning id
$$;

grant execute on all functions in schema tests to anon, authenticated, service_role;
