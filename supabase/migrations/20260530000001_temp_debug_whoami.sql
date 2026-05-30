-- TEMPORARY diagnostic — remove after debugging the RLS/JWT issue.
-- Returns what PostgREST resolves for the calling request's token.
create or replace function public.debug_whoami()
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'uid', auth.uid(),
    'role', auth.role(),
    'jwt_sub', (auth.jwt() ->> 'sub'),
    'jwt_role', (auth.jwt() ->> 'role'),
    'claims_present', (current_setting('request.jwt.claims', true) is not null
                       and current_setting('request.jwt.claims', true) <> '')
  );
$$;
grant execute on function public.debug_whoami() to anon, authenticated;
