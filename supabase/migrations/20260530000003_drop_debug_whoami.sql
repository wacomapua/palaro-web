-- Remove the temporary diagnostic added in 20260530000001 to investigate the
-- venue-insert RLS issue. No longer needed.
drop function if exists public.debug_whoami();
