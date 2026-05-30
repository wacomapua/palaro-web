-- Fix: creating a venue with PostgREST return=representation (the client calling
-- .select() after .insert()) failed with 42501. venues_public_read's USING called
-- is_venue_owner(id) — a STABLE function that re-queries venues and cannot see the
-- row being inserted during INSERT ... RETURNING, so a brand-new pending_review
-- row (owned by the caller) was treated as not-visible and the RETURNING failed.
--
-- Evaluate ownership directly on the row's own owner_id column instead. This is
-- semantically identical to is_venue_owner(id) for the venues table, but it works
-- during RETURNING because it doesn't re-query the table.
drop policy if exists venues_public_read on public.venues;
create policy venues_public_read on public.venues
  for select using (status = 'active' or owner_id = auth.uid());
