-- Venues operate in a fixed local timezone. Without this, slot day/time math
-- fell back to the server's (UTC) or the owner's browser timezone, so slots
-- could be stored/displayed a day off. Default to Manila; editable in settings.
alter table public.venues add column if not exists timezone text not null default 'Asia/Manila';
