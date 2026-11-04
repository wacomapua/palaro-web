-- Runs as supabase_admin before the migrations, in the throwaway test
-- container only. The bare Postgres image ships a minimal auth schema; hosted
-- Supabase gets the rest from GoTrue's own migrations. Recreate just the parts
-- this repo's migrations and tests rely on, with GoTrue's definitions.

create or replace function auth.uid() returns uuid
language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
$$;

create or replace function auth.role() returns text
language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
$$;

create or replace function auth.jwt() returns jsonb
language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim', true), ''),
    nullif(current_setting('request.jwt.claims', true), '')
  )::jsonb
$$;

alter table auth.users add column if not exists phone text;

create extension if not exists pgtap with schema extensions;
