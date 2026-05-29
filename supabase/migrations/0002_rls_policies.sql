-- =============================================================================
-- Row Level Security policies
-- =============================================================================
-- Tenant isolation: a user only sees rows for teams they are an active member
-- of. Captains/admins get write power within their teams. Profiles are
-- world-readable (we only expose display_name + avatar via API views in
-- practice; tighten this if PII becomes a concern).
-- =============================================================================

alter table public.profiles enable row level security;
alter table public.teams enable row level security;
alter table public.team_memberships enable row level security;
alter table public.events enable row level security;
alter table public.event_slots enable row level security;
alter table public.transactions enable row level security;
alter table public.announcements enable row level security;
alter table public.chat_channels enable row level security;
alter table public.chat_messages enable row level security;
alter table public.devices enable row level security;

-- ---------- profiles ----------
create policy profiles_self_read on public.profiles
  for select using (true);

create policy profiles_self_update on public.profiles
  for update using (id = auth.uid()) with check (id = auth.uid());

-- ---------- teams ----------
-- Anyone authenticated can read team meta (needed for invite-by-link flow).
create policy teams_read on public.teams
  for select using (auth.role() = 'authenticated');

create policy teams_create on public.teams
  for insert with check (captain_id = auth.uid());

create policy teams_update on public.teams
  for update using (public.is_team_captain(id)) with check (public.is_team_captain(id));

create policy teams_delete on public.teams
  for delete using (captain_id = auth.uid());

-- ---------- team_memberships ----------
create policy memberships_read on public.team_memberships
  for select using (
    user_id = auth.uid() or public.is_team_member(team_id)
  );

create policy memberships_join_self on public.team_memberships
  for insert with check (
    user_id = auth.uid() or public.is_team_captain(team_id)
  );

create policy memberships_update on public.team_memberships
  for update using (
    user_id = auth.uid() or public.is_team_captain(team_id)
  ) with check (
    user_id = auth.uid() or public.is_team_captain(team_id)
  );

create policy memberships_leave on public.team_memberships
  for delete using (
    user_id = auth.uid() or public.is_team_captain(team_id)
  );

-- ---------- events ----------
create policy events_read on public.events
  for select using (public.is_team_member(team_id));

create policy events_write on public.events
  for all using (public.is_team_captain(team_id))
  with check (public.is_team_captain(team_id));

-- ---------- event_slots ----------
create policy slots_read on public.event_slots
  for select using (
    exists (
      select 1 from public.events e
      where e.id = event_slots.event_id and public.is_team_member(e.team_id)
    )
  );

-- A user can claim their own slot, captains can manage any slot.
create policy slots_claim on public.event_slots
  for insert with check (
    user_id = auth.uid()
    or exists (
      select 1 from public.events e
      where e.id = event_slots.event_id and public.is_team_captain(e.team_id)
    )
  );

create policy slots_update on public.event_slots
  for update using (
    user_id = auth.uid()
    or exists (
      select 1 from public.events e
      where e.id = event_slots.event_id and public.is_team_captain(e.team_id)
    )
  );

create policy slots_release on public.event_slots
  for delete using (
    user_id = auth.uid()
    or exists (
      select 1 from public.events e
      where e.id = event_slots.event_id and public.is_team_captain(e.team_id)
    )
  );

-- ---------- transactions ----------
-- A user sees their own transactions and captains see all team transactions.
create policy txn_read on public.transactions
  for select using (
    user_id = auth.uid()
    or (team_id is not null and public.is_team_captain(team_id))
  );

-- Inserts/updates only via service role (Edge Functions). Clients never write directly.
-- (No insert/update/delete policy → blocked by default for non-service-role.)

-- ---------- announcements ----------
create policy ann_read on public.announcements
  for select using (public.is_team_member(team_id));

create policy ann_write on public.announcements
  for all using (public.is_team_captain(team_id))
  with check (public.is_team_captain(team_id));

-- ---------- chat ----------
create policy chat_channels_read on public.chat_channels
  for select using (public.is_team_member(team_id));

create policy chat_messages_read on public.chat_messages
  for select using (
    exists (
      select 1 from public.chat_channels c
      where c.id = chat_messages.channel_id and public.is_team_member(c.team_id)
    )
  );

create policy chat_messages_send on public.chat_messages
  for insert with check (
    sender_id = auth.uid()
    and exists (
      select 1 from public.chat_channels c
      where c.id = chat_messages.channel_id and public.is_team_member(c.team_id)
    )
  );

create policy chat_messages_delete_own on public.chat_messages
  for delete using (sender_id = auth.uid());

-- ---------- devices ----------
create policy devices_self on public.devices
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
