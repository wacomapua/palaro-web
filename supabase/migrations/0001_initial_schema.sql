-- =============================================================================
-- Team Manager — initial schema
-- =============================================================================
-- Multi-tenant by team. Tenant isolation is enforced by RLS policies that key
-- off `team_memberships`. A user can be a member of many teams.
-- =============================================================================

create extension if not exists "pgcrypto";
create extension if not exists "citext";

-- ---------- enums ----------
create type membership_role as enum ('captain', 'admin', 'member', 'reserve');
create type membership_status as enum ('active', 'invited', 'suspended', 'left');
create type event_type as enum ('match', 'practice', 'social', 'meetup');
create type event_status as enum ('scheduled', 'cancelled', 'completed');
create type slot_type as enum ('confirmed', 'reserve');
create type slot_status as enum ('reserved', 'paid', 'flaked', 'released');
create type txn_type as enum ('slot', 'flake', 'club_dues', 'captain_subscription', 'marketplace');
create type txn_gateway as enum ('paymongo', 'apple_iap', 'google_iap', 'manual');
create type txn_status as enum ('pending', 'succeeded', 'failed', 'refunded');
create type team_plan as enum ('free', 'pro');

-- ---------- profiles ----------
-- Mirrors auth.users; populated by trigger on signup.
create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  phone text unique,
  email citext unique,
  display_name text,
  avatar_url text,
  created_at timestamptz not null default now()
);

create index profiles_phone_idx on public.profiles(phone);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, phone, email, display_name)
  values (new.id, new.phone, new.email, coalesce(new.raw_user_meta_data->>'display_name', ''))
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

-- ---------- teams ----------
create table public.teams (
  id uuid primary key default gen_random_uuid(),
  slug citext unique not null,
  name text not null,
  sport text not null default 'football',
  captain_id uuid not null references public.profiles(id) on delete restrict,
  plan team_plan not null default 'free',
  member_limit int not null default 5, -- free tier: 5 members; pro lifts this
  theme jsonb,                          -- white-label colors / logo per team
  created_at timestamptz not null default now()
);

create index teams_captain_idx on public.teams(captain_id);

-- ---------- team_memberships ----------
create table public.team_memberships (
  team_id uuid not null references public.teams(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role membership_role not null default 'member',
  status membership_status not null default 'active',
  jersey_number int,
  dues_paid_until date,
  joined_at timestamptz not null default now(),
  primary key (team_id, user_id)
);

create index memberships_user_idx on public.team_memberships(user_id);
create index memberships_team_active_idx on public.team_memberships(team_id) where status = 'active';

-- Helper: is the current user a member of this team?
create or replace function public.is_team_member(_team_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(
    select 1
    from public.team_memberships m
    where m.team_id = _team_id
      and m.user_id = auth.uid()
      and m.status = 'active'
  );
$$;

create or replace function public.is_team_captain(_team_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(
    select 1
    from public.team_memberships m
    where m.team_id = _team_id
      and m.user_id = auth.uid()
      and m.role in ('captain', 'admin')
      and m.status = 'active'
  );
$$;

-- Enforce member_limit for free tier teams.
create or replace function public.enforce_member_limit()
returns trigger
language plpgsql
as $$
declare
  current_count int;
  team_limit int;
begin
  select member_limit into team_limit from public.teams where id = new.team_id;
  select count(*) into current_count
    from public.team_memberships
    where team_id = new.team_id and status = 'active';
  if current_count >= team_limit then
    raise exception 'Team is at member limit (% / %). Upgrade to Pro to add more.', current_count, team_limit
      using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger trg_enforce_member_limit
before insert on public.team_memberships
for each row
when (new.status = 'active')
execute function public.enforce_member_limit();

-- ---------- events ----------
create table public.events (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  title text not null,
  type event_type not null default 'match',
  status event_status not null default 'scheduled',
  location text,
  starts_at timestamptz not null,
  ends_at timestamptz,
  slot_count int not null default 11,
  reserve_count int not null default 3,
  slot_fee_cents int not null default 0,
  currency text not null default 'PHP',
  flake_fee_cents int not null default 0,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

create index events_team_starts_idx on public.events(team_id, starts_at desc);

-- ---------- event_slots ----------
create table public.event_slots (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  slot_type slot_type not null default 'confirmed',
  status slot_status not null default 'reserved',
  position int not null,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  unique (event_id, user_id),
  unique (event_id, slot_type, position)
);

create index slots_event_idx on public.event_slots(event_id);
create index slots_user_idx on public.event_slots(user_id);

-- ---------- transactions ----------
create table public.transactions (
  id uuid primary key default gen_random_uuid(),
  team_id uuid references public.teams(id) on delete set null,
  user_id uuid not null references public.profiles(id) on delete restrict,
  type txn_type not null,
  amount_cents int not null check (amount_cents >= 0),
  currency text not null default 'PHP',
  platform_fee_cents int not null default 0,
  gateway txn_gateway not null,
  gateway_ref text,
  status txn_status not null default 'pending',
  metadata jsonb,
  created_at timestamptz not null default now()
);

create index txn_user_idx on public.transactions(user_id, created_at desc);
create index txn_team_idx on public.transactions(team_id, created_at desc);
create index txn_gateway_ref_idx on public.transactions(gateway_ref);

-- ---------- announcements ----------
create table public.announcements (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  author_id uuid not null references public.profiles(id),
  body text not null,
  pinned boolean not null default false,
  created_at timestamptz not null default now()
);

create index announcements_team_idx on public.announcements(team_id, created_at desc);

-- ---------- chat ----------
create table public.chat_channels (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references public.teams(id) on delete cascade,
  kind text not null default 'team_general',
  created_at timestamptz not null default now(),
  unique (team_id, kind)
);

create table public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  channel_id uuid not null references public.chat_channels(id) on delete cascade,
  sender_id uuid not null references public.profiles(id),
  body text not null,
  created_at timestamptz not null default now()
);

create index chat_messages_channel_idx on public.chat_messages(channel_id, created_at desc);

-- Auto-create a general chat channel when a team is created.
create or replace function public.create_default_channel()
returns trigger
language plpgsql
as $$
begin
  insert into public.chat_channels (team_id, kind) values (new.id, 'team_general');
  return new;
end;
$$;

create trigger trg_create_default_channel
after insert on public.teams
for each row execute function public.create_default_channel();

-- Auto-add captain as first active member.
create or replace function public.add_captain_membership()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.team_memberships (team_id, user_id, role, status)
  values (new.id, new.captain_id, 'captain', 'active');
  return new;
end;
$$;

create trigger trg_add_captain_membership
after insert on public.teams
for each row execute function public.add_captain_membership();

-- ---------- devices (for push notifications) ----------
create table public.devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  expo_push_token text not null,
  platform text not null check (platform in ('ios', 'android')),
  created_at timestamptz not null default now(),
  unique (expo_push_token)
);

create index devices_user_idx on public.devices(user_id);
