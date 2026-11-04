-- The release jobs are scheduled (team-manager PR #7 review finding 8). 0005
-- and 20260529000004 skipped scheduling when pg_cron was not installed yet;
-- 20260531000003 installs it and (re)schedules both by name.
begin;
select plan(5);

select has_extension('pg_cron', 'pg_cron is installed');

select results_eq(
  $$select schedule, btrim(regexp_replace(command, '\s+', ' ', 'g')), active
      from cron.job where jobname = 'release-stale-venue-holds'$$,
  $$values ('* * * * *'::text,
            'update public.venue_slots set status = ''available'', held_until = null where status = ''held'' and held_until is not null and held_until < now()'::text,
            true)$$,
  'release-stale-venue-holds runs the stale hold release every minute');

select results_eq(
  $$select schedule, btrim(command), active
      from cron.job where jobname = 'release-stale-shared-bookings'$$,
  $$values ('* * * * *'::text, 'select public.release_stale_shared_bookings(15);'::text, true)$$,
  'release-stale-shared-bookings runs every minute');

select is((select count(*)::int from cron.job where jobname in ('release-stale-venue-holds', 'release-stale-shared-bookings')), 2,
  'exactly one job per name');

select is((select count(distinct database)::int from cron.job where jobname in ('release-stale-venue-holds', 'release-stale-shared-bookings')
           and database = current_database()), 1, 'both run in this database');

select * from finish();
rollback;
