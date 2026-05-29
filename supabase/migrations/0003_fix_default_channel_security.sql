-- Fix: trg_create_default_channel was running as the calling user, but
-- chat_channels has no INSERT policy (channels are only auto-created by this
-- trigger). Mirror the captain-membership trigger and run as security definer
-- so the trigger bypasses RLS like its sibling does.

create or replace function public.create_default_channel()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.chat_channels (team_id, kind) values (new.id, 'team_general');
  return new;
end;
$$;
