-- The refund tier walk in cancel_venue_booking against one fixed table of
-- expected refunds: the seven C8 policies at hour offsets on and around every
-- threshold. tests/refund.test.mjs reads the same two blocks below and checks
-- computeRefund (lib/refund.ts) against them, so the SQL walk and the owner
-- preview are held to the same answers. Keep the row formats as they are:
-- the TypeScript test parses them.
begin;

create temp table refund_policies (name text primary key, policy jsonb not null) on commit drop;
create temp table refund_cases (
  name text not null references refund_policies,
  hours numeric not null,
  pct int not null
) on commit drop;

-- BEGIN policies
insert into refund_policies (name, policy) values
  ('stock', '{"tiers":[{"hours_before":48,"refund_pct":100},{"hours_before":24,"refund_pct":50},{"hours_before":0,"refund_pct":0}]}'),
  ('custom_24_6', '{"tiers":[{"hours_before":24,"refund_pct":100},{"hours_before":6,"refund_pct":50},{"hours_before":0,"refund_pct":0}]}'),
  ('p72', '{"tiers":[{"hours_before":72,"refund_pct":100},{"hours_before":0,"refund_pct":0}]}'),
  ('p48_12', '{"tiers":[{"hours_before":48,"refund_pct":100},{"hours_before":12,"refund_pct":0}]}'),
  ('any_full', '{"tiers":[{"hours_before":0,"refund_pct":100}]}'),
  ('p24_half', '{"tiers":[{"hours_before":24,"refund_pct":50}]}'),
  ('unsorted', '{"tiers":[{"hours_before":0,"refund_pct":0},{"hours_before":48,"refund_pct":100},{"hours_before":24,"refund_pct":50}]}');
-- END policies

-- BEGIN cases
insert into refund_cases (name, hours, pct) values
  ('stock', 100, 100), ('stock', 72, 100), ('stock', 71.5, 100), ('stock', 48, 100),
  ('stock', 47.5, 50), ('stock', 24, 50), ('stock', 23.5, 0), ('stock', 12, 0),
  ('stock', 11.5, 0), ('stock', 6, 0), ('stock', 5.5, 0), ('stock', 0, 0), ('stock', -1, 0),
  ('custom_24_6', 100, 100), ('custom_24_6', 72, 100), ('custom_24_6', 71.5, 100), ('custom_24_6', 48, 100),
  ('custom_24_6', 47.5, 100), ('custom_24_6', 24, 100), ('custom_24_6', 23.5, 50), ('custom_24_6', 12, 50),
  ('custom_24_6', 11.5, 50), ('custom_24_6', 6, 50), ('custom_24_6', 5.5, 0), ('custom_24_6', 0, 0), ('custom_24_6', -1, 0),
  ('p72', 100, 100), ('p72', 72, 100), ('p72', 71.5, 0), ('p72', 48, 0),
  ('p72', 47.5, 0), ('p72', 24, 0), ('p72', 23.5, 0), ('p72', 12, 0),
  ('p72', 11.5, 0), ('p72', 6, 0), ('p72', 5.5, 0), ('p72', 0, 0), ('p72', -1, 0),
  ('p48_12', 100, 100), ('p48_12', 72, 100), ('p48_12', 71.5, 100), ('p48_12', 48, 100),
  ('p48_12', 47.5, 0), ('p48_12', 24, 0), ('p48_12', 23.5, 0), ('p48_12', 12, 0),
  ('p48_12', 11.5, 0), ('p48_12', 6, 0), ('p48_12', 5.5, 0), ('p48_12', 0, 0), ('p48_12', -1, 0),
  ('any_full', 100, 100), ('any_full', 72, 100), ('any_full', 71.5, 100), ('any_full', 48, 100),
  ('any_full', 47.5, 100), ('any_full', 24, 100), ('any_full', 23.5, 100), ('any_full', 12, 100),
  ('any_full', 11.5, 100), ('any_full', 6, 100), ('any_full', 5.5, 100), ('any_full', 0, 100), ('any_full', -1, 0),
  ('p24_half', 100, 50), ('p24_half', 72, 50), ('p24_half', 71.5, 50), ('p24_half', 48, 50),
  ('p24_half', 47.5, 50), ('p24_half', 24, 50), ('p24_half', 23.5, 0), ('p24_half', 12, 0),
  ('p24_half', 11.5, 0), ('p24_half', 6, 0), ('p24_half', 5.5, 0), ('p24_half', 0, 0), ('p24_half', -1, 0),
  ('unsorted', 100, 100), ('unsorted', 72, 100), ('unsorted', 71.5, 100), ('unsorted', 48, 100),
  ('unsorted', 47.5, 50), ('unsorted', 24, 50), ('unsorted', 23.5, 0), ('unsorted', 12, 0),
  ('unsorted', 11.5, 0), ('unsorted', 6, 0), ('unsorted', 5.5, 0), ('unsorted', 0, 0), ('unsorted', -1, 0);
-- END cases

select plan((select count(*)::int from refund_cases) + 2);

select tests.create_user() as owner \gset
select tests.create_user() as player \gset
select tests.create_venue(:'owner') as venue \gset

-- One court per policy, one paid exclusive booking per case. The policy sits
-- on the slot (the booking has no snapshot), so this exercises the walk only.
create temp table policy_courts on commit drop as
  select p.name, tests.create_court(:'venue', 'Court ' || p.name) as court_id
    from refund_policies p;

create temp table refund_runs on commit drop as
  select c.name, c.hours, c.pct,
         tests.create_slot(
           :'venue', pc.court_id,
           now() + c.hours * interval '1 hour',
           now() + c.hours * interval '1 hour' + interval '1 minute',
           100000, null, 'booked'
         ) as slot_id
    from refund_cases c
    join policy_courts pc using (name);

update public.venue_slots s
   set refund_policy = p.policy
  from refund_runs r
  join refund_policies p using (name)
 where s.id = r.slot_id;

alter table refund_runs add column booking_id uuid;
update refund_runs set booking_id = tests.create_booking(slot_id, :'player', 'paid', 1, 100000);

-- Cancel every booking as its captain in one statement (one now()).
select tests.claims(:'player');
create temp table refund_results on commit drop as
  select r.name, r.hours, r.pct, r.booking_id, c.refund_amount_cents, c.hours_before
    from refund_runs r
    cross join lateral public.cancel_venue_booking(r.booking_id, null) c;

select is(
  refund_amount_cents,
  round(100000 * pct / 100.0)::int,
  format('%s at %sh before start: %s%% refund', name, hours, pct)
)
  from refund_results
 order by name, hours desc;

select ok(
  (select bool_and(hours_before = hours) from refund_results),
  'cancel_venue_booking measured the same hours before start as the case table'
);

select is(
  (select count(*)::int
     from refund_results r
     join public.venue_bookings b on b.id = r.booking_id
    where b.status::text <> case when r.pct > 0 then 'refunded' else 'cancelled' end),
  0,
  'every booking ends refunded when any refund is due, else cancelled'
);

select * from finish();
rollback;
