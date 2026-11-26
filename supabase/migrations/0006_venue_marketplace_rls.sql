-- =============================================================================
-- Venue marketplace — RLS policies
-- =============================================================================
-- Mirrors team-manager's existing pattern: a `security definer` helper
-- (`is_venue_owner`) drives policies, all writes that mutate booking state
-- go through security-definer RPCs (book_venue_slot, complete_venue_booking,
-- cancel_venue_booking) which bypass RLS by design.
--
-- Anonymous browse: SELECT on active venues + their courts/slots is open
-- to anon role so the team-manager mobile app can show the marketplace tab
-- pre-login.
-- =============================================================================

create or replace function public.is_venue_owner(_venue_id uuid)
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists(
    select 1 from public.venues v
     where v.id = _venue_id and v.owner_id = auth.uid()
  );
$$;

alter table public.venues               enable row level security;
alter table public.venue_courts          enable row level security;
alter table public.venue_slot_templates  enable row level security;
alter table public.venue_slots           enable row level security;
alter table public.venue_bookings        enable row level security;
alter table public.venue_payouts         enable row level security;

-- ---------- venues ----------
-- Anonymous + authenticated can read active venues (browse). Owner sees own
-- venue at any status (so they see their pending_review one).
create policy venues_public_read on public.venues
  for select using (status = 'active' or public.is_venue_owner(id));

create policy venues_owner_insert on public.venues
  for insert with check (owner_id = auth.uid());

create policy venues_owner_update on public.venues
  for update using (public.is_venue_owner(id))
  with check (public.is_venue_owner(id));

create policy venues_owner_delete on public.venues
  for delete using (public.is_venue_owner(id));

-- ---------- venue_courts ----------
create policy courts_public_read on public.venue_courts
  for select using (
    exists (
      select 1 from public.venues v
       where v.id = venue_courts.venue_id
         and (v.status = 'active' or public.is_venue_owner(v.id))
    )
  );

create policy courts_owner_write on public.venue_courts
  for all using (public.is_venue_owner(venue_id))
  with check (public.is_venue_owner(venue_id));

-- ---------- venue_slot_templates ----------
create policy templates_owner_only on public.venue_slot_templates
  for all using (public.is_venue_owner(venue_id))
  with check (public.is_venue_owner(venue_id));

-- ---------- venue_slots ----------
create policy slots_public_read on public.venue_slots
  for select using (
    exists (
      select 1 from public.venues v
       where v.id = venue_slots.venue_id
         and (v.status = 'active' or public.is_venue_owner(v.id))
    )
  );

-- Owner can edit slot prices, close slots, etc. directly. Booking
-- transitions (held/booked) only happen via book_venue_slot /
-- complete_venue_booking (security definer; bypasses RLS).
create policy slots_owner_write on public.venue_slots
  for all using (public.is_venue_owner(venue_id))
  with check (public.is_venue_owner(venue_id));

-- ---------- venue_bookings ----------
-- Captain who paid sees their booking; venue owner sees all bookings on
-- their venue. No client INSERT/UPDATE policies — every state transition
-- flows through the security-definer RPCs.
create policy bookings_read on public.venue_bookings
  for select using (
    captain_user_id = auth.uid()
    or public.is_venue_owner(venue_id)
  );

-- ---------- venue_payouts ----------
create policy payouts_owner_read on public.venue_payouts
  for select using (public.is_venue_owner(venue_id));
-- Writes only via service-role edge functions (`payouts-run`). No policy.
