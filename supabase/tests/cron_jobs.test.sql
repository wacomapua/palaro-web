-- The release jobs are scheduled (team-manager PR #7 review finding 8). 0005
-- and 20260529000004 skipped scheduling when pg_cron was not installed yet;
-- 20260531000003 installs it and (re)schedules both by name.
-- C13: process-venue-refunds runs payments-process-refunds every 5 minutes
-- through pg_net, with the project URL and service role key from Vault.
begin;
select plan(12);

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

-- ---------------------------------------------------------------------------
-- process-venue-refunds (C13)
-- ---------------------------------------------------------------------------
select has_extension('pg_net', 'pg_net is installed');
select results_eq($$select schedule::text, active, database = current_database() from cron.job where jobname = 'process-venue-refunds'$$,
  $$values ('*/5 * * * *'::text, true, true)$$, 'process-venue-refunds runs every 5 minutes in this database, once');

create function pg_temp.run_refund_job() returns bigint language plpgsql as $$
declare
  _before bigint := (select coalesce(max(id), 0) from net.http_request_queue);
begin
  execute (select command from cron.job where jobname = 'process-venue-refunds');
  return (select count(*) from net.http_request_queue where id > _before);
end $$;

-- Before the runbook has created the Vault secrets, the job does nothing and
-- does not fail.
select is(pg_temp.run_refund_job(), 0::bigint, 'without the Vault secrets the job sends nothing and does not fail');
select vault.create_secret('http://kong.test:8000/', 'project_url') as s1 \gset
select is(pg_temp.run_refund_job(), 0::bigint, 'with only project_url it still sends nothing');
select vault.create_secret('test-service-role-key', 'service_role_key') as s2 \gset
select is(pg_temp.run_refund_job(), 1::bigint, 'with both secrets it sends one request');
select results_eq(
  $$select method::text, url, headers->>'Authorization', headers->>'Content-Type', convert_from(body, 'utf8')::jsonb
      from net.http_request_queue order by id desc limit 1$$,
  $$values ('POST'::text, 'http://kong.test:8000/functions/v1/payments-process-refunds'::text,
            'Bearer test-service-role-key'::text, 'application/json'::text, '{}'::jsonb)$$,
  'a POST to payments-process-refunds with the service role key and an empty body');

select is((select count(*)::int from cron.job), 3, 'three jobs in all, one per name');

select * from finish();
rollback;
